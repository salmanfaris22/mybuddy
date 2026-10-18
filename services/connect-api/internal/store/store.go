// Package store persists MyBuddy Connect metadata: device public keys, auth
// challenges, hashed bearer tokens, pairings, revocations and minimal audit
// events. It never stores screen frames, audio, clipboard data, files,
// transcripts, notifications or AI conversations.
package store

import (
	"context"
	"errors"
	"time"
)

var (
	ErrNotFound = errors.New("not found")
	ErrConflict = errors.New("conflict")
	ErrExpired  = errors.New("expired")
	ErrUsed     = errors.New("already used")
)

// Device is a registered device identity.
type Device struct {
	ID         string
	PublicKey  []byte // SPKI DER
	Platform   string // "android" | "macos"
	CreatedAt  time.Time
	LastSeenAt time.Time
}

// Challenge is a single-use authentication nonce.
type Challenge struct {
	ID        string
	DeviceID  string
	Nonce     []byte
	ExpiresAt time.Time
}

// Token is a bearer token, stored only as its SHA-256 hash.
type Token struct {
	Hash      [32]byte
	DeviceID  string
	ExpiresAt time.Time
}

// Pairing links a host (Mac) and a client (phone) that paired on the LAN.
type Pairing struct {
	ID             string
	HostDeviceID   string
	ClientDeviceID string
	CreatedAt      string // statement timestamp (RFC 3339), as signed by both devices
	RegisteredAt   time.Time
	RevokedAt      *time.Time
	RevokedBy      string
}

// Active reports whether the pairing has not been revoked.
func (p Pairing) Active() bool { return p.RevokedAt == nil }

// Involves reports whether deviceID is one of the two parties.
func (p Pairing) Involves(deviceID string) bool {
	return p.HostDeviceID == deviceID || p.ClientDeviceID == deviceID
}

// Peer returns the other party.
func (p Pairing) Peer(deviceID string) string {
	if p.HostDeviceID == deviceID {
		return p.ClientDeviceID
	}
	return p.HostDeviceID
}

// AuditEvent is privacy-preserving metadata about a security-relevant action.
type AuditEvent struct {
	At           time.Time
	Kind         string // e.g. "device.registered", "pairing.revoked"
	DeviceID     string
	PeerDeviceID string
}

// Store is implemented by MemoryStore and PostgresStore.
type Store interface {
	CreateDevice(ctx context.Context, d Device) error
	GetDevice(ctx context.Context, id string) (Device, error)
	TouchDevice(ctx context.Context, id string, at time.Time) error

	CreateChallenge(ctx context.Context, c Challenge) error
	// ConsumeChallenge atomically removes the challenge and returns it. It fails with
	// ErrNotFound if it does not exist (or was already consumed) or belongs to another
	// device, and ErrExpired if it has expired (it is still removed).
	ConsumeChallenge(ctx context.Context, id, deviceID string, now time.Time) (Challenge, error)

	CreateToken(ctx context.Context, t Token) error
	LookupToken(ctx context.Context, hash [32]byte, now time.Time) (Token, error)

	CreatePairing(ctx context.Context, p Pairing) error
	GetPairing(ctx context.Context, id string) (Pairing, error)
	ListPairings(ctx context.Context, deviceID string) ([]Pairing, error)
	ActivePairingBetween(ctx context.Context, a, b string) (Pairing, error)
	RevokePairing(ctx context.Context, id, by string, at time.Time) (Pairing, error)

	AppendAudit(ctx context.Context, e AuditEvent) error
	ListAudit(ctx context.Context, deviceID string, limit int) ([]AuditEvent, error)

	// DeleteExpired removes expired challenges/tokens and audit events older than auditBefore.
	DeleteExpired(ctx context.Context, now, auditBefore time.Time) error
	Ping(ctx context.Context) error
	Close()
}
