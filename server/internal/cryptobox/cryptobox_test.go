package cryptobox

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"testing"
)

// vector is testdata/push_vector.json — the known answer the Dart and
// Swift implementations are checked against too.
type vector struct {
	Scheme              string `json:"scheme"`
	EphemeralPrivateKey string `json:"ephemeralPrivateKey"`
	EphemeralPublicKey  string `json:"ephemeralPublicKey"`
	RecipientPrivateKey string `json:"recipientPrivateKey"`
	RecipientPublicKey  string `json:"recipientPublicKey"`
	Plaintext           string `json:"plaintext"`
	Ciphertext          string `json:"ciphertext"`
}

func loadVector(t *testing.T) vector {
	t.Helper()
	raw, err := os.ReadFile("testdata/push_vector.json")
	if err != nil {
		t.Fatalf("read vector: %v", err)
	}
	var v vector
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("decode vector: %v", err)
	}
	return v
}

func key32(t *testing.T, b64 string) [32]byte {
	t.Helper()
	k, err := ParsePublicKey(b64) // same decoding for private keys
	if err != nil {
		t.Fatalf("decode key: %v", err)
	}
	return k
}

func TestSeal_MatchesKnownAnswer(t *testing.T) {
	v := loadVector(t)
	if v.Scheme != Scheme {
		t.Fatalf("vector is for scheme %q, implementation is %q", v.Scheme, Scheme)
	}
	ephPub, ct, err := sealWith(key32(t, v.EphemeralPrivateKey), key32(t, v.RecipientPublicKey), []byte(v.Plaintext))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if got := base64.StdEncoding.EncodeToString(ephPub[:]); got != v.EphemeralPublicKey {
		t.Errorf("ephemeral public key = %s, want %s", got, v.EphemeralPublicKey)
	}
	if got := base64.StdEncoding.EncodeToString(ct); got != v.Ciphertext {
		t.Errorf("ciphertext = %s, want %s", got, v.Ciphertext)
	}
}

func TestOpen_KnownAnswer(t *testing.T) {
	v := loadVector(t)
	ct, _ := base64.StdEncoding.DecodeString(v.Ciphertext)
	plaintext, err := Open(key32(t, v.RecipientPrivateKey), key32(t, v.EphemeralPublicKey), ct)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	if string(plaintext) != v.Plaintext {
		t.Fatalf("plaintext = %q, want %q", plaintext, v.Plaintext)
	}
}

func TestSeal_RoundTripWithFreshKeys(t *testing.T) {
	v := loadVector(t)
	recipientPriv := key32(t, v.RecipientPrivateKey)
	ephA, ctA, err := Seal(key32(t, v.RecipientPublicKey), []byte("hello"))
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	ephB, ctB, _ := Seal(key32(t, v.RecipientPublicKey), []byte("hello"))
	if ephA == ephB || bytes.Equal(ctA, ctB) {
		t.Fatal("each seal must use a fresh ephemeral key")
	}
	got, err := Open(recipientPriv, ephA, ctA)
	if err != nil || string(got) != "hello" {
		t.Fatalf("round trip: %q, %v", got, err)
	}
}

func TestOpen_RejectsTamperingAndWrongKeys(t *testing.T) {
	v := loadVector(t)
	ct, _ := base64.StdEncoding.DecodeString(v.Ciphertext)
	tampered := append([]byte(nil), ct...)
	tampered[0] ^= 1
	if _, err := Open(key32(t, v.RecipientPrivateKey), key32(t, v.EphemeralPublicKey), tampered); err == nil {
		t.Error("a tampered ciphertext must not open")
	}
	if _, err := Open(key32(t, v.EphemeralPrivateKey), key32(t, v.EphemeralPublicKey), ct); err == nil {
		t.Error("the wrong private key must not open it")
	}
}

func TestParsePublicKey(t *testing.T) {
	if _, err := ParsePublicKey(base64.StdEncoding.EncodeToString(make([]byte, 31))); err == nil {
		t.Error("31 bytes must be rejected")
	}
	if _, err := ParsePublicKey("not base64!"); err == nil {
		t.Error("invalid base64 must be rejected")
	}
	if _, err := ParsePublicKey(base64.StdEncoding.EncodeToString(make([]byte, 32))); err != nil {
		t.Errorf("32 bytes must parse: %v", err)
	}
}

func TestSeal_RejectsLowOrderRecipientKey(t *testing.T) {
	// The all-zero point yields an all-zero shared secret.
	if _, _, err := Seal([32]byte{}, []byte("x")); err == nil {
		t.Fatal("a low-order recipient key must be rejected")
	}
}
