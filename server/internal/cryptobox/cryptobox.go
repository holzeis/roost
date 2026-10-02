// Package cryptobox encrypts message previews for push notifications
// (FR5.2) so that only the receiving device can read them: Apple's and
// Google's push services, which carry the notification outside the
// tailnet, only ever see ciphertext.
//
// It's an anonymous-sender "sealed box": for every message the server
// makes a fresh ephemeral X25519 key pair, agrees a shared secret with the
// device's long-term public key, derives a one-time key with HKDF-SHA256
// and encrypts with ChaCha20-Poly1305. The nonce is fixed (all zero),
// which is safe because the key is never reused: it's unique per message
// by construction, the same reasoning libsodium's sealed box and age use.
// HKDF's info binds both public keys and the scheme name, so a mismatch
// between the three implementations (this one, the Dart one in
// app/lib/services/push_crypto.dart and the Swift one in the iOS
// notification extension) can't silently produce a valid but different
// key. All three are checked against testdata/push_vector.json.
//
// Pure Go (golang.org/x/crypto), since the server is built with
// CGO_ENABLED=0.
package cryptobox

import (
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"io"

	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/crypto/hkdf"
)

// Scheme names this construction on the wire, so it can change later
// without guessing which one a payload used.
const Scheme = "v1"

// domain is mixed into HKDF's info.
const domain = "roost-push-v1"

// ParsePublicKey decodes a base64 (standard encoding) X25519 public key.
func ParsePublicKey(b64 string) ([32]byte, error) {
	var key [32]byte
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return key, fmt.Errorf("cryptobox: decode public key: %w", err)
	}
	if len(raw) != 32 {
		return key, fmt.Errorf("cryptobox: public key is %d bytes, want 32", len(raw))
	}
	copy(key[:], raw)
	return key, nil
}

// Seal encrypts plaintext so only the holder of recipientPub's private key
// can read it, returning the ephemeral public key the recipient needs
// alongside the ciphertext.
func Seal(recipientPub [32]byte, plaintext []byte) (ephemeralPub [32]byte, ciphertext []byte, err error) {
	var ephemeralPriv [32]byte
	if _, err := io.ReadFull(rand.Reader, ephemeralPriv[:]); err != nil {
		return ephemeralPub, nil, fmt.Errorf("cryptobox: generate ephemeral key: %w", err)
	}
	return sealWith(ephemeralPriv, recipientPub, plaintext)
}

// sealWith is Seal with a given ephemeral private key — deterministic, for
// the known-answer test vector shared with the app's implementations.
func sealWith(ephemeralPriv, recipientPub [32]byte, plaintext []byte) ([32]byte, []byte, error) {
	var ephemeralPub [32]byte
	pub, err := curve25519.X25519(ephemeralPriv[:], curve25519.Basepoint)
	if err != nil {
		return ephemeralPub, nil, fmt.Errorf("cryptobox: ephemeral public key: %w", err)
	}
	copy(ephemeralPub[:], pub)
	aead, err := deriveAEAD(ephemeralPriv[:], recipientPub[:], ephemeralPub, recipientPub)
	if err != nil {
		return ephemeralPub, nil, err
	}
	return ephemeralPub, aead.Seal(nil, make([]byte, chacha20poly1305.NonceSize), plaintext, nil), nil
}

// Open decrypts what Seal produced, given the recipient's private key.
// Production server code never needs it; it exists so the construction is
// testable end to end in Go.
func Open(recipientPriv, ephemeralPub [32]byte, ciphertext []byte) ([]byte, error) {
	recipientPub, err := curve25519.X25519(recipientPriv[:], curve25519.Basepoint)
	if err != nil {
		return nil, fmt.Errorf("cryptobox: recipient public key: %w", err)
	}
	var recipientPubArr [32]byte
	copy(recipientPubArr[:], recipientPub)
	aead, err := deriveAEAD(recipientPriv[:], ephemeralPub[:], ephemeralPub, recipientPubArr)
	if err != nil {
		return nil, err
	}
	plaintext, err := aead.Open(nil, make([]byte, chacha20poly1305.NonceSize), ciphertext, nil)
	if err != nil {
		return nil, errors.New("cryptobox: message authentication failed")
	}
	return plaintext, nil
}

func deriveAEAD(privateKey, peerPublic []byte, ephemeralPub, recipientPub [32]byte) (cipher.AEAD, error) {
	// X25519 rejects low-order peer keys (an all-zero shared secret).
	shared, err := curve25519.X25519(privateKey, peerPublic)
	if err != nil {
		return nil, fmt.Errorf("cryptobox: key agreement: %w", err)
	}
	info := make([]byte, 0, 64+len(domain))
	info = append(info, ephemeralPub[:]...)
	info = append(info, recipientPub[:]...)
	info = append(info, domain...)
	key := make([]byte, chacha20poly1305.KeySize)
	if _, err := io.ReadFull(hkdf.New(sha256.New, shared, nil, info), key); err != nil {
		return nil, fmt.Errorf("cryptobox: derive key: %w", err)
	}
	return chacha20poly1305.New(key)
}
