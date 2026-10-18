// Command vectorgen produces deterministic cross-language test vectors for the
// MBH1 secure channel and the MyBuddy Connect signature statements.
//
// Usage:
//
//	go run . -out ../../vectors/mbh1-v1.json   # (re)generate
//	go run . -check ../../vectors/mbh1-v1.json # regenerate in memory and diff
//
// All key material here is TEST-ONLY and derived from public seed strings.
// ECDSA signatures use RFC 6979 (nil random source) so output is reproducible.
package main

import (
	"bytes"
	"crypto"
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/hkdf"
	"crypto/hmac"
	"crypto/sha1"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"os"
)

var b64u = base64.RawURLEncoding

func seed(label string) []byte {
	s := sha256.Sum256([]byte("mybuddy-test-vector/" + label))
	return s[:]
}

// lp returns a 4-byte big-endian length prefix followed by b.
func lp(b []byte) []byte {
	out := make([]byte, 4, 4+len(b))
	binary.BigEndian.PutUint32(out, uint32(len(b)))
	return append(out, b...)
}

func sha(parts ...[]byte) []byte {
	h := sha256.New()
	for _, p := range parts {
		h.Write(p)
	}
	return h.Sum(nil)
}

func signDER(k *ecdsa.PrivateKey, msg []byte) []byte {
	digest := sha256.Sum256(msg)
	sig, err := k.Sign(nil, digest[:], crypto.SHA256) // nil rand => RFC 6979 deterministic
	must(err)
	return sig
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}

func identity(label string) (*ecdsa.PrivateKey, []byte) {
	k, err := ecdsa.ParseRawPrivateKey(elliptic.P256(), seed(label))
	must(err)
	spki, err := x509.MarshalPKIXPublicKey(&k.PublicKey)
	must(err)
	return k, spki
}

func deviceID(spki []byte) string {
	s := sha256.Sum256(spki)
	return hex.EncodeToString(s[:16])
}

func fingerprint(spki []byte) string {
	s := sha256.Sum256(spki)
	return b64u.EncodeToString(s[:])
}

func hkdfKey(ikm, salt []byte, info string, n int) []byte {
	out, err := hkdf.Key(sha256.New, ikm, salt, info, n)
	must(err)
	return out
}

type Frame struct {
	Direction string `json:"direction"` // "c2h" or "h2c"
	Counter   uint64 `json:"counter"`
	Plaintext string `json:"plaintext"`
	Frame     string `json:"frameB64u"`
}

type Vectors struct {
	Comment string `json:"comment"`
	Inputs  struct {
		Mode                   string `json:"mode"`
		ClientName             string `json:"clientName"`
		Platform               string `json:"platform"`
		HostIdentityPrivHex    string `json:"hostIdentityPrivateScalarHex"`
		ClientIdentityPrivHex  string `json:"clientIdentityPrivateScalarHex"`
		HostEphemeralPrivHex   string `json:"hostEphemeralPrivateScalarHex"`
		ClientEphemeralPrivHex string `json:"clientEphemeralPrivateScalarHex"`
		HostIdentityKey        string `json:"hostIdentityKeySpkiB64u"`
		ClientIdentityKey      string `json:"clientIdentityKeySpkiB64u"`
		HostEphemeral          string `json:"hostEphemeralX963B64u"`
		ClientEphemeral        string `json:"clientEphemeralX963B64u"`
		HostNonce              string `json:"hostNonceB64u"`
		ClientNonce            string `json:"clientNonceB64u"`
		PairingSecret          string `json:"pairingSecretB64u"`
	} `json:"inputs"`
	Expected struct {
		HostDeviceID     string  `json:"hostDeviceId"`
		ClientDeviceID   string  `json:"clientDeviceId"`
		HostFingerprint  string  `json:"hostFingerprint"`
		TH1Hex           string  `json:"th1Hex"`
		HostSignature    string  `json:"hostSignatureDerB64u"`
		TH2Hex           string  `json:"th2Hex"`
		ClientSignature  string  `json:"clientSignatureDerB64u"`
		PairingProofB64u string  `json:"pairingProofB64u"`
		SharedSecretHex  string  `json:"sharedSecretHex"`
		KeyC2HHex        string  `json:"keyC2HHex"`
		KeyH2CHex        string  `json:"keyH2CHex"`
		SAS              string  `json:"sas"`
		SessionID        string  `json:"sessionId"`
		Frames           []Frame `json:"frames"`
		QRURL            string  `json:"qrUrl"`
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
		// Signed WebRTC rendezvous relayed through /v1/signal (PROTOCOL §7.3).
		RtcKind       string `json:"rtcKind"`
		RtcID         string `json:"rtcId"`
		RtcAt         string `json:"rtcAt"`
		RtcSDP        string `json:"rtcSdp"`
		RtcMessageHex string `json:"rtcMessageHex"`
		RtcClientSig  string `json:"rtcClientSignatureDerB64u"`
		RtcEnvelope   string `json:"rtcEnvelopeJson"`
	} `json:"connect"`
}

func sealFrame(key []byte, dir byte, counter uint64, plaintext []byte) []byte {
	block, err := aes.NewCipher(key)
	must(err)
	gcm, err := cipher.NewGCM(block)
	must(err)
	ctr := make([]byte, 8)
	binary.BigEndian.PutUint64(ctr, counter)
	nonce := append(make([]byte, 4), ctr...)
	aad := append(append([]byte("MBH1/frame"), dir), ctr...)
	return append(ctr, gcm.Seal(nil, nonce, plaintext, aad)...)
}

func generate() Vectors {
	var v Vectors
	v.Comment = "MBH1 v1 + MyBuddy Connect test vectors. TEST-ONLY keys derived from public seeds. Generated by protocol/tools/vectorgen; do not edit by hand."

	hostID, hostSPKI := identity("host-identity")
	clientID, clientSPKI := identity("client-identity")

	hostEph, err := ecdh.P256().NewPrivateKey(seed("host-ephemeral"))
	must(err)
	clientEph, err := ecdh.P256().NewPrivateKey(seed("client-ephemeral"))
	must(err)
	hostNonce := seed("host-nonce")
	clientNonce := seed("client-nonce")
	pairingSecret := seed("pairing-secret")
	mode := "pair"
	clientName := "Vivo X300"
	platform := "android"

	in := &v.Inputs
	in.Mode, in.ClientName, in.Platform = mode, clientName, platform
	in.HostIdentityPrivHex = hex.EncodeToString(seed("host-identity"))
	in.ClientIdentityPrivHex = hex.EncodeToString(seed("client-identity"))
	in.HostEphemeralPrivHex = hex.EncodeToString(seed("host-ephemeral"))
	in.ClientEphemeralPrivHex = hex.EncodeToString(seed("client-ephemeral"))
	in.HostIdentityKey = b64u.EncodeToString(hostSPKI)
	in.ClientIdentityKey = b64u.EncodeToString(clientSPKI)
	in.HostEphemeral = b64u.EncodeToString(hostEph.PublicKey().Bytes())
	in.ClientEphemeral = b64u.EncodeToString(clientEph.PublicKey().Bytes())
	in.HostNonce = b64u.EncodeToString(hostNonce)
	in.ClientNonce = b64u.EncodeToString(clientNonce)
	in.PairingSecret = b64u.EncodeToString(pairingSecret)

	th1 := sha([]byte("MBH1/th1"), lp([]byte(mode)), lp(clientEph.PublicKey().Bytes()), lp(clientNonce),
		lp(hostEph.PublicKey().Bytes()), lp(hostNonce), lp(hostSPKI))
	hostSig := signDER(hostID, append([]byte("MBH1/host-sig"), th1...))
	th2 := sha([]byte("MBH1/th2"), th1, lp(clientSPKI), lp([]byte(clientName)), lp([]byte(platform)))
	clientSig := signDER(clientID, append([]byte("MBH1/client-sig"), th2...))
	mac := hmac.New(sha256.New, pairingSecret)
	mac.Write([]byte("MBH1/pair-proof"))
	mac.Write(th2)
	proof := mac.Sum(nil)

	shared, err := clientEph.ECDH(hostEph.PublicKey())
	must(err)
	shared2, err := hostEph.ECDH(clientEph.PublicKey())
	must(err)
	if !bytes.Equal(shared, shared2) {
		panic("ECDH mismatch")
	}
	okm := hkdfKey(shared, th2, "MBH1/keys", 64)
	keyC2H, keyH2C := okm[:32], okm[32:]
	sasBytes := hkdfKey(shared, th2, "MBH1/sas", 4)
	sas := fmt.Sprintf("%06d", binary.BigEndian.Uint32(sasBytes)%1_000_000)
	sid := "s_" + b64u.EncodeToString(hkdfKey(shared, th2, "MBH1/session-id", 12))

	ex := &v.Expected
	ex.HostDeviceID = deviceID(hostSPKI)
	ex.ClientDeviceID = deviceID(clientSPKI)
	ex.HostFingerprint = fingerprint(hostSPKI)
	ex.TH1Hex = hex.EncodeToString(th1)
	ex.HostSignature = b64u.EncodeToString(hostSig)
	ex.TH2Hex = hex.EncodeToString(th2)
	ex.ClientSignature = b64u.EncodeToString(clientSig)
	ex.PairingProofB64u = b64u.EncodeToString(proof)
	ex.SharedSecretHex = hex.EncodeToString(shared)
	ex.KeyC2HHex = hex.EncodeToString(keyC2H)
	ex.KeyH2CHex = hex.EncodeToString(keyH2C)
	ex.SAS = sas
	ex.SessionID = sid
	ex.QRURL = "mybuddy://pair?v=1&h=192.168.1.20:47811&fp=" + fingerprint(hostSPKI) +
		"&s=" + b64u.EncodeToString(pairingSecret) + "&x=1792131000&n=Salman%E2%80%99s%20MacBook%20Air"

	c2hPlain := `{"version":1,"type":"pairing.request","sessionId":"` + sid + `","sequence":1,"sentAt":"2026-10-16T08:30:00.000Z","payload":{"deviceName":"Vivo X300","platform":"android","appVersion":"0.1.0"}}`
	h2cPlain := `{"version":1,"type":"pairing.approved","sessionId":"` + sid + `","sequence":1,"sentAt":"2026-10-16T08:30:05.000Z","replyTo":1,"payload":{"hostDeviceId":"` + ex.HostDeviceID + `","hostName":"MacBook Air","grantedCapabilities":["screen.view","health.read"]}}`
	ex.Frames = []Frame{
		{"c2h", 0, c2hPlain, b64u.EncodeToString(sealFrame(keyC2H, 0x01, 0, []byte(c2hPlain)))},
		{"h2c", 0, h2cPlain, b64u.EncodeToString(sealFrame(keyH2C, 0x02, 0, []byte(h2cPlain)))},
		{"c2h", 1, `{"version":1,"type":"host.heartbeat","sessionId":"` + sid + `","sequence":2,"sentAt":"2026-10-16T08:30:06.000Z","payload":{"probe":"p1","reply":false}}`, ""},
	}
	ex.Frames[2].Frame = b64u.EncodeToString(sealFrame(keyC2H, 0x01, 1, []byte(ex.Frames[2].Plaintext)))

	// MyBuddy Connect statements (client side signs; server verifies).
	c := &v.Connect
	regMsg := append([]byte("MBC1/register"), append(lp(clientSPKI), lp([]byte(platform))...)...)
	c.RegisterMessageHex = hex.EncodeToString(regMsg)
	c.RegisterSignature = b64u.EncodeToString(signDER(clientID, regMsg))
	c.ChallengeID = "ch_test_0001"
	chNonce := seed("challenge-nonce")
	c.ChallengeNonce = b64u.EncodeToString(chNonce)
	authMsg := append([]byte("MBC1/auth"), append(append(lp([]byte(c.ChallengeID)), lp(chNonce)...), lp([]byte(ex.ClientDeviceID))...)...)
	c.AuthMessageHex = hex.EncodeToString(authMsg)
	c.AuthSignature = b64u.EncodeToString(signDER(clientID, authMsg))
	c.PairingCreatedAt = "2026-10-16T08:30:05.000Z"
	pairMsg := append([]byte("MBC1/pairing"), append(append(lp([]byte(ex.HostDeviceID)), lp([]byte(ex.ClientDeviceID))...), lp([]byte(c.PairingCreatedAt))...)...)
	c.PairingMessageHex = hex.EncodeToString(pairMsg)
	c.PairingHostSig = b64u.EncodeToString(signDER(hostID, pairMsg))
	c.PairingClientSig = b64u.EncodeToString(signDER(clientID, pairMsg))
	c.TurnSecret = "test-turn-secret-not-for-production"
	c.TurnUsername = "1792131600:" + ex.ClientDeviceID
	tm := hmac.New(sha1.New, []byte(c.TurnSecret))
	tm.Write([]byte(c.TurnUsername))
	c.TurnCredential = base64.StdEncoding.EncodeToString(tm.Sum(nil))
	c.RtcKind = "offer"
	c.RtcID = "r_7Hq2xGv0aQk1"
	c.RtcAt = "2026-10-16T08:40:00.000Z"
	c.RtcSDP = "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\na=group:BUNDLE 0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\nc=IN IP4 0.0.0.0\r\na=fingerprint:sha-256 1F:2E:3D:4C:5B:6A:79:88:97:A6:B5:C4:D3:E2:F1:00:1F:2E:3D:4C:5B:6A:79:88:97:A6:B5:C4:D3:E2:F1:00\r\na=setup:actpass\r\na=mid:0\r\na=sctp-port:5000\r\n"
	rtcMsg := append([]byte("MBC1/rtc"), append(append(append(append(append(lp([]byte(c.RtcKind)), lp([]byte(c.RtcID))...),
		lp([]byte(ex.ClientDeviceID))...), lp([]byte(ex.HostDeviceID))...), lp([]byte(c.RtcAt))...), lp([]byte(c.RtcSDP))...)...)
	c.RtcMessageHex = hex.EncodeToString(rtcMsg)
	c.RtcClientSig = b64u.EncodeToString(signDER(clientID, rtcMsg))
	env, err := json.Marshal(map[string]any{"v": 1, "kind": c.RtcKind, "rid": c.RtcID, "from": ex.ClientDeviceID, "to": ex.HostDeviceID,
		"at": c.RtcAt, "sdp": c.RtcSDP, "sig": c.RtcClientSig})
	must(err)
	c.RtcEnvelope = string(env)
	return v
}

func main() {
	out := flag.String("out", "", "write vectors to this path")
	check := flag.String("check", "", "regenerate and compare with this path")
	flag.Parse()
	data, err := json.MarshalIndent(generate(), "", "  ")
	must(err)
	data = append(data, '\n')
	switch {
	case *out != "":
		must(os.WriteFile(*out, data, 0o644))
		fmt.Println("wrote", *out)
	case *check != "":
		existing, err := os.ReadFile(*check)
		must(err)
		if !bytes.Equal(existing, data) {
			fmt.Fprintln(os.Stderr, "vectors differ from regenerated output:", *check)
			os.Exit(1)
		}
		fmt.Println("vectors match:", *check)
	default:
		os.Stdout.Write(data)
	}
}
