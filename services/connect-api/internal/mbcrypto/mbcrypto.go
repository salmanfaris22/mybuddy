// Package mbcrypto implements the MyBuddy Connect signature statements
// (docs/PROTOCOL.md §7) and device identity helpers.
//
// Identities are ECDSA P-256 keys encoded as SubjectPublicKeyInfo DER.
// Signatures are ASN.1 DER over SHA-256 of the statement bytes.
package mbcrypto

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"regexp"
)

// B64U is base64url without padding, the binary encoding used throughout the protocol.
var B64U = base64.RawURLEncoding

var (
	ErrBadKey       = errors.New("public key is not a P-256 SubjectPublicKeyInfo")
	ErrBadSignature = errors.New("signature verification failed")
)

var deviceIDPattern = regexp.MustCompile(`^[0-9a-f]{32}$`)

// ValidDeviceID reports whether s has the shape of a device ID (32 lowercase hex chars).
func ValidDeviceID(s string) bool { return deviceIDPattern.MatchString(s) }

// LP returns a 4-byte big-endian length prefix followed by b.
func LP(b []byte) []byte {
	out := make([]byte, 4, 4+len(b))
	binary.BigEndian.PutUint32(out, uint32(len(b)))
	return append(out, b...)
}

func concat(parts ...[]byte) []byte {
	n := 0
	for _, p := range parts {
		n += len(p)
	}
	out := make([]byte, 0, n)
	for _, p := range parts {
		out = append(out, p...)
	}
	return out
}

// RegisterStatement is signed by a device to prove possession of its key at registration.
func RegisterStatement(spki []byte, platform string) []byte {
	return concat([]byte("MBC1/register"), LP(spki), LP([]byte(platform)))
}

// AuthStatement is signed by a device to answer an authentication challenge.
func AuthStatement(challengeID string, nonce []byte, deviceID string) []byte {
	return concat([]byte("MBC1/auth"), LP([]byte(challengeID)), LP(nonce), LP([]byte(deviceID)))
}

// PairingStatement is signed by both the host and the client to register a pairing.
func PairingStatement(hostDeviceID, clientDeviceID, createdAt string) []byte {
	return concat([]byte("MBC1/pairing"), LP([]byte(hostDeviceID)), LP([]byte(clientDeviceID)), LP([]byte(createdAt)))
}

// ParsePublicKey parses an SPKI DER key and requires the P-256 curve.
func ParsePublicKey(spki []byte) (*ecdsa.PublicKey, error) {
	if len(spki) == 0 || len(spki) > 200 {
		return nil, ErrBadKey
	}
	pub, err := x509.ParsePKIXPublicKey(spki)
	if err != nil {
		return nil, ErrBadKey
	}
	ec, ok := pub.(*ecdsa.PublicKey)
	if !ok || ec.Curve != elliptic.P256() {
		return nil, ErrBadKey
	}
	return ec, nil
}

// DeviceID is the lowercase hex of the first 16 bytes of SHA-256(SPKI).
func DeviceID(spki []byte) string {
	sum := sha256.Sum256(spki)
	return hex.EncodeToString(sum[:16])
}

// Fingerprint is base64url(SHA-256(SPKI)).
func Fingerprint(spki []byte) string {
	sum := sha256.Sum256(spki)
	return B64U.EncodeToString(sum[:])
}

// Verify checks a DER ECDSA signature over SHA-256(message).
func Verify(pub *ecdsa.PublicKey, message, derSig []byte) error {
	if len(derSig) == 0 || len(derSig) > 80 {
		return ErrBadSignature
	}
	digest := sha256.Sum256(message)
	if !ecdsa.VerifyASN1(pub, digest[:], derSig) {
		return ErrBadSignature
	}
	return nil
}

// VerifySPKI parses spki and verifies derSig over message.
func VerifySPKI(spki, message, derSig []byte) error {
	pub, err := ParsePublicKey(spki)
	if err != nil {
		return err
	}
	return Verify(pub, message, derSig)
}

// Sign produces a DER signature (used by tests and tools; the server never signs statements).
func Sign(priv *ecdsa.PrivateKey, message []byte) ([]byte, error) {
	digest := sha256.Sum256(message)
	return ecdsa.SignASN1(rand.Reader, priv, digest[:])
}

// RandomBytes returns n bytes from the system CSPRNG.
func RandomBytes(n int) []byte {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		panic("mbcrypto: system randomness unavailable: " + err.Error())
	}
	return b
}

// HashToken returns SHA-256(token) — tokens are stored only in hashed form.
func HashToken(token string) [32]byte { return sha256.Sum256([]byte(token)) }

// ConstantTimeEqual compares two byte slices in constant time.
func ConstantTimeEqual(a, b []byte) bool { return subtle.ConstantTimeCompare(a, b) == 1 }
