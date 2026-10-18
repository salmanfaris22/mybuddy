// Package config loads connect-api settings from the environment.
package config

import (
	"errors"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"time"
)

// Config holds runtime settings. Secrets are never printed (see String).
type Config struct {
	ListenAddr        string
	AllowPublicListen bool
	DatabaseURL       string
	TrustProxyHeaders bool
	TurnSecret        []byte
	TurnURLs          []string
	TurnTTL           time.Duration
	TokenTTL          time.Duration
	ChallengeTTL      time.Duration
	AuditRetention    time.Duration
	PairingClockSkew  time.Duration
}

// Load reads configuration using getenv (os.Getenv in production). Secrets may instead be
// supplied as files (MYBUDDY_DATABASE_URL_FILE, MYBUDDY_TURN_SECRET_FILE) for Docker secrets.
func Load(getenv func(string) string) (Config, error) {
	return load(getenv, os.ReadFile)
}

func load(getenv func(string) string, readFile func(string) ([]byte, error)) (Config, error) {
	databaseURL, err := secret(getenv, readFile, "MYBUDDY_DATABASE_URL")
	if err != nil {
		return Config{}, err
	}
	turnSecret, err := secret(getenv, readFile, "MYBUDDY_TURN_SECRET")
	if err != nil {
		return Config{}, err
	}
	c := Config{
		ListenAddr:        or(getenv("MYBUDDY_LISTEN"), "127.0.0.1:8787"),
		AllowPublicListen: getenv("MYBUDDY_ALLOW_PUBLIC_LISTEN") == "1",
		DatabaseURL:       databaseURL,
		TrustProxyHeaders: getenv("MYBUDDY_TRUST_PROXY") == "1",
		TurnSecret:        []byte(turnSecret),
		TokenTTL:          15 * time.Minute,
		ChallengeTTL:      60 * time.Second,
		AuditRetention:    30 * 24 * time.Hour,
		PairingClockSkew:  10 * time.Minute,
	}
	if urls := strings.TrimSpace(getenv("MYBUDDY_TURN_URLS")); urls != "" {
		for _, u := range strings.Split(urls, ",") {
			u = strings.TrimSpace(u)
			if !(strings.HasPrefix(u, "turn:") || strings.HasPrefix(u, "turns:") || strings.HasPrefix(u, "stun:")) {
				return Config{}, fmt.Errorf("MYBUDDY_TURN_URLS: %q is not a turn:, turns: or stun: URI", u)
			}
			c.TurnURLs = append(c.TurnURLs, u)
		}
	}
	// TURN REST credentials can't be renewed inside a running allocation (coturn checks the expiry on every
	// refresh), so a relayed session lives at most this long before the apps reconnect with fresh ones.
	ttl := or(getenv("MYBUDDY_TURN_TTL_SECONDS"), "43200")
	secs, err := strconv.Atoi(ttl)
	if err != nil || secs < 60 || secs > 86400 {
		return Config{}, errors.New("MYBUDDY_TURN_TTL_SECONDS must be between 60 and 86400")
	}
	c.TurnTTL = time.Duration(secs) * time.Second
	if len(c.TurnSecret) > 0 && len(c.TurnSecret) < 16 {
		return Config{}, errors.New("MYBUDDY_TURN_SECRET must be at least 16 bytes")
	}

	host, _, err := net.SplitHostPort(c.ListenAddr)
	if err != nil {
		return Config{}, fmt.Errorf("MYBUDDY_LISTEN: %w", err)
	}
	if !isLoopback(host) && !c.AllowPublicListen {
		return Config{}, fmt.Errorf("refusing to listen on non-loopback address %q: run behind a TLS reverse proxy and set MYBUDDY_ALLOW_PUBLIC_LISTEN=1 only on a private network", c.ListenAddr)
	}
	return c, nil
}

// secret returns NAME, or the contents of the file named by NAME_FILE (trailing newlines removed).
// Setting both is an error so a stale value can't silently win. Errors never include file contents.
func secret(getenv func(string) string, readFile func(string) ([]byte, error), name string) (string, error) {
	value, path := getenv(name), getenv(name+"_FILE")
	switch {
	case value != "" && path != "":
		return "", fmt.Errorf("set %s or %s_FILE, not both", name, name)
	case path != "":
		b, err := readFile(path)
		if err != nil {
			return "", fmt.Errorf("%s_FILE: %w", name, err)
		}
		v := strings.TrimRight(string(b), "\r\n")
		if v == "" {
			return "", fmt.Errorf("%s_FILE: %s is empty", name, path)
		}
		return v, nil
	}
	return value, nil
}

func isLoopback(host string) bool {
	if host == "localhost" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func or(v, def string) string {
	if v == "" {
		return def
	}
	return v
}

// String summarizes the configuration without secrets.
func (c Config) String() string {
	db := "memory (not persisted)"
	if c.DatabaseURL != "" {
		db = "postgres"
	}
	turn := "not configured"
	if len(c.TurnSecret) > 0 && len(c.TurnURLs) > 0 {
		turn = fmt.Sprintf("%d url(s), ttl %s", len(c.TurnURLs), c.TurnTTL)
	}
	return fmt.Sprintf("listen=%s store=%s turn=%s trustProxy=%v", c.ListenAddr, db, turn, c.TrustProxyHeaders)
}
