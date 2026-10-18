package turn_test

import (
	"strings"
	"testing"
	"time"

	"mybuddy.local/connect-api/internal/testutil"
	"mybuddy.local/connect-api/internal/turn"
)

func TestCredentialMatchesVector(t *testing.T) {
	v := testutil.LoadVectors(t)
	got := turn.Credential([]byte(v.Connect.TurnSecret), v.Connect.TurnUsername)
	if got != v.Connect.TurnCredential {
		t.Fatalf("credential = %s, want %s", got, v.Connect.TurnCredential)
	}
}

func TestIssue(t *testing.T) {
	i := turn.Issuer{Secret: []byte("0123456789abcdef-secret"), URLs: []string{"turns:turn.example.com:5349"}, TTL: 10 * time.Minute}
	if !i.Configured() {
		t.Fatal("expected configured")
	}
	now := time.Unix(1_800_000_000, 0)
	c := i.Issue("da96726356de5002c857434beefe468d", now)
	if c.Username != "1800000600:da96726356de5002c857434beefe468d" {
		t.Fatalf("username = %s", c.Username)
	}
	if c.TTLSeconds != 600 || len(c.URLs) != 1 || c.Credential == "" {
		t.Fatalf("unexpected credentials %+v", c)
	}
	if strings.Contains(c.Credential, string(i.Secret)) {
		t.Fatal("secret leaked into credential")
	}
}

func TestNotConfigured(t *testing.T) {
	for _, i := range []turn.Issuer{{}, {Secret: []byte("short"), URLs: []string{"turn:x"}, TTL: time.Minute}, {Secret: []byte("0123456789abcdef"), TTL: time.Minute}} {
		if i.Configured() {
			t.Fatalf("issuer %+v should not be configured", i)
		}
	}
}
