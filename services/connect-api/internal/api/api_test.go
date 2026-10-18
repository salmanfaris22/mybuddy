package api_test

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"

	"mybuddy.local/connect-api/internal/api"
	"mybuddy.local/connect-api/internal/config"
	"mybuddy.local/connect-api/internal/mbcrypto"
	"mybuddy.local/connect-api/internal/store"
	"mybuddy.local/connect-api/internal/testutil"
)

// ---------- harness ----------

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) Now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) Advance(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type env struct {
	t     *testing.T
	srv   *api.Server
	ts    *httptest.Server
	clock *clock
	store store.Store
}

type envOpt func(*config.Config, *api.Options)

func withTurn(c *config.Config, _ *api.Options) {
	c.TurnSecret = []byte("integration-test-turn-secret")
	c.TurnURLs = []string{"turns:turn.example.com:5349", "turn:turn.example.com:3478?transport=udp"}
	c.TurnTTL = 10 * time.Minute
}

func newEnv(t *testing.T, opts ...envOpt) *env {
	t.Helper()
	cfg, err := config.Load(func(string) string { return "" })
	if err != nil {
		t.Fatal(err)
	}
	clk := &clock{t: time.Date(2026, 10, 16, 8, 30, 0, 0, time.UTC)}
	st := store.NewMemoryStore()
	o := api.Options{Config: cfg, Store: st, Now: clk.Now, UnauthRatePerSecond: 1000, UnauthBurst: 1000}
	for _, opt := range opts {
		opt(&o.Config, &o)
	}
	srv := api.New(o)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	return &env{t: t, srv: srv, ts: ts, clock: clk, store: st}
}

func (e *env) do(method, path string, body any, token string) (int, map[string]any) {
	e.t.Helper()
	var r io.Reader
	switch b := body.(type) {
	case nil:
	case string:
		r = strings.NewReader(b)
	default:
		data, _ := json.Marshal(b)
		r = bytes.NewReader(data)
	}
	req, _ := http.NewRequest(method, e.ts.URL+path, r)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	data, _ := io.ReadAll(resp.Body)
	if len(data) > 0 {
		_ = json.Unmarshal(data, &out)
	}
	return resp.StatusCode, out
}

func errCode(m map[string]any) string {
	if e, ok := m["error"].(map[string]any); ok {
		s, _ := e["code"].(string)
		return s
	}
	return ""
}

func (e *env) register(d *testutil.Device) {
	e.t.Helper()
	status, body := e.do("POST", "/v1/devices", map[string]string{
		"publicKey": mbcrypto.B64U.EncodeToString(d.SPKI),
		"platform":  d.Platform,
		"proof":     d.Sign(e.t, mbcrypto.RegisterStatement(d.SPKI, d.Platform)),
	}, "")
	if status != http.StatusCreated || body["deviceId"] != d.ID {
		e.t.Fatalf("register: %d %v", status, body)
	}
}

func (e *env) challenge(deviceID string) (string, []byte) {
	e.t.Helper()
	status, body := e.do("POST", "/v1/auth/challenge", map[string]string{"deviceId": deviceID}, "")
	if status != http.StatusOK {
		e.t.Fatalf("challenge: %d %v", status, body)
	}
	nonce, err := mbcrypto.B64U.DecodeString(body["nonce"].(string))
	if err != nil {
		e.t.Fatal(err)
	}
	return body["challengeId"].(string), nonce
}

func (e *env) login(d *testutil.Device) string {
	e.t.Helper()
	id, nonce := e.challenge(d.ID)
	status, body := e.do("POST", "/v1/auth/token", map[string]string{
		"challengeId": id, "deviceId": d.ID, "signature": d.Sign(e.t, mbcrypto.AuthStatement(id, nonce, d.ID)),
	}, "")
	if status != http.StatusOK {
		e.t.Fatalf("token: %d %v", status, body)
	}
	return body["token"].(string)
}

func (e *env) pairingBody(host, client *testutil.Device, createdAt string) map[string]string {
	st := mbcrypto.PairingStatement(host.ID, client.ID, createdAt)
	return map[string]string{
		"hostDeviceId": host.ID, "clientDeviceId": client.ID, "createdAt": createdAt,
		"hostSignature": host.Sign(e.t, st), "clientSignature": client.Sign(e.t, st),
	}
}

func (e *env) nowString() string { return e.clock.Now().UTC().Format("2006-01-02T15:04:05.000Z") }

// paired returns host + client devices with tokens and an active pairing id.
func (e *env) paired() (host, client *testutil.Device, hostTok, clientTok, pairingID string) {
	e.t.Helper()
	host, client = testutil.NewDevice(e.t, "macos"), testutil.NewDevice(e.t, "android")
	e.register(host)
	e.register(client)
	hostTok, clientTok = e.login(host), e.login(client)
	status, body := e.do("POST", "/v1/pairings", e.pairingBody(host, client, e.nowString()), hostTok)
	if status != http.StatusCreated {
		e.t.Fatalf("pairing: %d %v", status, body)
	}
	return host, client, hostTok, clientTok, body["pairingId"].(string)
}

// ---------- REST tests ----------

func TestHealth(t *testing.T) {
	e := newEnv(t)
	if s, b := e.do("GET", "/healthz", nil, ""); s != 200 || b["status"] != "ok" {
		t.Fatalf("healthz %d %v", s, b)
	}
	if s, _ := e.do("GET", "/readyz", nil, ""); s != 200 {
		t.Fatalf("readyz %d", s)
	}
}

func TestRegisterValidation(t *testing.T) {
	e := newEnv(t)
	d := testutil.NewDevice(t, "android")
	e.register(d)

	// Idempotent re-registration with the same key.
	s, b := e.do("POST", "/v1/devices", map[string]string{
		"publicKey": mbcrypto.B64U.EncodeToString(d.SPKI), "platform": "android",
		"proof": d.Sign(t, mbcrypto.RegisterStatement(d.SPKI, "android")),
	}, "")
	if s != 200 || b["deviceId"] != d.ID {
		t.Fatalf("re-register: %d %v", s, b)
	}

	other := testutil.NewDevice(t, "android")
	cases := []struct {
		name   string
		body   any
		status int
		code   string
	}{
		{"bad platform", map[string]string{"publicKey": mbcrypto.B64U.EncodeToString(other.SPKI), "platform": "ios", "proof": other.Sign(t, mbcrypto.RegisterStatement(other.SPKI, "ios"))}, 400, "bad_platform"},
		{"proof over wrong platform", map[string]string{"publicKey": mbcrypto.B64U.EncodeToString(other.SPKI), "platform": "android", "proof": other.Sign(t, mbcrypto.RegisterStatement(other.SPKI, "macos"))}, 401, "bad_proof"},
		{"proof by another key", map[string]string{"publicKey": mbcrypto.B64U.EncodeToString(other.SPKI), "platform": "android", "proof": d.Sign(t, mbcrypto.RegisterStatement(other.SPKI, "android"))}, 401, "bad_proof"},
		{"not base64", map[string]string{"publicKey": "!!!", "platform": "android", "proof": "x"}, 400, "bad_key"},
		{"unknown field", `{"publicKey":"a","platform":"android","proof":"b","admin":true}`, 400, "bad_request"},
		{"trailing data", `{"publicKey":"a","platform":"android","proof":"b"} {}`, 400, "bad_request"},
		{"too large", `{"publicKey":"` + strings.Repeat("A", 20000) + `"}`, 413, "too_large"},
	}
	for _, c := range cases {
		s, b := e.do("POST", "/v1/devices", c.body, "")
		if s != c.status || errCode(b) != c.code {
			t.Errorf("%s: got %d %q, want %d %q", c.name, s, errCode(b), c.status, c.code)
		}
	}

	// A P-384 key must be rejected (identity keys are P-256 only).
	p384, _ := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	spki384, _ := x509.MarshalPKIXPublicKey(&p384.PublicKey)
	s, b = e.do("POST", "/v1/devices", map[string]string{"publicKey": mbcrypto.B64U.EncodeToString(spki384), "platform": "android", "proof": "AAAA"}, "")
	if s != 400 || errCode(b) != "bad_key" {
		t.Fatalf("P-384 key: %d %v", s, b)
	}
}

func TestChallengeIsSingleUseAndExpires(t *testing.T) {
	e := newEnv(t)
	d := testutil.NewDevice(t, "android")
	e.register(d)

	id, nonce := e.challenge(d.ID)
	sig := d.Sign(t, mbcrypto.AuthStatement(id, nonce, d.ID))
	body := map[string]string{"challengeId": id, "deviceId": d.ID, "signature": sig}
	if s, b := e.do("POST", "/v1/auth/token", body, ""); s != 200 || len(b["token"].(string)) != 43 {
		t.Fatalf("first use: %d %v", s, b)
	}
	if s, b := e.do("POST", "/v1/auth/token", body, ""); s != 401 || errCode(b) != "auth_failed" {
		t.Fatalf("replayed challenge: %d %v", s, b)
	}

	id, nonce = e.challenge(d.ID)
	e.clock.Advance(61 * time.Second)
	if s, _ := e.do("POST", "/v1/auth/token", map[string]string{"challengeId": id, "deviceId": d.ID, "signature": d.Sign(t, mbcrypto.AuthStatement(id, nonce, d.ID))}, ""); s != 401 {
		t.Fatalf("expired challenge accepted: %d", s)
	}

	attacker := testutil.NewDevice(t, "android")
	id, nonce = e.challenge(d.ID)
	if s, _ := e.do("POST", "/v1/auth/token", map[string]string{"challengeId": id, "deviceId": d.ID, "signature": attacker.Sign(t, mbcrypto.AuthStatement(id, nonce, d.ID))}, ""); s != 401 {
		t.Fatalf("signature from another key accepted: %d", s)
	}

	// Unknown devices still get a challenge (no enumeration) but can never get a token.
	id, nonce = e.challenge(attacker.ID)
	if s, _ := e.do("POST", "/v1/auth/token", map[string]string{"challengeId": id, "deviceId": attacker.ID, "signature": attacker.Sign(t, mbcrypto.AuthStatement(id, nonce, attacker.ID))}, ""); s != 401 {
		t.Fatalf("unregistered device got a token: %d", s)
	}
}

func TestBearerTokenRequiredAndExpires(t *testing.T) {
	e := newEnv(t)
	d := testutil.NewDevice(t, "android")
	e.register(d)
	tok := e.login(d)
	if s, _ := e.do("GET", "/v1/me", nil, ""); s != 401 {
		t.Fatalf("no token: %d", s)
	}
	if s, _ := e.do("GET", "/v1/me", nil, "short"); s != 401 {
		t.Fatalf("malformed token: %d", s)
	}
	if s, _ := e.do("GET", "/v1/me", nil, strings.Repeat("A", 43)); s != 401 {
		t.Fatalf("unknown token: %d", s)
	}
	s, b := e.do("GET", "/v1/me", nil, tok)
	if s != 200 || b["deviceId"] != d.ID || b["platform"] != "android" {
		t.Fatalf("me: %d %v", s, b)
	}
	e.clock.Advance(15 * time.Minute)
	if s, _ := e.do("GET", "/v1/me", nil, tok); s != 401 {
		t.Fatalf("expired token accepted: %d", s)
	}
}

func TestPairingLifecycle(t *testing.T) {
	e := newEnv(t, withTurn)
	host, client := testutil.NewDevice(t, "macos"), testutil.NewDevice(t, "android")
	e.register(host)
	e.register(client)
	hostTok, clientTok := e.login(host), e.login(client)

	now := e.nowString()
	if s, b := e.do("POST", "/v1/pairings", e.pairingBody(host, client, now), clientTok); s != 403 || errCode(b) != "not_host" {
		t.Fatalf("client registering as host: %d %v", s, b)
	}
	bad := e.pairingBody(host, client, now)
	bad["clientSignature"] = host.Sign(t, mbcrypto.PairingStatement(host.ID, client.ID, now))
	if s, b := e.do("POST", "/v1/pairings", bad, hostTok); s != 400 || errCode(b) != "bad_signature" {
		t.Fatalf("host-forged client signature: %d %v", s, b)
	}
	stale := e.clock.Now().Add(-11 * time.Minute).UTC().Format(time.RFC3339Nano)
	if s, b := e.do("POST", "/v1/pairings", e.pairingBody(host, client, stale), hostTok); s != 400 || errCode(b) != "stale_statement" {
		t.Fatalf("stale statement: %d %v", s, b)
	}
	if s, b := e.do("GET", "/v1/turn-credentials", nil, clientTok); s != 403 || errCode(b) != "no_active_pairing" {
		t.Fatalf("turn before pairing: %d %v", s, b)
	}

	s, b := e.do("POST", "/v1/pairings", e.pairingBody(host, client, now), hostTok)
	if s != 201 {
		t.Fatalf("create pairing: %d %v", s, b)
	}
	pid := b["pairingId"].(string)
	if s, b := e.do("POST", "/v1/pairings", e.pairingBody(host, client, now), hostTok); s != 200 || b["pairingId"] != pid {
		t.Fatalf("idempotent pairing: %d %v", s, b)
	}

	// An Android device cannot act as host.
	phone2 := testutil.NewDevice(t, "android")
	e.register(phone2)
	phone2Tok := e.login(phone2)
	if s, b := e.do("POST", "/v1/pairings", e.pairingBody(phone2, client, now), phone2Tok); s != 400 || errCode(b) != "bad_host" {
		t.Fatalf("android host: %d %v", s, b)
	}

	s, b = e.do("GET", "/v1/turn-credentials", nil, clientTok)
	if s != 200 || !strings.HasSuffix(b["username"].(string), ":"+client.ID) || b["credential"] == "" || b["ttlSeconds"].(float64) != 600 {
		t.Fatalf("turn credentials: %d %v", s, b)
	}

	if s, _ := e.do("DELETE", "/v1/pairings/"+pid, nil, phone2Tok); s != 404 {
		t.Fatalf("stranger revoke: %d", s)
	}
	if s, _ := e.do("DELETE", "/v1/pairings/"+pid, nil, clientTok); s != 204 {
		t.Fatalf("client revoke: %d", s)
	}
	s, b = e.do("GET", "/v1/pairings", nil, hostTok)
	list := b["pairings"].([]any)
	if s != 200 || len(list) != 1 || list[0].(map[string]any)["revokedAt"] == nil {
		t.Fatalf("list after revoke: %d %v", s, b)
	}
	if s, _ := e.do("GET", "/v1/turn-credentials", nil, clientTok); s != 403 {
		t.Fatalf("turn after revoke: %d", s)
	}
}

func TestTurnNotConfigured(t *testing.T) {
	e := newEnv(t)
	_, _, _, clientTok, _ := e.paired()
	if s, b := e.do("GET", "/v1/turn-credentials", nil, clientTok); s != 503 || errCode(b) != "turn_not_configured" {
		t.Fatalf("turn not configured: %d %v", s, b)
	}
}

func TestUnauthenticatedRateLimit(t *testing.T) {
	e := newEnv(t, func(_ *config.Config, o *api.Options) { o.UnauthRatePerSecond = 0.001; o.UnauthBurst = 3 })
	for i := 0; i < 3; i++ {
		if s, _ := e.do("POST", "/v1/auth/challenge", map[string]string{"deviceId": strings.Repeat("a", 32)}, ""); s != 200 {
			t.Fatalf("request %d: %d", i, s)
		}
	}
	if s, b := e.do("POST", "/v1/auth/challenge", map[string]string{"deviceId": strings.Repeat("a", 32)}, ""); s != 429 || errCode(b) != "rate_limited" {
		t.Fatalf("4th request: %d %v", s, b)
	}
}

// ---------- signaling tests ----------

func (e *env) dial(token string) *websocket.Conn {
	e.t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	c, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(e.ts.URL, "http")+"/v1/signal",
		&websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}})
	if err != nil {
		e.t.Fatalf("dial: %v", err)
	}
	e.t.Cleanup(func() { c.CloseNow() })
	return c
}

func send(t *testing.T, c *websocket.Conn, v any) {
	t.Helper()
	data, _ := json.Marshal(v)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	if err := c.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("write: %v", err)
	}
}

// next reads messages until one of type typ arrives (skipping presence noise).
func next(t *testing.T, c *websocket.Conn, typ string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		_, data, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("waiting for %q: %v", typ, err)
		}
		m := map[string]any{}
		_ = json.Unmarshal(data, &m)
		if m["type"] == typ {
			return m
		}
	}
}

func TestSignalRequiresAuth(t *testing.T) {
	e := newEnv(t)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, resp, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(e.ts.URL, "http")+"/v1/signal", nil)
	if err == nil || resp == nil || resp.StatusCode != 401 {
		t.Fatalf("unauthenticated dial: err=%v resp=%v", err, resp)
	}
}

func TestSignalRelayBetweenPairedDevices(t *testing.T) {
	e := newEnv(t)
	host, client, hostTok, clientTok, pid := e.paired()
	hc := e.dial(hostTok)
	cc := e.dial(clientTok)

	send(t, hc, map[string]string{"type": "ping"})
	next(t, hc, "pong")

	send(t, cc, map[string]string{"type": "presence"})
	p := next(t, cc, "presence")
	peers := p["peers"].([]any)
	if len(peers) != 1 || peers[0].(map[string]any)["deviceId"] != host.ID || peers[0].(map[string]any)["online"] != true {
		t.Fatalf("presence: %v", p)
	}

	frame := mbcrypto.B64U.EncodeToString([]byte(`{"type":"hs.hello","protocol":1}`))
	send(t, cc, map[string]string{"type": "relay", "to": host.ID, "id": "m1", "data": frame})
	got := next(t, hc, "relay")
	if got["from"] != client.ID || got["id"] != "m1" || got["data"] != frame {
		t.Fatalf("relayed message: %v", got)
	}

	// Relaying to a device without a pairing is refused.
	stranger := testutil.NewDevice(t, "android")
	send(t, hc, map[string]string{"type": "relay", "to": stranger.ID, "id": "m2", "data": frame})
	if m := next(t, hc, "error"); m["code"] != "not_paired" || m["id"] != "m2" {
		t.Fatalf("relay to stranger: %v", m)
	}

	// Revoking over REST notifies both sides and cuts relay immediately.
	if s, _ := e.do("DELETE", "/v1/pairings/"+pid, nil, hostTok); s != 204 {
		t.Fatalf("revoke: %d", s)
	}
	if m := next(t, cc, "pairing.revoked"); m["pairingId"] != pid || m["peerDeviceId"] != host.ID {
		t.Fatalf("client revocation notice: %v", m)
	}
	if m := next(t, hc, "pairing.revoked"); m["peerDeviceId"] != client.ID {
		t.Fatalf("host revocation notice: %v", m)
	}
	send(t, cc, map[string]string{"type": "relay", "to": host.ID, "id": "m3", "data": frame})
	if m := next(t, cc, "error"); m["code"] != "not_paired" {
		t.Fatalf("relay after revoke: %v", m)
	}
}

func TestSignalPeerOfflineAndViolations(t *testing.T) {
	e := newEnv(t)
	host, _, _, clientTok, _ := e.paired()
	cc := e.dial(clientTok)
	frame := mbcrypto.B64U.EncodeToString([]byte("x"))
	send(t, cc, map[string]string{"type": "relay", "to": host.ID, "id": "m1", "data": frame})
	if m := next(t, cc, "error"); m["code"] != "peer_offline" {
		t.Fatalf("offline peer: %v", m)
	}
	// Three protocol violations close the socket.
	send(t, cc, map[string]string{"type": "shell", "id": "v1"})
	if m := next(t, cc, "error"); m["code"] != "unknown_type" {
		t.Fatalf("unknown type: %v", m)
	}
	send(t, cc, map[string]any{"type": "relay", "to": host.ID, "id": "v2", "data": frame, "extra": 1})
	if m := next(t, cc, "error"); m["code"] != "bad_message" {
		t.Fatalf("unknown field: %v", m)
	}
	send(t, cc, map[string]string{"type": "relay", "to": "not-a-device", "id": "v3", "data": frame})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		if _, _, err := cc.Read(ctx); err != nil {
			if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
				t.Fatalf("expected policy-violation close, got %v", err)
			}
			break
		}
	}
}

func TestSignalOversizedMessageClosesSocket(t *testing.T) {
	e := newEnv(t)
	_, _, _, clientTok, _ := e.paired()
	cc := e.dial(clientTok)
	big := strings.Repeat("A", 100*1024)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = cc.Write(ctx, websocket.MessageText, []byte(`{"type":"relay","data":"`+big+`"}`))
	for {
		if _, _, err := cc.Read(ctx); err != nil {
			if websocket.CloseStatus(err) != websocket.StatusMessageTooBig {
				t.Fatalf("expected message-too-big close, got %v", err)
			}
			return
		}
	}
}

func TestSignalNewConnectionReplacesOld(t *testing.T) {
	e := newEnv(t)
	_, _, _, clientTok, _ := e.paired()
	first := e.dial(clientTok)
	_ = e.dial(clientTok)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		if _, _, err := first.Read(ctx); err != nil {
			if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
				t.Fatalf("expected replaced connection to close with policy violation, got %v", err)
			}
			return
		}
	}
}

func TestSignalClosesWhenTokenExpires(t *testing.T) {
	e := newEnv(t, func(c *config.Config, o *api.Options) {
		c.TokenTTL = 400 * time.Millisecond
		o.Now = time.Now // real clock so the expiry timer fires
	})
	d := testutil.NewDevice(t, "android")
	e.register(d)
	c := e.dial(e.login(d))
	if m := next(t, c, "error"); m["code"] != "token_expired" {
		t.Fatalf("expected token_expired, got %v", m)
	}
}
