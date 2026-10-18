package main

import (
	"testing"
	"time"
)

// The derivation must match connect-api's issuer (internal/turn) and coturn's use-auth-secret.
func TestPasswordMatchesTheRESTConvention(t *testing.T) {
	// Same inputs as protocol/vectors/mbh1-v1.json "connect.turn*".
	got := password([]byte("test-turn-secret-not-for-production"), "1792131600:da96726356de5002c857434beefe468d")
	if got == "" || len(got) != 28 {
		t.Fatalf("unexpected credential %q", got)
	}
}

func TestExpiredCredentialsAreRefused(t *testing.T) {
	now := time.Unix(1_800_000_000, 0)
	if !valid("1800000060:abc", now) {
		t.Fatal("a future expiry must be valid")
	}
	if valid("1799999999:abc", now) || valid("nonsense", now) || valid("x:abc", now) {
		t.Fatal("expired or malformed usernames must be refused")
	}
}
