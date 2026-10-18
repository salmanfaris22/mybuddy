package store

import (
	"context"
	"embed"
	"errors"
	"fmt"
	"io/fs"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"
)

//go:embed migrations/*.sql
var migrationFiles embed.FS

// PostgresStore persists metadata in PostgreSQL.
type PostgresStore struct {
	pool *pgxpool.Pool
}

// OpenPostgres connects, applies pending migrations and returns a store.
func OpenPostgres(ctx context.Context, url string) (*PostgresStore, error) {
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return nil, fmt.Errorf("parse database url: %w", err)
	}
	cfg.MaxConns = 10
	pool, err := pgxpool.NewWithConfig(ctx, cfg)
	if err != nil {
		return nil, fmt.Errorf("connect: %w", err)
	}
	s := &PostgresStore{pool: pool}
	if err := s.migrate(ctx); err != nil {
		pool.Close()
		return nil, err
	}
	return s, nil
}

// Pool exposes the pool for tests.
func (s *PostgresStore) Pool() *pgxpool.Pool { return s.pool }

func (s *PostgresStore) migrate(ctx context.Context) error {
	entries, err := fs.ReadDir(migrationFiles, "migrations")
	if err != nil {
		return err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	tx, err := s.pool.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx) //nolint:errcheck // rollback after commit is a no-op
	// Serialize concurrent migrators.
	if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(727274)`); err != nil {
		return err
	}
	if _, err := tx.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (version INT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL)`); err != nil {
		return err
	}
	for _, e := range entries {
		name := e.Name()
		version, err := strconv.Atoi(strings.SplitN(name, "_", 2)[0])
		if err != nil {
			return fmt.Errorf("migration %s: bad version prefix", name)
		}
		var exists bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)`, version).Scan(&exists); err != nil {
			return err
		}
		if exists {
			continue
		}
		sql, err := migrationFiles.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, string(sql)); err != nil {
			return fmt.Errorf("apply migration %s: %w", name, err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO schema_migrations (version, applied_at) VALUES ($1, now())`, version); err != nil {
			return err
		}
	}
	return tx.Commit(ctx)
}

func isUniqueViolation(err error) bool {
	var pgErr *pgconn.PgError
	return errors.As(err, &pgErr) && pgErr.Code == "23505"
}

func (s *PostgresStore) CreateDevice(ctx context.Context, d Device) error {
	tag, err := s.pool.Exec(ctx,
		`INSERT INTO devices (id, public_key, platform, created_at, last_seen_at) VALUES ($1, $2, $3, $4, $5) ON CONFLICT (id) DO NOTHING`,
		d.ID, d.PublicKey, d.Platform, d.CreatedAt, d.LastSeenAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	return nil
}

func (s *PostgresStore) GetDevice(ctx context.Context, id string) (Device, error) {
	var d Device
	err := s.pool.QueryRow(ctx, `SELECT id, public_key, platform, created_at, last_seen_at FROM devices WHERE id = $1`, id).
		Scan(&d.ID, &d.PublicKey, &d.Platform, &d.CreatedAt, &d.LastSeenAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Device{}, ErrNotFound
	}
	return d, err
}

func (s *PostgresStore) TouchDevice(ctx context.Context, id string, at time.Time) error {
	tag, err := s.pool.Exec(ctx, `UPDATE devices SET last_seen_at = $2 WHERE id = $1`, id, at)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *PostgresStore) CreateChallenge(ctx context.Context, c Challenge) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO auth_challenges (id, device_id, nonce, expires_at) VALUES ($1, $2, $3, $4)`,
		c.ID, c.DeviceID, c.Nonce, c.ExpiresAt)
	if isUniqueViolation(err) {
		return ErrConflict
	}
	return err
}

func (s *PostgresStore) ConsumeChallenge(ctx context.Context, id, deviceID string, now time.Time) (Challenge, error) {
	c := Challenge{ID: id, DeviceID: deviceID}
	err := s.pool.QueryRow(ctx, `DELETE FROM auth_challenges WHERE id = $1 AND device_id = $2 RETURNING nonce, expires_at`, id, deviceID).
		Scan(&c.Nonce, &c.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Challenge{}, ErrNotFound
	}
	if err != nil {
		return Challenge{}, err
	}
	if !now.Before(c.ExpiresAt) {
		return Challenge{}, ErrExpired
	}
	return c, nil
}

func (s *PostgresStore) CreateToken(ctx context.Context, t Token) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO auth_tokens (token_hash, device_id, expires_at) VALUES ($1, $2, $3)`, t.Hash[:], t.DeviceID, t.ExpiresAt)
	if isUniqueViolation(err) {
		return ErrConflict
	}
	return err
}

func (s *PostgresStore) LookupToken(ctx context.Context, hash [32]byte, now time.Time) (Token, error) {
	t := Token{Hash: hash}
	err := s.pool.QueryRow(ctx, `SELECT device_id, expires_at FROM auth_tokens WHERE token_hash = $1 AND expires_at > $2`, hash[:], now).
		Scan(&t.DeviceID, &t.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Token{}, ErrNotFound
	}
	return t, err
}

const pairingColumns = `id, host_device_id, client_device_id, statement_created_at, registered_at, revoked_at, COALESCE(revoked_by, '')`

func scanPairing(row pgx.Row) (Pairing, error) {
	var p Pairing
	err := row.Scan(&p.ID, &p.HostDeviceID, &p.ClientDeviceID, &p.CreatedAt, &p.RegisteredAt, &p.RevokedAt, &p.RevokedBy)
	return p, err
}

func (s *PostgresStore) CreatePairing(ctx context.Context, p Pairing) error {
	_, err := s.pool.Exec(ctx,
		`INSERT INTO pairings (id, host_device_id, client_device_id, statement_created_at, registered_at) VALUES ($1, $2, $3, $4, $5)`,
		p.ID, p.HostDeviceID, p.ClientDeviceID, p.CreatedAt, p.RegisteredAt)
	if isUniqueViolation(err) {
		return ErrConflict
	}
	return err
}

func (s *PostgresStore) GetPairing(ctx context.Context, id string) (Pairing, error) {
	p, err := scanPairing(s.pool.QueryRow(ctx, `SELECT `+pairingColumns+` FROM pairings WHERE id = $1`, id))
	if errors.Is(err, pgx.ErrNoRows) {
		return Pairing{}, ErrNotFound
	}
	return p, err
}

func (s *PostgresStore) ListPairings(ctx context.Context, deviceID string) ([]Pairing, error) {
	rows, err := s.pool.Query(ctx, `SELECT `+pairingColumns+` FROM pairings WHERE host_device_id = $1 OR client_device_id = $1 ORDER BY registered_at`, deviceID)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []Pairing{}
	for rows.Next() {
		p, err := scanPairing(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, rows.Err()
}

func (s *PostgresStore) ActivePairingBetween(ctx context.Context, a, b string) (Pairing, error) {
	p, err := scanPairing(s.pool.QueryRow(ctx, `SELECT `+pairingColumns+` FROM pairings
		WHERE revoked_at IS NULL AND ((host_device_id = $1 AND client_device_id = $2) OR (host_device_id = $2 AND client_device_id = $1))
		LIMIT 1`, a, b))
	if errors.Is(err, pgx.ErrNoRows) {
		return Pairing{}, ErrNotFound
	}
	return p, err
}

func (s *PostgresStore) RevokePairing(ctx context.Context, id, by string, at time.Time) (Pairing, error) {
	if _, err := s.pool.Exec(ctx, `UPDATE pairings SET revoked_at = $3, revoked_by = $2 WHERE id = $1 AND revoked_at IS NULL`, id, by, at); err != nil {
		return Pairing{}, err
	}
	return s.GetPairing(ctx, id)
}

func (s *PostgresStore) AppendAudit(ctx context.Context, e AuditEvent) error {
	_, err := s.pool.Exec(ctx, `INSERT INTO audit_events (at, kind, device_id, peer_device_id) VALUES ($1, $2, $3, $4)`,
		e.At, e.Kind, e.DeviceID, e.PeerDeviceID)
	return err
}

func (s *PostgresStore) ListAudit(ctx context.Context, deviceID string, limit int) ([]AuditEvent, error) {
	rows, err := s.pool.Query(ctx, `SELECT at, kind, device_id, peer_device_id FROM audit_events
		WHERE device_id = $1 OR peer_device_id = $1 ORDER BY at DESC, id DESC LIMIT $2`, deviceID, limit)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []AuditEvent{}
	for rows.Next() {
		var e AuditEvent
		if err := rows.Scan(&e.At, &e.Kind, &e.DeviceID, &e.PeerDeviceID); err != nil {
			return nil, err
		}
		out = append(out, e)
	}
	return out, rows.Err()
}

func (s *PostgresStore) DeleteExpired(ctx context.Context, now, auditBefore time.Time) error {
	batch := &pgx.Batch{}
	batch.Queue(`DELETE FROM auth_challenges WHERE expires_at <= $1`, now)
	batch.Queue(`DELETE FROM auth_tokens WHERE expires_at <= $1`, now)
	batch.Queue(`DELETE FROM audit_events WHERE at < $1`, auditBefore)
	return s.pool.SendBatch(ctx, batch).Close()
}

func (s *PostgresStore) Ping(ctx context.Context) error { return s.pool.Ping(ctx) }
func (s *PostgresStore) Close()                         { s.pool.Close() }
