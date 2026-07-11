package main

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/pem"
	"math/big"
	"testing"
	"time"
)

var now = time.Date(2026, 7, 10, 12, 0, 0, 0, time.UTC)

// mkCert generates a self-signed cert valid for the given window and returns
// (certPEM, keyPEM). No live CA needed — decision logic only reads notAfter
// and the key pair.
func mkCert(t *testing.T, notBefore, notAfter time.Time) ([]byte, []byte) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: "test.example"},
		NotBefore:    notBefore,
		NotAfter:     notAfter,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	return certPEM, keyPEM
}

func days(n int) time.Duration { return time.Duration(n) * 24 * time.Hour }

// The q-6f9d966e regression: an expired cert with the acme-success marker
// still present MUST be renewed. The marker must never gate the decision.
func TestDecideRenewal_ExpiredCertWithStaleMarker(t *testing.T) {
	cert, _ := mkCert(t, now.Add(-days(90)), now.Add(-days(5))) // expired 5 days ago
	for _, marker := range []bool{true, false} {
		d := DecideRenewal(marker, cert, now, 30)
		if !d.Act {
			t.Errorf("marker=%v: expired cert must renew; got %+v", marker, d)
		}
	}
}

func TestDecideRenewal_WithinThreshold(t *testing.T) {
	cert, _ := mkCert(t, now.Add(-days(80)), now.Add(days(10)))
	if d := DecideRenewal(true, cert, now, 30); !d.Act {
		t.Errorf("cert expiring in 10d with 30d threshold must renew; got %+v", d)
	}
}

func TestDecideRenewal_Healthy(t *testing.T) {
	cert, _ := mkCert(t, now.Add(-days(10)), now.Add(days(80)))
	if d := DecideRenewal(true, cert, now, 30); d.Act {
		t.Errorf("cert valid for 80d must not renew; got %+v", d)
	}
}

func TestDecideRenewal_MissingOrGarbage(t *testing.T) {
	if d := DecideRenewal(false, nil, now, 30); !d.Act {
		t.Errorf("missing cert must renew; got %+v", d)
	}
	if d := DecideRenewal(false, []byte("not a pem"), now, 30); !d.Act {
		t.Errorf("garbage cert must renew; got %+v", d)
	}
}

// Consumer-side freshness: the 1-day self-signed placeholder must always
// read as stale so the ssl-cert need keeps re-requesting until a real cert
// arrives; a freshly renewed 90-day cert must read as fresh.
func TestIsFresh(t *testing.T) {
	placeholder, _ := mkCert(t, now, now.Add(days(1)))
	if d := IsFresh(placeholder, now, 21); d.Act {
		t.Errorf("1-day placeholder must not be fresh; got %+v", d)
	}
	renewed, _ := mkCert(t, now, now.Add(days(90)))
	if d := IsFresh(renewed, now, 21); !d.Act {
		t.Errorf("90-day cert must be fresh; got %+v", d)
	}
	if d := IsFresh(nil, now, 21); d.Act {
		t.Errorf("missing cert must not be fresh; got %+v", d)
	}
}

// The fulfilled-but-stale path (q-5118c7ed): broker renews (new cert with
// later notAfter), consumer already holds the old cert — the pushed cert
// must install; a replayed older cert must not.
func TestShouldInstall_RenewedCertReplacesOld(t *testing.T) {
	oldCert, oldKey := mkCert(t, now.Add(-days(80)), now.Add(days(10)))
	newCert, newKey := mkCert(t, now, now.Add(days(90)))

	if d := ShouldInstall(newCert, newKey, oldCert, now); !d.Act {
		t.Errorf("renewed cert must install over old; got %+v", d)
	}
	// Replay protection: pushing the old (valid key pair, earlier notAfter)
	// cert over the new one is refused on the notAfter comparison.
	if d := ShouldInstall(oldCert, oldKey, newCert, now); d.Act {
		t.Errorf("older cert must not replace newer; got %+v", d)
	}
}

func TestShouldInstall_IdenticalIsNoop(t *testing.T) {
	cert, key := mkCert(t, now, now.Add(days(90)))
	if d := ShouldInstall(cert, key, cert, now); d.Act {
		t.Errorf("identical cert must be a no-op; got %+v", d)
	}
}

func TestShouldInstall_GarbageCandidateRefused(t *testing.T) {
	current, _ := mkCert(t, now, now.Add(days(90)))
	if d := ShouldInstall([]byte("{}"), []byte("{}"), current, now); d.Act {
		t.Errorf("garbage candidate must be refused; got %+v", d)
	}
	// Empty revocation-style payload decoded to nothing:
	if d := ShouldInstall(nil, nil, current, now); d.Act {
		t.Errorf("empty candidate must be refused; got %+v", d)
	}
}

func TestShouldInstall_KeyMismatchRefused(t *testing.T) {
	current, _ := mkCert(t, now, now.Add(days(10)))
	cand, _ := mkCert(t, now, now.Add(days(90)))
	_, otherKey := mkCert(t, now, now.Add(days(90)))
	if d := ShouldInstall(cand, otherKey, current, now); d.Act {
		t.Errorf("mismatched key must be refused; got %+v", d)
	}
}

func TestShouldInstall_CurrentGarbageAcceptsValidCandidate(t *testing.T) {
	cand, key := mkCert(t, now, now.Add(days(90)))
	if d := ShouldInstall(cand, key, []byte("corrupted"), now); !d.Act {
		t.Errorf("valid candidate must install over corrupt current; got %+v", d)
	}
	if d := ShouldInstall(cand, key, nil, now); !d.Act {
		t.Errorf("valid candidate must install over missing current; got %+v", d)
	}
}

func TestShouldInstall_ExpiredCandidateOverValidCurrentRefused(t *testing.T) {
	current, _ := mkCert(t, now.Add(-days(10)), now.Add(days(30)))
	cand, key := mkCert(t, now.Add(-days(90)), now.Add(-days(1)))
	if d := ShouldInstall(cand, key, current, now); d.Act {
		t.Errorf("expired candidate must not replace valid current; got %+v", d)
	}
}

func TestValidatePair(t *testing.T) {
	cert, key := mkCert(t, now, now.Add(days(90)))
	_, otherKey := mkCert(t, now, now.Add(days(90)))

	if err := ValidatePair(cert, key); err != nil {
		t.Errorf("valid pair must validate: %v", err)
	}
	if err := ValidatePair(cert, otherKey); err == nil {
		t.Error("mismatched key must fail validation")
	}
	if err := ValidatePair([]byte("junk"), key); err == nil {
		t.Error("garbage cert must fail validation")
	}
}

func TestKeyMatches(t *testing.T) {
	cert, key := mkCert(t, now, now.Add(days(90)))
	_, otherKey := mkCert(t, now, now.Add(days(90)))

	match, err := KeyMatches(cert, key)
	if err != nil || !match {
		t.Errorf("own key must match: match=%v err=%v", match, err)
	}
	match, err = KeyMatches(cert, otherKey)
	if err != nil || match {
		t.Errorf("other key must not match: match=%v err=%v", match, err)
	}
	if _, err := KeyMatches(cert, []byte("junk")); err == nil {
		t.Error("junk key must error")
	}
}
