package config

import (
	"errors"
	"strings"
	"testing"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestDefaultsAreLoopback(t *testing.T) {
	c, err := Load(env(nil))
	if err != nil {
		t.Fatal(err)
	}
	if c.ListenAddr != "127.0.0.1:8787" || c.DatabaseURL != "" || len(c.TurnURLs) != 0 {
		t.Fatalf("unexpected defaults %+v", c)
	}
}

func TestRefusesPublicListenWithoutOptIn(t *testing.T) {
	if _, err := Load(env(map[string]string{"MYBUDDY_LISTEN": "0.0.0.0:8787"})); err == nil {
		t.Fatal("expected refusal for 0.0.0.0 without opt-in")
	}
	if _, err := Load(env(map[string]string{"MYBUDDY_LISTEN": "0.0.0.0:8787", "MYBUDDY_ALLOW_PUBLIC_LISTEN": "1"})); err != nil {
		t.Fatalf("opt-in should allow: %v", err)
	}
	if _, err := Load(env(map[string]string{"MYBUDDY_LISTEN": "[::1]:8787"})); err != nil {
		t.Fatalf("IPv6 loopback should be allowed: %v", err)
	}
}

func TestTurnValidation(t *testing.T) {
	if _, err := Load(env(map[string]string{"MYBUDDY_TURN_URLS": "http://turn.example.com"})); err == nil {
		t.Fatal("non-turn URL accepted")
	}
	if _, err := Load(env(map[string]string{"MYBUDDY_TURN_SECRET": "short"})); err == nil {
		t.Fatal("short secret accepted")
	}
	c, err := Load(env(map[string]string{"MYBUDDY_TURN_URLS": "turns:turn.example.com:5349, turn:turn.example.com:3478?transport=udp", "MYBUDDY_TURN_SECRET": "a-very-long-shared-secret"}))
	if err != nil || len(c.TurnURLs) != 2 {
		t.Fatalf("valid turn config rejected: %v", err)
	}
	if strings.Contains(c.String(), "a-very-long-shared-secret") {
		t.Fatal("String() leaks the TURN secret")
	}
}

func TestSecretsFromFiles(t *testing.T) {
	files := map[string]string{"/run/secrets/db": "postgres://u:p@db/x\n", "/run/secrets/turn": "a-very-long-shared-secret\r\n", "/run/secrets/empty": "\n"}
	readFile := func(p string) ([]byte, error) {
		if v, ok := files[p]; ok {
			return []byte(v), nil
		}
		return nil, errors.New("no such file")
	}
	c, err := load(env(map[string]string{"MYBUDDY_DATABASE_URL_FILE": "/run/secrets/db", "MYBUDDY_TURN_SECRET_FILE": "/run/secrets/turn"}), readFile)
	if err != nil {
		t.Fatal(err)
	}
	if c.DatabaseURL != "postgres://u:p@db/x" || string(c.TurnSecret) != "a-very-long-shared-secret" {
		t.Fatalf("file secrets not loaded or not trimmed: %q", c.DatabaseURL)
	}
	if _, err := load(env(map[string]string{"MYBUDDY_TURN_SECRET": "x", "MYBUDDY_TURN_SECRET_FILE": "/run/secrets/turn"}), readFile); err == nil {
		t.Fatal("both value and _FILE accepted")
	}
	if _, err := load(env(map[string]string{"MYBUDDY_DATABASE_URL_FILE": "/missing"}), readFile); err == nil {
		t.Fatal("missing secret file accepted")
	}
	_, err = load(env(map[string]string{"MYBUDDY_DATABASE_URL_FILE": "/run/secrets/empty"}), readFile)
	if err == nil || strings.Contains(err.Error(), "postgres://") {
		t.Fatalf("empty secret file accepted or error leaked contents: %v", err)
	}
}
