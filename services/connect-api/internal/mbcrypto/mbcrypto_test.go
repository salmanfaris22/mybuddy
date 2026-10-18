package mbcrypto_test

import (
	"encoding/hex"
	"testing"

	"mybuddy.local/connect-api/internal/mbcrypto"
	"mybuddy.local/connect-api/internal/testutil"
)

func decode(t *testing.T, s string) []byte {
	t.Helper()
	b, err := mbcrypto.B64U.DecodeString(s)
	if err != nil {
		t.Fatalf("b64u decode: %v", err)
	}
	return b
}

func TestVectorsDeviceIdentity(t *testing.T) {
	v := testutil.LoadVectors(t)
	host := decode(t, v.Inputs.HostIdentityKey)
	client := decode(t, v.Inputs.ClientIdentityKey)
	if got := mbcrypto.DeviceID(host); got != v.Expected.HostDeviceID {
		t.Fatalf("host device id = %s, want %s", got, v.Expected.HostDeviceID)
	}
	if got := mbcrypto.DeviceID(client); got != v.Expected.ClientDeviceID {
		t.Fatalf("client device id = %s, want %s", got, v.Expected.ClientDeviceID)
	}
	if got := mbcrypto.Fingerprint(host); got != v.Expected.HostFingerprint {
		t.Fatalf("fingerprint = %s, want %s", got, v.Expected.HostFingerprint)
	}
	if !mbcrypto.ValidDeviceID(v.Expected.HostDeviceID) || mbcrypto.ValidDeviceID("ABC") {
		t.Fatal("ValidDeviceID shape check wrong")
	}
}

func TestVectorsStatementsAndSignatures(t *testing.T) {
	v := testutil.LoadVectors(t)
	client := decode(t, v.Inputs.ClientIdentityKey)
	host := decode(t, v.Inputs.HostIdentityKey)

	reg := mbcrypto.RegisterStatement(client, v.Inputs.Platform)
	if hex.EncodeToString(reg) != v.Connect.RegisterMessageHex {
		t.Fatal("register statement bytes differ from vector")
	}
	if err := mbcrypto.VerifySPKI(client, reg, decode(t, v.Connect.RegisterSignature)); err != nil {
		t.Fatalf("register signature: %v", err)
	}

	auth := mbcrypto.AuthStatement(v.Connect.ChallengeID, decode(t, v.Connect.ChallengeNonce), v.Expected.ClientDeviceID)
	if hex.EncodeToString(auth) != v.Connect.AuthMessageHex {
		t.Fatal("auth statement bytes differ from vector")
	}
	if err := mbcrypto.VerifySPKI(client, auth, decode(t, v.Connect.AuthSignature)); err != nil {
		t.Fatalf("auth signature: %v", err)
	}

	pair := mbcrypto.PairingStatement(v.Expected.HostDeviceID, v.Expected.ClientDeviceID, v.Connect.PairingCreatedAt)
	if hex.EncodeToString(pair) != v.Connect.PairingMessageHex {
		t.Fatal("pairing statement bytes differ from vector")
	}
	if err := mbcrypto.VerifySPKI(host, pair, decode(t, v.Connect.PairingHostSig)); err != nil {
		t.Fatalf("pairing host signature: %v", err)
	}
	if err := mbcrypto.VerifySPKI(client, pair, decode(t, v.Connect.PairingClientSig)); err != nil {
		t.Fatalf("pairing client signature: %v", err)
	}
	// A signature by the wrong key must fail.
	if err := mbcrypto.VerifySPKI(host, pair, decode(t, v.Connect.PairingClientSig)); err == nil {
		t.Fatal("client signature verified under host key")
	}
}

func TestTamperedSignatureRejected(t *testing.T) {
	v := testutil.LoadVectors(t)
	client := decode(t, v.Inputs.ClientIdentityKey)
	reg := mbcrypto.RegisterStatement(client, v.Inputs.Platform)
	sig := decode(t, v.Connect.RegisterSignature)
	sig[len(sig)-1] ^= 0x01
	if err := mbcrypto.VerifySPKI(client, reg, sig); err == nil {
		t.Fatal("tampered signature accepted")
	}
	reg[len(reg)-1] ^= 0x01
	if err := mbcrypto.VerifySPKI(client, reg, decode(t, v.Connect.RegisterSignature)); err == nil {
		t.Fatal("signature accepted over tampered message")
	}
}

func TestParsePublicKeyRejectsNonP256(t *testing.T) {
	for _, bad := range [][]byte{nil, []byte("not der"), make([]byte, 300)} {
		if _, err := mbcrypto.ParsePublicKey(bad); err == nil {
			t.Fatalf("accepted %x", bad)
		}
	}
}

func TestLengthPrefix(t *testing.T) {
	got := mbcrypto.LP([]byte("ab"))
	if hex.EncodeToString(got) != "000000026162" {
		t.Fatalf("LP = %x", got)
	}
}
