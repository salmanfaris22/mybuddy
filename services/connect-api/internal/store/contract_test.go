package store_test

import (
	"context"
	"crypto/sha256"
	"errors"
	"net/url"
	"os"
	"strings"
	"testing"
	"time"

	"mybuddy.local/connect-api/internal/store"
)

// Times are truncated to microseconds because PostgreSQL stores microsecond precision.
var t0 = time.Date(2026, 10, 16, 8, 30, 0, 0, time.UTC)

func dev(id, platform string) store.Device {
	key := make([]byte, 91)
	copy(key, id)
	return store.Device{ID: id, PublicKey: key, Platform: platform, CreatedAt: t0, LastSeenAt: t0}
}

const (
	hostID   = "e514356e6546b0b22ebcdd982ec66090"
	clientID = "da96726356de5002c857434beefe468d"
	otherID  = "0123456789abcdef0123456789abcdef"
)

// runContract exercises behavior every Store implementation must share.
func runContract(t *testing.T, newStore func(t *testing.T) store.Store) {
	ctx := context.Background()

	t.Run("devices", func(t *testing.T) {
		s := newStore(t)
		if err := s.CreateDevice(ctx, dev(hostID, "macos")); err != nil {
			t.Fatal(err)
		}
		if err := s.CreateDevice(ctx, dev(hostID, "macos")); !errors.Is(err, store.ErrConflict) {
			t.Fatalf("duplicate device err = %v, want ErrConflict", err)
		}
		d, err := s.GetDevice(ctx, hostID)
		if err != nil || d.Platform != "macos" || len(d.PublicKey) != 91 {
			t.Fatalf("GetDevice = %+v, %v", d, err)
		}
		if _, err := s.GetDevice(ctx, otherID); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("missing device err = %v", err)
		}
		if err := s.TouchDevice(ctx, hostID, t0.Add(time.Hour)); err != nil {
			t.Fatal(err)
		}
		d, _ = s.GetDevice(ctx, hostID)
		if !d.LastSeenAt.Equal(t0.Add(time.Hour)) {
			t.Fatalf("last seen = %v", d.LastSeenAt)
		}
	})

	t.Run("challenges are single use and expire", func(t *testing.T) {
		s := newStore(t)
		c := store.Challenge{ID: "ch1", DeviceID: clientID, Nonce: []byte("nonce"), ExpiresAt: t0.Add(time.Minute)}
		if err := s.CreateChallenge(ctx, c); err != nil {
			t.Fatal(err)
		}
		if _, err := s.ConsumeChallenge(ctx, "ch1", otherID, t0); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("wrong device consume err = %v", err)
		}
		got, err := s.ConsumeChallenge(ctx, "ch1", clientID, t0)
		if err != nil || string(got.Nonce) != "nonce" {
			t.Fatalf("consume = %+v, %v", got, err)
		}
		if _, err := s.ConsumeChallenge(ctx, "ch1", clientID, t0); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("second consume err = %v, want ErrNotFound", err)
		}
		_ = s.CreateChallenge(ctx, store.Challenge{ID: "ch2", DeviceID: clientID, Nonce: []byte("n"), ExpiresAt: t0})
		if _, err := s.ConsumeChallenge(ctx, "ch2", clientID, t0); !errors.Is(err, store.ErrExpired) {
			t.Fatalf("expired consume err = %v, want ErrExpired", err)
		}
		if _, err := s.ConsumeChallenge(ctx, "ch2", clientID, t0); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("expired challenge must be deleted, err = %v", err)
		}
	})

	t.Run("tokens", func(t *testing.T) {
		s := newStore(t)
		_ = s.CreateDevice(ctx, dev(clientID, "android"))
		h := sha256.Sum256([]byte("token"))
		if err := s.CreateToken(ctx, store.Token{Hash: h, DeviceID: clientID, ExpiresAt: t0.Add(15 * time.Minute)}); err != nil {
			t.Fatal(err)
		}
		tok, err := s.LookupToken(ctx, h, t0)
		if err != nil || tok.DeviceID != clientID {
			t.Fatalf("lookup = %+v, %v", tok, err)
		}
		if _, err := s.LookupToken(ctx, h, t0.Add(15*time.Minute)); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("expired token err = %v", err)
		}
		if _, err := s.LookupToken(ctx, sha256.Sum256([]byte("other")), t0); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("unknown token err = %v", err)
		}
	})

	t.Run("pairings", func(t *testing.T) {
		s := newStore(t)
		for _, d := range []store.Device{dev(hostID, "macos"), dev(clientID, "android"), dev(otherID, "android")} {
			if err := s.CreateDevice(ctx, d); err != nil {
				t.Fatal(err)
			}
		}
		p := store.Pairing{ID: "pr1", HostDeviceID: hostID, ClientDeviceID: clientID, CreatedAt: "2026-10-16T08:30:05.000Z", RegisteredAt: t0}
		if err := s.CreatePairing(ctx, p); err != nil {
			t.Fatal(err)
		}
		dup := p
		dup.ID = "pr2"
		if err := s.CreatePairing(ctx, dup); !errors.Is(err, store.ErrConflict) {
			t.Fatalf("duplicate active pairing err = %v", err)
		}
		if got, err := s.ActivePairingBetween(ctx, clientID, hostID); err != nil || got.ID != "pr1" {
			t.Fatalf("active between (reversed) = %+v, %v", got, err)
		}
		if _, err := s.ActivePairingBetween(ctx, clientID, otherID); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("unpaired err = %v", err)
		}
		list, err := s.ListPairings(ctx, clientID)
		if err != nil || len(list) != 1 {
			t.Fatalf("list = %v, %v", list, err)
		}
		rev, err := s.RevokePairing(ctx, "pr1", clientID, t0.Add(time.Minute))
		if err != nil || rev.Active() || rev.RevokedBy != clientID {
			t.Fatalf("revoke = %+v, %v", rev, err)
		}
		// Revoking again keeps the original revocation.
		rev2, err := s.RevokePairing(ctx, "pr1", hostID, t0.Add(2*time.Minute))
		if err != nil || rev2.RevokedBy != clientID || !rev2.RevokedAt.Equal(t0.Add(time.Minute)) {
			t.Fatalf("second revoke = %+v, %v", rev2, err)
		}
		if _, err := s.ActivePairingBetween(ctx, clientID, hostID); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("revoked pairing still active: %v", err)
		}
		// After revocation the same pair may pair again.
		if err := s.CreatePairing(ctx, dup); err != nil {
			t.Fatalf("re-pair after revoke: %v", err)
		}
		if _, err := s.RevokePairing(ctx, "missing", hostID, t0); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("revoke missing err = %v", err)
		}
	})

	t.Run("audit and expiry sweep", func(t *testing.T) {
		s := newStore(t)
		_ = s.CreateDevice(ctx, dev(clientID, "android"))
		_ = s.AppendAudit(ctx, store.AuditEvent{At: t0, Kind: "old", DeviceID: clientID})
		_ = s.AppendAudit(ctx, store.AuditEvent{At: t0.Add(time.Hour), Kind: "new", DeviceID: hostID, PeerDeviceID: clientID})
		_ = s.CreateChallenge(ctx, store.Challenge{ID: "c", DeviceID: clientID, Nonce: []byte("n"), ExpiresAt: t0})
		_ = s.CreateToken(ctx, store.Token{Hash: sha256.Sum256([]byte("t")), DeviceID: clientID, ExpiresAt: t0})
		if err := s.DeleteExpired(ctx, t0, t0.Add(30*time.Minute)); err != nil {
			t.Fatal(err)
		}
		ev, err := s.ListAudit(ctx, clientID, 10)
		if err != nil || len(ev) != 1 || ev[0].Kind != "new" {
			t.Fatalf("audit after sweep = %+v, %v", ev, err)
		}
		if _, err := s.ConsumeChallenge(ctx, "c", clientID, t0.Add(-time.Hour)); !errors.Is(err, store.ErrNotFound) {
			t.Fatalf("expired challenge survived sweep: %v", err)
		}
		if err := s.Ping(ctx); err != nil {
			t.Fatal(err)
		}
	})
}

func TestMemoryStoreContract(t *testing.T) {
	runContract(t, func(t *testing.T) store.Store { return store.NewMemoryStore() })
}

// TestPostgresStoreContract runs only when MYBUDDY_TEST_DATABASE_URL points at a
// disposable database whose name contains "mybuddy_test" (tables are truncated).
// scripts/pg-test.sh creates such a database in a throw-away cluster.
func TestPostgresStoreContract(t *testing.T) {
	dsn := os.Getenv("MYBUDDY_TEST_DATABASE_URL")
	if dsn == "" {
		t.Skip("not run — set MYBUDDY_TEST_DATABASE_URL (see scripts/pg-test.sh)")
	}
	u, err := url.Parse(dsn)
	if err != nil || !strings.Contains(u.Path, "mybuddy_test") {
		t.Fatalf("refusing to run destructive tests against %q: database name must contain mybuddy_test", u.Redacted())
	}
	ctx := context.Background()
	runContract(t, func(t *testing.T) store.Store {
		s, err := store.OpenPostgres(ctx, dsn)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.Pool().Exec(ctx, `TRUNCATE audit_events, auth_tokens, auth_challenges, pairings, devices`); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(s.Close)
		return s
	})
}
