// Package testutil provides helpers shared by connect-api tests.
package testutil

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"mybuddy.local/connect-api/internal/mbcrypto"
)

// Vectors mirrors the parts of protocol/vectors/mbh1-v1.json used by Go tests.
type Vectors struct {
	Inputs struct {
		Platform          string `json:"platform"`
		HostIdentityKey   string `json:"hostIdentityKeySpkiB64u"`
		ClientIdentityKey string `json:"clientIdentityKeySpkiB64u"`
	} `json:"inputs"`
	Expected struct {
		HostDeviceID    string `json:"hostDeviceId"`
		ClientDeviceID  string `json:"clientDeviceId"`
		HostFingerprint string `json:"hostFingerprint"`
	} `json:"expected"`
	Connect struct {
		RegisterMessageHex string `json:"registerMessageHex"`
		RegisterSignature  string `json:"registerSignatureDerB64u"`
		ChallengeID        string `json:"challengeId"`
		ChallengeNonce     string `json:"challengeNonceB64u"`
		AuthMessageHex     string `json:"authMessageHex"`
		AuthSignature      string `json:"authSignatureDerB64u"`
		PairingCreatedAt   string `json:"pairingCreatedAt"`
		PairingMessageHex  string `json:"pairingMessageHex"`
		PairingHostSig     string `json:"pairingHostSignatureDerB64u"`
		PairingClientSig   string `json:"pairingClientSignatureDerB64u"`
		TurnSecret         string `json:"turnSecret"`
		TurnUsername       string `json:"turnUsername"`
		TurnCredential     string `json:"turnCredential"`
	} `json:"connect"`
}

// LoadVectors finds protocol/vectors/mbh1-v1.json by walking up from the working directory.
func LoadVectors(t testing.TB) Vectors {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	for {
		p := filepath.Join(dir, "protocol", "vectors", "mbh1-v1.json")
		if data, err := os.ReadFile(p); err == nil {
			var v Vectors
			if err := json.Unmarshal(data, &v); err != nil {
				t.Fatalf("parse %s: %v", p, err)
			}
			return v
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			t.Fatal("protocol/vectors/mbh1-v1.json not found above the test directory")
		}
		dir = parent
	}
}

// Device is a test identity with helpers to produce protocol signatures.
type Device struct {
	Priv     *ecdsa.PrivateKey
	SPKI     []byte
	ID       string
	Platform string
}

// NewDevice generates a fresh P-256 identity.
func NewDevice(t testing.TB, platform string) *Device {
	t.Helper()
	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	spki, err := x509.MarshalPKIXPublicKey(&priv.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	return &Device{Priv: priv, SPKI: spki, ID: mbcrypto.DeviceID(spki), Platform: platform}
}

// Sign signs message and returns the base64url DER signature.
func (d *Device) Sign(t testing.TB, message []byte) string {
	t.Helper()
	sig, err := mbcrypto.Sign(d.Priv, message)
	if err != nil {
		t.Fatal(err)
	}
	return mbcrypto.B64U.EncodeToString(sig)
}
