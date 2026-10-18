package store

import (
	"context"
	"sort"
	"sync"
	"time"
)

// MemoryStore is a process-local Store for development and tests.
// Data is lost on restart.
type MemoryStore struct {
	mu         sync.Mutex
	devices    map[string]Device
	challenges map[string]Challenge
	tokens     map[[32]byte]Token
	pairings   map[string]Pairing
	audit      []AuditEvent
	maxAudit   int
}

// NewMemoryStore returns an empty store.
func NewMemoryStore() *MemoryStore {
	return &MemoryStore{
		devices:    map[string]Device{},
		challenges: map[string]Challenge{},
		tokens:     map[[32]byte]Token{},
		pairings:   map[string]Pairing{},
		maxAudit:   10_000,
	}
}

func (m *MemoryStore) CreateDevice(_ context.Context, d Device) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.devices[d.ID]; ok {
		return ErrConflict
	}
	d.PublicKey = append([]byte(nil), d.PublicKey...)
	m.devices[d.ID] = d
	return nil
}

func (m *MemoryStore) GetDevice(_ context.Context, id string) (Device, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[id]
	if !ok {
		return Device{}, ErrNotFound
	}
	d.PublicKey = append([]byte(nil), d.PublicKey...)
	return d, nil
}

func (m *MemoryStore) TouchDevice(_ context.Context, id string, at time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	d, ok := m.devices[id]
	if !ok {
		return ErrNotFound
	}
	d.LastSeenAt = at
	m.devices[id] = d
	return nil
}

func (m *MemoryStore) CreateChallenge(_ context.Context, c Challenge) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.challenges[c.ID]; ok {
		return ErrConflict
	}
	m.challenges[c.ID] = c
	return nil
}

func (m *MemoryStore) ConsumeChallenge(_ context.Context, id, deviceID string, now time.Time) (Challenge, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	c, ok := m.challenges[id]
	if !ok || c.DeviceID != deviceID {
		return Challenge{}, ErrNotFound
	}
	delete(m.challenges, id)
	if !now.Before(c.ExpiresAt) {
		return Challenge{}, ErrExpired
	}
	return c, nil
}

func (m *MemoryStore) CreateToken(_ context.Context, t Token) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.tokens[t.Hash]; ok {
		return ErrConflict
	}
	m.tokens[t.Hash] = t
	return nil
}

func (m *MemoryStore) LookupToken(_ context.Context, hash [32]byte, now time.Time) (Token, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	t, ok := m.tokens[hash]
	if !ok || !now.Before(t.ExpiresAt) {
		return Token{}, ErrNotFound
	}
	return t, nil
}

func (m *MemoryStore) CreatePairing(_ context.Context, p Pairing) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.pairings[p.ID]; ok {
		return ErrConflict
	}
	for _, e := range m.pairings {
		if e.Active() && e.HostDeviceID == p.HostDeviceID && e.ClientDeviceID == p.ClientDeviceID {
			return ErrConflict
		}
	}
	m.pairings[p.ID] = p
	return nil
}

func (m *MemoryStore) GetPairing(_ context.Context, id string) (Pairing, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.pairings[id]
	if !ok {
		return Pairing{}, ErrNotFound
	}
	return p, nil
}

func (m *MemoryStore) ListPairings(_ context.Context, deviceID string) ([]Pairing, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []Pairing{}
	for _, p := range m.pairings {
		if p.Involves(deviceID) {
			out = append(out, p)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].RegisteredAt.Before(out[j].RegisteredAt) })
	return out, nil
}

func (m *MemoryStore) ActivePairingBetween(_ context.Context, a, b string) (Pairing, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, p := range m.pairings {
		if !p.Active() {
			continue
		}
		if (p.HostDeviceID == a && p.ClientDeviceID == b) || (p.HostDeviceID == b && p.ClientDeviceID == a) {
			return p, nil
		}
	}
	return Pairing{}, ErrNotFound
}

func (m *MemoryStore) RevokePairing(_ context.Context, id, by string, at time.Time) (Pairing, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	p, ok := m.pairings[id]
	if !ok {
		return Pairing{}, ErrNotFound
	}
	if p.RevokedAt == nil {
		t := at
		p.RevokedAt = &t
		p.RevokedBy = by
		m.pairings[id] = p
	}
	return p, nil
}

func (m *MemoryStore) AppendAudit(_ context.Context, e AuditEvent) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.audit = append(m.audit, e)
	if len(m.audit) > m.maxAudit {
		m.audit = append([]AuditEvent(nil), m.audit[len(m.audit)-m.maxAudit:]...)
	}
	return nil
}

func (m *MemoryStore) ListAudit(_ context.Context, deviceID string, limit int) ([]AuditEvent, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := []AuditEvent{}
	for i := len(m.audit) - 1; i >= 0 && len(out) < limit; i-- {
		if e := m.audit[i]; e.DeviceID == deviceID || e.PeerDeviceID == deviceID {
			out = append(out, e)
		}
	}
	return out, nil
}

func (m *MemoryStore) DeleteExpired(_ context.Context, now, auditBefore time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, c := range m.challenges {
		if !now.Before(c.ExpiresAt) {
			delete(m.challenges, id)
		}
	}
	for h, t := range m.tokens {
		if !now.Before(t.ExpiresAt) {
			delete(m.tokens, h)
		}
	}
	kept := m.audit[:0]
	for _, e := range m.audit {
		if !e.At.Before(auditBefore) {
			kept = append(kept, e)
		}
	}
	m.audit = kept
	return nil
}

func (m *MemoryStore) Ping(context.Context) error { return nil }
func (m *MemoryStore) Close()                     {}
