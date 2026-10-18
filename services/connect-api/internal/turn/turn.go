// Package turn issues short-lived TURN credentials using the coturn
// "TURN REST API" convention (use-auth-secret / static-auth-secret):
//
//	username   = "<unix expiry>:<deviceId>"
//	credential = base64(HMAC-SHA1(sharedSecret, username))
//
// The shared secret never leaves the server.
package turn

import (
	"crypto/hmac"
	"crypto/sha1" //nolint:gosec // HMAC-SHA1 is mandated by the coturn REST API credential scheme.
	"encoding/base64"
	"fmt"
	"time"
)

// Credentials are returned to an authenticated, paired device.
type Credentials struct {
	URLs       []string `json:"urls"`
	Username   string   `json:"username"`
	Credential string   `json:"credential"`
	TTLSeconds int      `json:"ttlSeconds"`
}

// Issuer generates credentials. A zero-value Issuer is "not configured".
type Issuer struct {
	Secret []byte
	URLs   []string
	TTL    time.Duration
}

// Configured reports whether TURN is set up on this server.
func (i Issuer) Configured() bool { return len(i.Secret) >= 16 && len(i.URLs) > 0 && i.TTL > 0 }

// Issue returns credentials for deviceID valid until now+TTL.
func (i Issuer) Issue(deviceID string, now time.Time) Credentials {
	expiry := now.Add(i.TTL).Unix()
	username := fmt.Sprintf("%d:%s", expiry, deviceID)
	return Credentials{
		URLs:       append([]string(nil), i.URLs...),
		Username:   username,
		Credential: Credential(i.Secret, username),
		TTLSeconds: int(i.TTL / time.Second),
	}
}

// Credential computes base64(HMAC-SHA1(secret, username)).
func Credential(secret []byte, username string) string {
	m := hmac.New(sha1.New, secret)
	m.Write([]byte(username))
	return base64.StdEncoding.EncodeToString(m.Sum(nil))
}
