// Package api implements the MyBuddy Connect HTTP API (docs/PROTOCOL.md §7).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"

	"mybuddy.local/connect-api/internal/config"
	"mybuddy.local/connect-api/internal/mbcrypto"
	"mybuddy.local/connect-api/internal/ratelimit"
	"mybuddy.local/connect-api/internal/signal"
	"mybuddy.local/connect-api/internal/store"
	"mybuddy.local/connect-api/internal/turn"
)

const maxBodyBytes = 16 * 1024

// Server wires handlers to the store, signaling hub and TURN issuer.
type Server struct {
	cfg     config.Config
	store   store.Store
	hub     *signal.Hub
	turn    turn.Issuer
	now     func() time.Time
	log     *slog.Logger
	limiter *ratelimit.Keyed
}

// Options configure a Server. Now defaults to time.Now.
type Options struct {
	Config config.Config
	Store  store.Store
	Now    func() time.Time
	Log    *slog.Logger
	// UnauthRatePerSecond/UnauthBurst limit unauthenticated requests per client IP.
	// Defaults: 0.5/s (30 per minute) with a burst of 10.
	UnauthRatePerSecond float64
	UnauthBurst         int
}

// New builds a Server.
func New(o Options) *Server {
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.Log == nil {
		o.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if o.UnauthRatePerSecond <= 0 {
		o.UnauthRatePerSecond = 0.5
	}
	if o.UnauthBurst <= 0 {
		o.UnauthBurst = 10
	}
	return &Server{
		cfg:     o.Config,
		store:   o.Store,
		hub:     signal.NewHub(o.Store, o.Now, o.Log),
		turn:    turn.Issuer{Secret: o.Config.TurnSecret, URLs: o.Config.TurnURLs, TTL: o.Config.TurnTTL},
		now:     o.Now,
		log:     o.Log,
		limiter: ratelimit.NewKeyed(o.UnauthRatePerSecond, o.UnauthBurst, 10*time.Minute),
	}
}

// Hub exposes the signaling hub (tests).
func (s *Server) Hub() *signal.Hub { return s.hub }

// Handler returns the routed, middleware-wrapped handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", s.healthz)
	mux.HandleFunc("GET /readyz", s.readyz)
	mux.HandleFunc("POST /v1/devices", s.limited(s.registerDevice))
	mux.HandleFunc("POST /v1/auth/challenge", s.limited(s.createChallenge))
	mux.HandleFunc("POST /v1/auth/token", s.limited(s.issueToken))
	mux.HandleFunc("GET /v1/me", s.authed(s.me))
	mux.HandleFunc("POST /v1/pairings", s.authed(s.createPairing))
	mux.HandleFunc("GET /v1/pairings", s.authed(s.listPairings))
	mux.HandleFunc("DELETE /v1/pairings/{id}", s.authed(s.revokePairing))
	mux.HandleFunc("GET /v1/turn-credentials", s.authed(s.turnCredentials))
	mux.HandleFunc("GET /v1/signal", s.authed(s.signal))
	return s.recoverer(s.secureHeaders(mux))
}

// RunMaintenance periodically deletes expired challenges/tokens and old audit events.
func (s *Server) RunMaintenance(ctx context.Context, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			now := s.now()
			if err := s.store.DeleteExpired(ctx, now, now.Add(-s.cfg.AuditRetention)); err != nil {
				s.log.Warn("maintenance failed", "err", err)
			}
			s.limiter.Sweep(now)
		}
	}
}

// ---------- middleware ----------

type ctxKey int

const (
	deviceKey ctxKey = iota
	tokenExpiryKey
)

func (s *Server) recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if rec := recover(); rec != nil {
				s.log.Error("panic in handler", "path", r.URL.Path, "panic", rec)
				writeError(w, http.StatusInternalServerError, "internal", "internal error")
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func (s *Server) secureHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("Cache-Control", "no-store")
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("Referrer-Policy", "no-referrer")
		next.ServeHTTP(w, r)
	})
}

func (s *Server) clientIP(r *http.Request) string {
	if s.cfg.TrustProxyHeaders {
		if xff := r.Header.Get("X-Forwarded-For"); xff != "" {
			parts := strings.Split(xff, ",")
			// The right-most entry is the one appended by our (single, trusted) proxy.
			if ip := strings.TrimSpace(parts[len(parts)-1]); net.ParseIP(ip) != nil {
				return ip
			}
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return host
}

func (s *Server) limited(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.limiter.Allow(s.clientIP(r), s.now()) {
			writeError(w, http.StatusTooManyRequests, "rate_limited", "too many requests; slow down")
			return
		}
		next(w, r)
	}
}

func (s *Server) authed(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		token, ok := strings.CutPrefix(auth, "Bearer ")
		if !ok || len(token) != 43 {
			writeError(w, http.StatusUnauthorized, "unauthorized", "missing or malformed bearer token")
			return
		}
		t, err := s.store.LookupToken(r.Context(), mbcrypto.HashToken(token), s.now())
		if err != nil {
			writeError(w, http.StatusUnauthorized, "unauthorized", "invalid or expired token")
			return
		}
		ctx := context.WithValue(r.Context(), deviceKey, t.DeviceID)
		ctx = context.WithValue(ctx, tokenExpiryKey, t.ExpiresAt)
		next(w, r.WithContext(ctx))
	}
}

func callerID(r *http.Request) string { return r.Context().Value(deviceKey).(string) }

// ---------- helpers ----------

type apiError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]apiError{"error": {Code: code, Message: message}})
}

// decodeJSON strictly decodes a single JSON object (unknown fields rejected).
func decodeJSON(w http.ResponseWriter, r *http.Request, dst any) bool {
	r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			writeError(w, http.StatusRequestEntityTooLarge, "too_large", "request body too large")
		} else {
			writeError(w, http.StatusBadRequest, "bad_request", "malformed JSON body")
		}
		return false
	}
	if dec.More() {
		writeError(w, http.StatusBadRequest, "bad_request", "unexpected data after JSON body")
		return false
	}
	return true
}

func (s *Server) audit(ctx context.Context, kind, deviceID, peer string) {
	if err := s.store.AppendAudit(ctx, store.AuditEvent{At: s.now(), Kind: kind, DeviceID: deviceID, PeerDeviceID: peer}); err != nil {
		s.log.Warn("audit append failed", "kind", kind, "err", err)
	}
}

func randomID(prefix string) string {
	return prefix + mbcrypto.B64U.EncodeToString(mbcrypto.RandomBytes(16))
}

// ---------- health ----------

func (s *Server) healthz(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]string{"status": "ok"})
}

func (s *Server) readyz(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
	defer cancel()
	if err := s.store.Ping(ctx); err != nil {
		writeError(w, http.StatusServiceUnavailable, "store_unavailable", "store not reachable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"status": "ready"})
}

// ---------- devices & auth ----------

type registerRequest struct {
	PublicKey string `json:"publicKey"`
	Platform  string `json:"platform"`
	Proof     string `json:"proof"`
}

func (s *Server) registerDevice(w http.ResponseWriter, r *http.Request) {
	var req registerRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if req.Platform != "android" && req.Platform != "macos" {
		writeError(w, http.StatusBadRequest, "bad_platform", "platform must be android or macos")
		return
	}
	spki, err := mbcrypto.B64U.DecodeString(req.PublicKey)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_key", "publicKey must be base64url SPKI DER")
		return
	}
	proof, err := mbcrypto.B64U.DecodeString(req.Proof)
	if err != nil {
		writeError(w, http.StatusBadRequest, "bad_proof", "proof must be base64url DER")
		return
	}
	if _, err := mbcrypto.ParsePublicKey(spki); err != nil {
		writeError(w, http.StatusBadRequest, "bad_key", "publicKey must be a P-256 key")
		return
	}
	if err := mbcrypto.VerifySPKI(spki, mbcrypto.RegisterStatement(spki, req.Platform), proof); err != nil {
		writeError(w, http.StatusUnauthorized, "bad_proof", "proof of key possession failed")
		return
	}
	id := mbcrypto.DeviceID(spki)
	now := s.now()
	err = s.store.CreateDevice(r.Context(), store.Device{ID: id, PublicKey: spki, Platform: req.Platform, CreatedAt: now, LastSeenAt: now})
	switch {
	case err == nil:
		s.audit(r.Context(), "device.registered", id, "")
		writeJSON(w, http.StatusCreated, map[string]string{"deviceId": id})
	case errors.Is(err, store.ErrConflict):
		existing, gerr := s.store.GetDevice(r.Context(), id)
		if gerr == nil && mbcrypto.ConstantTimeEqual(existing.PublicKey, spki) && existing.Platform == req.Platform {
			writeJSON(w, http.StatusOK, map[string]string{"deviceId": id})
			return
		}
		writeError(w, http.StatusConflict, "conflict", "device already registered")
	default:
		s.log.Error("create device", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
	}
}

type challengeRequest struct {
	DeviceID string `json:"deviceId"`
}

func (s *Server) createChallenge(w http.ResponseWriter, r *http.Request) {
	var req challengeRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	if !mbcrypto.ValidDeviceID(req.DeviceID) {
		writeError(w, http.StatusBadRequest, "bad_device_id", "deviceId must be 32 lowercase hex characters")
		return
	}
	// Challenges are issued for unknown devices too, so device existence is not revealed.
	c := store.Challenge{ID: randomID("ch_"), DeviceID: req.DeviceID, Nonce: mbcrypto.RandomBytes(32), ExpiresAt: s.now().Add(s.cfg.ChallengeTTL)}
	if err := s.store.CreateChallenge(r.Context(), c); err != nil {
		s.log.Error("create challenge", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{
		"challengeId": c.ID,
		"nonce":       mbcrypto.B64U.EncodeToString(c.Nonce),
		"expiresAt":   c.ExpiresAt.UTC().Format(time.RFC3339Nano),
	})
}

type tokenRequest struct {
	ChallengeID string `json:"challengeId"`
	DeviceID    string `json:"deviceId"`
	Signature   string `json:"signature"`
}

func (s *Server) issueToken(w http.ResponseWriter, r *http.Request) {
	var req tokenRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	fail := func() { writeError(w, http.StatusUnauthorized, "auth_failed", "authentication failed") }
	if !mbcrypto.ValidDeviceID(req.DeviceID) || len(req.ChallengeID) > 64 {
		fail()
		return
	}
	sig, err := mbcrypto.B64U.DecodeString(req.Signature)
	if err != nil {
		fail()
		return
	}
	ch, err := s.store.ConsumeChallenge(r.Context(), req.ChallengeID, req.DeviceID, s.now())
	if err != nil {
		fail()
		return
	}
	dev, err := s.store.GetDevice(r.Context(), req.DeviceID)
	if err != nil {
		fail()
		return
	}
	if err := mbcrypto.VerifySPKI(dev.PublicKey, mbcrypto.AuthStatement(ch.ID, ch.Nonce, dev.ID), sig); err != nil {
		fail()
		return
	}
	token := mbcrypto.B64U.EncodeToString(mbcrypto.RandomBytes(32))
	expires := s.now().Add(s.cfg.TokenTTL)
	if err := s.store.CreateToken(r.Context(), store.Token{Hash: mbcrypto.HashToken(token), DeviceID: dev.ID, ExpiresAt: expires}); err != nil {
		s.log.Error("create token", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
		return
	}
	_ = s.store.TouchDevice(r.Context(), dev.ID, s.now())
	s.audit(r.Context(), "auth.token_issued", dev.ID, "")
	writeJSON(w, http.StatusOK, map[string]string{"token": token, "expiresAt": expires.UTC().Format(time.RFC3339Nano)})
}

// ---------- pairings ----------

type pairingJSON struct {
	PairingID      string  `json:"pairingId"`
	HostDeviceID   string  `json:"hostDeviceId"`
	ClientDeviceID string  `json:"clientDeviceId"`
	CreatedAt      string  `json:"createdAt"`
	RevokedAt      *string `json:"revokedAt,omitempty"`
}

func toJSON(p store.Pairing) pairingJSON {
	out := pairingJSON{PairingID: p.ID, HostDeviceID: p.HostDeviceID, ClientDeviceID: p.ClientDeviceID, CreatedAt: p.CreatedAt}
	if p.RevokedAt != nil {
		s := p.RevokedAt.UTC().Format(time.RFC3339Nano)
		out.RevokedAt = &s
	}
	return out
}

func (s *Server) me(w http.ResponseWriter, r *http.Request) {
	id := callerID(r)
	dev, err := s.store.GetDevice(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusUnauthorized, "unauthorized", "device not found")
		return
	}
	list, err := s.store.ListPairings(r.Context(), id)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
		return
	}
	out := make([]pairingJSON, 0, len(list))
	for _, p := range list {
		out = append(out, toJSON(p))
	}
	writeJSON(w, http.StatusOK, map[string]any{"deviceId": dev.ID, "platform": dev.Platform, "pairings": out})
}

type pairingRequest struct {
	HostDeviceID    string `json:"hostDeviceId"`
	ClientDeviceID  string `json:"clientDeviceId"`
	CreatedAt       string `json:"createdAt"`
	HostSignature   string `json:"hostSignature"`
	ClientSignature string `json:"clientSignature"`
}

func (s *Server) createPairing(w http.ResponseWriter, r *http.Request) {
	var req pairingRequest
	if !decodeJSON(w, r, &req) {
		return
	}
	caller := callerID(r)
	if req.HostDeviceID != caller {
		writeError(w, http.StatusForbidden, "not_host", "only the host device can register a pairing")
		return
	}
	if !mbcrypto.ValidDeviceID(req.ClientDeviceID) || req.ClientDeviceID == req.HostDeviceID {
		writeError(w, http.StatusBadRequest, "bad_device_id", "invalid client device id")
		return
	}
	created, err := time.Parse(time.RFC3339Nano, req.CreatedAt)
	if err != nil || len(req.CreatedAt) > 40 {
		writeError(w, http.StatusBadRequest, "bad_timestamp", "createdAt must be RFC 3339")
		return
	}
	if d := s.now().Sub(created); d > s.cfg.PairingClockSkew || d < -s.cfg.PairingClockSkew {
		writeError(w, http.StatusBadRequest, "stale_statement", "pairing statement is too old or in the future")
		return
	}
	host, err := s.store.GetDevice(r.Context(), req.HostDeviceID)
	if err != nil || host.Platform != "macos" {
		writeError(w, http.StatusBadRequest, "bad_host", "host must be a registered macOS device")
		return
	}
	client, err := s.store.GetDevice(r.Context(), req.ClientDeviceID)
	if err != nil {
		writeError(w, http.StatusBadRequest, "unknown_device", "client device is not registered")
		return
	}
	hostSig, err1 := mbcrypto.B64U.DecodeString(req.HostSignature)
	clientSig, err2 := mbcrypto.B64U.DecodeString(req.ClientSignature)
	statement := mbcrypto.PairingStatement(req.HostDeviceID, req.ClientDeviceID, req.CreatedAt)
	if err1 != nil || err2 != nil ||
		mbcrypto.VerifySPKI(host.PublicKey, statement, hostSig) != nil ||
		mbcrypto.VerifySPKI(client.PublicKey, statement, clientSig) != nil {
		writeError(w, http.StatusBadRequest, "bad_signature", "both devices must sign the pairing statement")
		return
	}
	if existing, err := s.store.ActivePairingBetween(r.Context(), host.ID, client.ID); err == nil {
		writeJSON(w, http.StatusOK, toJSON(existing))
		return
	}
	p := store.Pairing{ID: randomID("pr_"), HostDeviceID: host.ID, ClientDeviceID: client.ID, CreatedAt: req.CreatedAt, RegisteredAt: s.now()}
	if err := s.store.CreatePairing(r.Context(), p); err != nil {
		if errors.Is(err, store.ErrConflict) {
			if existing, gerr := s.store.ActivePairingBetween(r.Context(), host.ID, client.ID); gerr == nil {
				writeJSON(w, http.StatusOK, toJSON(existing))
				return
			}
		}
		s.log.Error("create pairing", "err", err)
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
		return
	}
	s.audit(r.Context(), "pairing.created", host.ID, client.ID)
	writeJSON(w, http.StatusCreated, toJSON(p))
}

func (s *Server) listPairings(w http.ResponseWriter, r *http.Request) {
	list, err := s.store.ListPairings(r.Context(), callerID(r))
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
		return
	}
	out := make([]pairingJSON, 0, len(list))
	for _, p := range list {
		out = append(out, toJSON(p))
	}
	writeJSON(w, http.StatusOK, map[string]any{"pairings": out})
}

func (s *Server) revokePairing(w http.ResponseWriter, r *http.Request) {
	caller := callerID(r)
	p, err := s.store.GetPairing(r.Context(), r.PathValue("id"))
	if err != nil || !p.Involves(caller) {
		// Do not reveal pairings the caller is not part of.
		writeError(w, http.StatusNotFound, "not_found", "pairing not found")
		return
	}
	p, err = s.store.RevokePairing(r.Context(), p.ID, caller, s.now())
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
		return
	}
	s.hub.PairingRevoked(p)
	s.audit(r.Context(), "pairing.revoked", caller, p.Peer(caller))
	w.WriteHeader(http.StatusNoContent)
}

// ---------- TURN & signaling ----------

func (s *Server) turnCredentials(w http.ResponseWriter, r *http.Request) {
	if !s.turn.Configured() {
		writeError(w, http.StatusServiceUnavailable, "turn_not_configured", "this server has no TURN relay configured")
		return
	}
	caller := callerID(r)
	list, err := s.store.ListPairings(r.Context(), caller)
	if err != nil {
		writeError(w, http.StatusInternalServerError, "internal", "internal error")
		return
	}
	active := false
	for _, p := range list {
		active = active || p.Active()
	}
	if !active {
		writeError(w, http.StatusForbidden, "no_active_pairing", "TURN credentials require an active pairing")
		return
	}
	writeJSON(w, http.StatusOK, s.turn.Issue(caller, s.now()))
}

func (s *Server) signal(w http.ResponseWriter, r *http.Request) {
	caller := callerID(r)
	expires := r.Context().Value(tokenExpiryKey).(time.Time)
	// The server's ReadTimeout would otherwise persist on the hijacked connection
	// and kill long-lived relays; liveness is handled by WebSocket pings instead.
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	_ = rc.SetWriteDeadline(time.Time{})
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return // Accept already wrote an HTTP error response.
	}
	s.hub.Serve(r.Context(), ws, caller, expires)
}
