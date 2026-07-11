// Package main implements fort-certcheck: pure decision functions for the
// certificate lifecycle (renewal, freshness, installation), separated from
// I/O so they are unit-testable without a live CA.
//
// Design note (q-6f9d966e): the NixOS acme module's `acme-<cert>.service`
// short-circuits on the `out/acme-success` marker — the marker only means
// "a real ACME cert was obtained at least once", NOT "the cert is valid".
// Every decision here is keyed on the certificate's actual notAfter; the
// marker is accepted as an input only so callers can log it, and is
// deliberately ignored by DecideRenewal.
package main

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"fmt"
	"time"
)

// Decision is the outcome of a lifecycle question plus a human-readable reason.
type Decision struct {
	Act    bool
	Reason string
}

// NotAfter extracts the expiry of the first CERTIFICATE block in pemData.
func NotAfter(pemData []byte) (time.Time, error) {
	cert, err := parseFirstCert(pemData)
	if err != nil {
		return time.Time{}, err
	}
	return cert.NotAfter, nil
}

func parseFirstCert(pemData []byte) (*x509.Certificate, error) {
	for rest := pemData; len(rest) > 0; {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		return x509.ParseCertificate(block.Bytes)
	}
	return nil, fmt.Errorf("no CERTIFICATE block found")
}

// DecideRenewal answers "does this cert need to be (re)ordered right now?".
//
// markerExists (the acme-success marker) is IGNORED for the decision — a
// stale marker over an expired cert must still yield renew=true. It is only
// echoed into the reason so operators can see the mismatch.
//
// certPEM == nil means the cert file is missing.
func DecideRenewal(markerExists bool, certPEM []byte, now time.Time, minValidDays int) Decision {
	suffix := ""
	if markerExists {
		suffix = " (acme-success marker present; ignored)"
	}

	if len(certPEM) == 0 {
		return Decision{true, "certificate missing" + suffix}
	}
	notAfter, err := NotAfter(certPEM)
	if err != nil {
		return Decision{true, fmt.Sprintf("certificate unreadable: %v%s", err, suffix)}
	}
	remaining := notAfter.Sub(now)
	if remaining <= 0 {
		return Decision{true, fmt.Sprintf("certificate expired %s ago%s", (-remaining).Round(time.Hour), suffix)}
	}
	if remaining < time.Duration(minValidDays)*24*time.Hour {
		return Decision{true, fmt.Sprintf("certificate expires in %s (< %dd threshold)%s", remaining.Round(time.Hour), minValidDays, suffix)}
	}
	return Decision{false, fmt.Sprintf("certificate valid for %s", remaining.Round(time.Hour))}
}

// IsFresh answers the consumer-side question "is my local copy of the cert
// still good enough, or should the ssl-cert need be re-requested?".
// It is the same expiry math as DecideRenewal but named separately because
// the thresholds differ (consumer freshness must be below the broker's
// renewal threshold, or consumers would flap before the broker renews).
func IsFresh(certPEM []byte, now time.Time, minValidDays int) Decision {
	d := DecideRenewal(false, certPEM, now, minValidDays)
	return Decision{!d.Act, d.Reason}
}

// ValidatePair reports whether certPEM parses and keyPEM is its private key.
// Consumers use this to distinguish "candidate is garbage — retry later"
// from "candidate is valid but not an improvement — no-op".
func ValidatePair(certPEM, keyPEM []byte) error {
	if _, err := parseFirstCert(certPEM); err != nil {
		return fmt.Errorf("cert unreadable: %w", err)
	}
	match, err := KeyMatches(certPEM, keyPEM)
	if err != nil {
		return fmt.Errorf("key unreadable: %w", err)
	}
	if !match {
		return fmt.Errorf("key does not match cert")
	}
	return nil
}

// ShouldInstall answers "should this pushed cert/key pair replace what is on
// disk?". Rules:
//   - candidate must parse and the key must match the cert (else never install)
//   - candidate expired while current is valid → keep current
//   - candidate identical to current → no-op
//   - current missing/unreadable → install
//   - candidate notAfter earlier than current's → keep current (stale replay)
//   - otherwise → install
func ShouldInstall(candCertPEM, candKeyPEM, currentCertPEM []byte, now time.Time) Decision {
	candCert, err := parseFirstCert(candCertPEM)
	if err != nil {
		return Decision{false, fmt.Sprintf("candidate cert unreadable: %v", err)}
	}
	match, err := KeyMatches(candCertPEM, candKeyPEM)
	if err != nil {
		return Decision{false, fmt.Sprintf("candidate key unreadable: %v", err)}
	}
	if !match {
		return Decision{false, "candidate key does not match candidate cert"}
	}

	current, currentErr := parseFirstCert(currentCertPEM)
	if currentErr != nil {
		return Decision{true, "current cert missing or unreadable; installing candidate"}
	}

	if bytes.Equal(bytes.TrimSpace(candCertPEM), bytes.TrimSpace(currentCertPEM)) {
		return Decision{false, "candidate identical to current cert"}
	}
	if !candCert.NotAfter.After(now) && current.NotAfter.After(now) {
		return Decision{false, "candidate expired while current cert is still valid"}
	}
	if candCert.NotAfter.Before(current.NotAfter) {
		return Decision{false, fmt.Sprintf("candidate notAfter %s earlier than current %s", candCert.NotAfter.Format(time.RFC3339), current.NotAfter.Format(time.RFC3339))}
	}
	return Decision{true, fmt.Sprintf("candidate is newer (notAfter %s)", candCert.NotAfter.Format(time.RFC3339))}
}

// KeyMatches reports whether keyPEM's public key matches certPEM's.
func KeyMatches(certPEM, keyPEM []byte) (bool, error) {
	cert, err := parseFirstCert(certPEM)
	if err != nil {
		return false, err
	}
	key, err := parsePrivateKey(keyPEM)
	if err != nil {
		return false, err
	}
	type pubKeyed interface{ Public() interface{} }

	switch pub := cert.PublicKey.(type) {
	case *rsa.PublicKey:
		k, ok := key.(*rsa.PrivateKey)
		return ok && pub.Equal(&k.PublicKey), nil
	case *ecdsa.PublicKey:
		k, ok := key.(*ecdsa.PrivateKey)
		return ok && pub.Equal(&k.PublicKey), nil
	case ed25519.PublicKey:
		k, ok := key.(ed25519.PrivateKey)
		return ok && pub.Equal(k.Public()), nil
	default:
		if k, ok := key.(pubKeyed); ok {
			type equaler interface{ Equal(x interface{}) bool }
			if e, ok := cert.PublicKey.(equaler); ok {
				return e.Equal(k.Public()), nil
			}
		}
		return false, fmt.Errorf("unsupported public key type %T", cert.PublicKey)
	}
}

func parsePrivateKey(pemData []byte) (interface{}, error) {
	for rest := pemData; len(rest) > 0; {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		switch block.Type {
		case "PRIVATE KEY":
			return x509.ParsePKCS8PrivateKey(block.Bytes)
		case "RSA PRIVATE KEY":
			return x509.ParsePKCS1PrivateKey(block.Bytes)
		case "EC PRIVATE KEY":
			return x509.ParseECPrivateKey(block.Bytes)
		}
	}
	return nil, fmt.Errorf("no private key block found")
}
