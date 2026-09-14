package livekit

import (
	"testing"

	auth "github.com/livekit/protocol/auth"
)

func TestMinter_Token_GrantsRoomJoin(t *testing.T) {
	m := NewMinter("test-key", "test-secret-at-least-32-bytes-long")

	raw, err := m.Token("user-123", "room-abc")
	if err != nil {
		t.Fatalf("Token() error = %v", err)
	}

	verifier, err := auth.ParseAPIToken(raw)
	if err != nil {
		t.Fatalf("ParseAPIToken() error = %v", err)
	}
	if verifier.Identity() != "user-123" {
		t.Errorf("identity = %q, want %q", verifier.Identity(), "user-123")
	}

	_, grants, err := verifier.Verify("test-secret-at-least-32-bytes-long")
	if err != nil {
		t.Fatalf("Verify() error = %v", err)
	}
	if grants.Video == nil || !grants.Video.RoomJoin {
		t.Fatal("expected a video grant with RoomJoin = true")
	}
	if grants.Video.Room != "room-abc" {
		t.Errorf("room = %q, want %q", grants.Video.Room, "room-abc")
	}
}
