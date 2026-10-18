// Command devturn is a DEVELOPMENT-ONLY TURN relay for exercising MyBuddy's relayed path on one machine
// (Android emulator ↔ local test host). Production uses coturn (infrastructure/). It accepts the same
// short-lived credentials connect-api issues (coturn "use-auth-secret": username "<expiry>:<deviceId>",
// password base64(HMAC-SHA1(secret, username))), refuses expired ones, and listens on loopback only.
//
//	MYBUDDY_TURN_SECRET=… go run . -listen 127.0.0.1:3478 -relay-ip 192.168.1.20
package main

import (
	"crypto/hmac"
	"crypto/sha1" //nolint:gosec // mandated by the coturn REST credential scheme
	"encoding/base64"
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/pion/turn/v4"
)

// password derives the long-term credential for a REST-API username.
func password(secret []byte, username string) string {
	m := hmac.New(sha1.New, secret)
	m.Write([]byte(username))
	return base64.StdEncoding.EncodeToString(m.Sum(nil))
}

// valid reports whether a REST-API username has not expired.
func valid(username string, now time.Time) bool {
	expiry, _, ok := strings.Cut(username, ":")
	if !ok {
		return false
	}
	t, err := strconv.ParseInt(expiry, 10, 64)
	return err == nil && now.Unix() <= t
}

func main() {
	listen := flag.String("listen", "127.0.0.1:3478", "UDP address to listen on (loopback only)")
	relayIP := flag.String("relay-ip", "127.0.0.1", "IP advertised for relayed addresses (this machine's LAN IP for emulator tests)")
	realm := flag.String("realm", "mybuddy.local", "TURN realm")
	flag.Parse()

	secret := os.Getenv("MYBUDDY_TURN_SECRET")
	if secret == "" {
		if path := os.Getenv("MYBUDDY_TURN_SECRET_FILE"); path != "" {
			b, err := os.ReadFile(path)
			if err != nil {
				log.Fatalf("MYBUDDY_TURN_SECRET_FILE: %v", err)
			}
			secret = strings.TrimRight(string(b), "\r\n")
		}
	}
	if len(secret) < 16 {
		log.Fatal("set MYBUDDY_TURN_SECRET (≥ 16 bytes) to the same value connect-api uses")
	}
	host, _, err := net.SplitHostPort(*listen)
	if err != nil || !net.ParseIP(host).IsLoopback() {
		log.Fatalf("devturn listens on loopback only (got %q); use coturn for anything else", *listen)
	}
	relay := net.ParseIP(*relayIP)
	if relay == nil {
		log.Fatalf("bad -relay-ip %q", *relayIP)
	}

	conn, err := net.ListenPacket("udp4", *listen)
	if err != nil {
		log.Fatal(err)
	}
	var allocations atomic.Int64
	server, err := turn.NewServer(turn.ServerConfig{
		Realm: *realm,
		AuthHandler: func(username, realm string, src net.Addr) ([]byte, bool) {
			if !valid(username, time.Now()) {
				log.Printf("refused expired or malformed credential from %s", src)
				return nil, false
			}
			return turn.GenerateAuthKey(username, realm, password([]byte(secret), username)), true
		},
		PacketConnConfigs: []turn.PacketConnConfig{{
			PacketConn: conn,
			// Bound to the advertised address (like coturn's relay-ip), so peers see relayed packets come
			// from the relay candidate's own address and both ends report the pair as "relay".
			RelayAddressGenerator: &turn.RelayAddressGeneratorStatic{
				RelayAddress: relay,
				Address:      relay.String(),
			},
			PermissionHandler: func(src net.Addr, peer net.IP) bool {
				log.Printf("permission %s → %s (allocation #%d)", src, peer, allocations.Add(1))
				return true
			},
		}},
	})
	if err != nil {
		log.Fatal(err)
	}
	log.Printf("devturn listening on udp %s, relaying as %s (development only)", *listen, relay)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	_ = server.Close()
}
