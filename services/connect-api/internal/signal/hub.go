// Package signal implements the /v1/signal opaque relay (docs/PROTOCOL.md §7.3).
//
// The hub forwards base64url-encoded MBH1 frames between devices that share an
// active pairing. It never parses or stores the relayed data.
package signal

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"regexp"
	"sync"
	"time"

	"github.com/coder/websocket"

	"mybuddy.local/connect-api/internal/mbcrypto"
	"mybuddy.local/connect-api/internal/ratelimit"
	"mybuddy.local/connect-api/internal/store"
)

const (
	// MaxMessageBytes is the maximum outer message size accepted from a client.
	MaxMessageBytes = 96 * 1024
	// MaxDataBytes is the maximum decoded relay payload.
	MaxDataBytes  = 64 * 1024
	sendQueueSize = 64
	maxViolations = 3
	writeTimeout  = 10 * time.Second
	pingInterval  = 30 * time.Second
)

var msgIDPattern = regexp.MustCompile(`^[A-Za-z0-9_-]{1,64}$`)

// Hub tracks one live connection per device.
type Hub struct {
	store store.Store
	now   func() time.Time
	log   *slog.Logger

	// Rate and Burst configure the per-connection token bucket.
	Rate  float64
	Burst int

	mu    sync.Mutex
	conns map[string]*conn
}

// NewHub creates a hub.
func NewHub(s store.Store, now func() time.Time, log *slog.Logger) *Hub {
	return &Hub{store: s, now: now, log: log, Rate: 50, Burst: 100, conns: map[string]*conn{}}
}

type conn struct {
	deviceID string
	ws       *websocket.Conn
	send     chan []byte
	done     chan struct{}
	once     sync.Once
}

func (c *conn) shutdown(code websocket.StatusCode, reason string) {
	c.once.Do(func() {
		close(c.done)
		_ = c.ws.Close(code, reason)
	})
}

// enqueue queues a message without blocking; it reports false if the queue is full or closed.
func (c *conn) enqueue(msg []byte) bool {
	select {
	case <-c.done:
		return false
	default:
	}
	select {
	case c.send <- msg:
		return true
	default:
		return false
	}
}

type inbound struct {
	Type string `json:"type"`
	To   string `json:"to,omitempty"`
	ID   string `json:"id,omitempty"`
	Data string `json:"data,omitempty"`
}

type peerPresence struct {
	DeviceID string `json:"deviceId"`
	Online   bool   `json:"online"`
}

func encode(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}

func errorMsg(code, message, id string) []byte {
	m := map[string]string{"type": "error", "code": code, "message": message}
	if id != "" {
		m["id"] = id
	}
	return encode(m)
}

// Online reports whether deviceID currently has a live connection.
func (h *Hub) Online(deviceID string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	_, ok := h.conns[deviceID]
	return ok
}

// Serve runs the relay for an authenticated device until the socket closes,
// ctx is cancelled, or the bearer token expires.
func (h *Hub) Serve(ctx context.Context, ws *websocket.Conn, deviceID string, tokenExpiresAt time.Time) {
	ws.SetReadLimit(MaxMessageBytes)
	c := &conn{deviceID: deviceID, ws: ws, send: make(chan []byte, sendQueueSize), done: make(chan struct{})}

	h.mu.Lock()
	old := h.conns[deviceID]
	h.conns[deviceID] = c
	h.mu.Unlock()
	if old != nil {
		// Close outside the lock: the close handshake can take seconds.
		go old.shutdown(websocket.StatusPolicyViolation, "replaced by a newer connection")
	}
	h.audit(ctx, "signal.connected", deviceID, "")
	h.broadcastPresence(ctx, deviceID, true)

	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	go h.writeLoop(ctx, c, tokenExpiresAt)

	h.readLoop(ctx, c)

	c.shutdown(websocket.StatusNormalClosure, "")
	h.mu.Lock()
	current := h.conns[deviceID] == c
	if current {
		delete(h.conns, deviceID)
	}
	h.mu.Unlock()
	h.audit(context.WithoutCancel(ctx), "signal.disconnected", deviceID, "")
	if current {
		h.broadcastPresence(context.WithoutCancel(ctx), deviceID, false)
	}
}

func (h *Hub) writeLoop(ctx context.Context, c *conn, tokenExpiresAt time.Time) {
	ping := time.NewTicker(pingInterval)
	defer ping.Stop()
	expiry := time.NewTimer(tokenExpiresAt.Sub(h.now()))
	defer expiry.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-c.done:
			return
		case msg := <-c.send:
			wctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.ws.Write(wctx, websocket.MessageText, msg)
			cancel()
			if err != nil {
				c.shutdown(websocket.StatusInternalError, "write failed")
				return
			}
		case <-ping.C:
			pctx, cancel := context.WithTimeout(ctx, writeTimeout)
			err := c.ws.Ping(pctx)
			cancel()
			if err != nil {
				c.shutdown(websocket.StatusGoingAway, "ping timeout")
				return
			}
		case <-expiry.C:
			wctx, cancel := context.WithTimeout(ctx, writeTimeout)
			_ = c.ws.Write(wctx, websocket.MessageText, errorMsg("token_expired", "bearer token expired; reconnect with a new token", ""))
			cancel()
			c.shutdown(websocket.StatusPolicyViolation, "token expired")
			return
		}
	}
}

func (h *Hub) readLoop(ctx context.Context, c *conn) {
	bucket := ratelimit.NewBucket(h.Rate, h.Burst, h.now())
	violations := 0
	violate := func(code, message, id string) bool {
		violations++
		c.enqueue(errorMsg(code, message, id))
		if violations >= maxViolations {
			c.shutdown(websocket.StatusPolicyViolation, "too many protocol violations")
			return true
		}
		return false
	}
	for {
		typ, data, err := c.ws.Read(ctx)
		if err != nil {
			return
		}
		if !bucket.Allow(h.now()) {
			if violate("rate_limited", "too many messages", "") {
				return
			}
			continue
		}
		if typ != websocket.MessageText {
			if violate("bad_message", "text frames only", "") {
				return
			}
			continue
		}
		var m inbound
		dec := json.NewDecoder(bytes.NewReader(data))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&m); err != nil {
			if violate("bad_message", "malformed message", "") {
				return
			}
			continue
		}
		switch m.Type {
		case "ping":
			c.enqueue([]byte(`{"type":"pong"}`))
		case "presence":
			c.enqueue(encode(map[string]any{"type": "presence", "peers": h.peers(ctx, c.deviceID)}))
		case "relay":
			if stop := h.relay(ctx, c, m, violate); stop {
				return
			}
		default:
			if violate("unknown_type", "unsupported message type", m.ID) {
				return
			}
		}
	}
}

// relay forwards m from c to m.To. It returns true if the connection was closed.
func (h *Hub) relay(ctx context.Context, c *conn, m inbound, violate func(code, message, id string) bool) bool {
	if !mbcrypto.ValidDeviceID(m.To) || m.To == c.deviceID || !msgIDPattern.MatchString(m.ID) {
		return violate("bad_message", "relay needs a valid peer device id and message id", "")
	}
	raw, err := mbcrypto.B64U.DecodeString(m.Data)
	if err != nil || len(raw) == 0 || len(raw) > MaxDataBytes {
		return violate("bad_message", "relay data must be 1..65536 bytes of base64url", m.ID)
	}
	if _, err := h.store.ActivePairingBetween(ctx, c.deviceID, m.To); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			return violate("not_paired", "no active pairing with that device", m.ID)
		}
		c.enqueue(errorMsg("unavailable", "temporarily unavailable", m.ID))
		return false
	}
	h.mu.Lock()
	peer, online := h.conns[m.To]
	h.mu.Unlock()
	if !online {
		c.enqueue(errorMsg("peer_offline", "peer is not connected", m.ID))
		return false
	}
	out := encode(map[string]string{"type": "relay", "from": c.deviceID, "id": m.ID, "data": m.Data})
	if !peer.enqueue(out) {
		c.enqueue(errorMsg("peer_busy", "peer is not keeping up; retry", m.ID))
	}
	return false
}

func (h *Hub) peers(ctx context.Context, deviceID string) []peerPresence {
	pairings, err := h.store.ListPairings(ctx, deviceID)
	if err != nil {
		return []peerPresence{}
	}
	out := []peerPresence{}
	for _, p := range pairings {
		if !p.Active() {
			continue
		}
		peer := p.Peer(deviceID)
		out = append(out, peerPresence{DeviceID: peer, Online: h.Online(peer)})
	}
	return out
}

func (h *Hub) broadcastPresence(ctx context.Context, deviceID string, online bool) {
	pairings, err := h.store.ListPairings(ctx, deviceID)
	if err != nil {
		return
	}
	msg := encode(map[string]any{"type": "presence", "peers": []peerPresence{{DeviceID: deviceID, Online: online}}})
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, p := range pairings {
		if !p.Active() {
			continue
		}
		if peer, ok := h.conns[p.Peer(deviceID)]; ok {
			peer.enqueue(msg)
		}
	}
}

// PairingRevoked notifies both parties (if connected). Relay authorization is
// checked against the store on every message, so revocation is effective immediately.
func (h *Hub) PairingRevoked(p store.Pairing) {
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, id := range []string{p.HostDeviceID, p.ClientDeviceID} {
		if c, ok := h.conns[id]; ok {
			c.enqueue(encode(map[string]string{"type": "pairing.revoked", "pairingId": p.ID, "peerDeviceId": p.Peer(id)}))
		}
	}
}

func (h *Hub) audit(ctx context.Context, kind, deviceID, peer string) {
	if err := h.store.AppendAudit(ctx, store.AuditEvent{At: h.now(), Kind: kind, DeviceID: deviceID, PeerDeviceID: peer}); err != nil {
		h.log.Warn("audit append failed", "kind", kind, "err", err)
	}
}
