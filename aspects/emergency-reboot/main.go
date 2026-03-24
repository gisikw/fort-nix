package main

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"log"
	"math"
	"net"
	"os"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// Protocol: UDP packet = "<timestamp_unix>.<hmac_hex>"
// HMAC is SHA256(secret, timestamp_string).
// Timestamp must be within 30 seconds of receiver's clock.

const maxDrift = 30 * time.Second

func main() {
	secretFile := os.Getenv("SECRET_FILE")
	listenAddr := os.Getenv("LISTEN_ADDR")
	if secretFile == "" {
		log.Fatal("SECRET_FILE not set")
	}
	if listenAddr == "" {
		listenAddr = ":9999"
	}

	secret, err := os.ReadFile(secretFile)
	if err != nil {
		log.Fatalf("failed to read secret: %v", err)
	}
	secret = []byte(strings.TrimSpace(string(secret)))

	addr, err := net.ResolveUDPAddr("udp", listenAddr)
	if err != nil {
		log.Fatalf("invalid listen addr: %v", err)
	}

	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		log.Fatalf("listen: %v", err)
	}
	defer conn.Close()

	log.Printf("emergency-reboot: listening on %s", listenAddr)

	buf := make([]byte, 256)
	for {
		n, remote, err := conn.ReadFromUDP(buf)
		if err != nil {
			log.Printf("read error: %v", err)
			continue
		}

		msg := strings.TrimSpace(string(buf[:n]))
		parts := strings.SplitN(msg, ".", 2)
		if len(parts) != 2 {
			log.Printf("rejected from %s: bad format", remote)
			continue
		}

		tsStr, gotMAC := parts[0], parts[1]

		ts, err := strconv.ParseInt(tsStr, 10, 64)
		if err != nil {
			log.Printf("rejected from %s: bad timestamp", remote)
			continue
		}

		drift := time.Duration(math.Abs(float64(time.Now().Unix()-ts))) * time.Second
		if drift > maxDrift {
			log.Printf("rejected from %s: timestamp drift %s", remote, drift)
			continue
		}

		mac := hmac.New(sha256.New, secret)
		mac.Write([]byte(tsStr))
		expected := hex.EncodeToString(mac.Sum(nil))

		if !hmac.Equal([]byte(gotMAC), []byte(expected)) {
			log.Printf("rejected from %s: bad HMAC", remote)
			continue
		}

		log.Printf("ACCEPTED reboot from %s — rebooting NOW", remote)
		conn.WriteToUDP([]byte("rebooting\n"), remote)

		// Sync disks then reboot
		syscall.Sync()
		time.Sleep(500 * time.Millisecond)
		syscall.Reboot(syscall.LINUX_REBOOT_CMD_RESTART)
	}
}

// Client usage (from any host with the secret):
//   TS=$(date +%s)
//   MAC=$(echo -n "$TS" | openssl dgst -sha256 -hmac "$(cat /path/to/secret)" -hex | awk '{print $NF}')
//   echo "${TS}.${MAC}" | nc -u -w1 <host-ip> 9999
func usage() {
	fmt.Fprintln(os.Stderr, "This is a daemon, not a CLI tool. See source for client usage.")
}
