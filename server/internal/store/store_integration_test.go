//go:build integration

// Run with: DATABASE_URL=postgres://... go test -tags=integration ./internal/store/...
// The CI workflow provides DATABASE_URL via a Postgres service container.
package store

import (
	"context"
	"os"
	"testing"
	"time"

	"roost/server/internal/db"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		t.Skip("DATABASE_URL not set; skipping integration test")
	}

	if err := db.Migrate(url); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := db.Connect(context.Background(), url)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)
	return New(pool)
}

func TestStore_RoomAndMessageLifecycle(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, "alice@github-"+t.Name(), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	bob, err := s.GetOrCreateUserByTailscaleID(ctx, "bob@github-"+t.Name(), "Bob")
	if err != nil {
		t.Fatalf("create bob: %v", err)
	}

	// Re-provisioning the same identity must return the same user, not a duplicate.
	aliceAgain, err := s.GetOrCreateUserByTailscaleID(ctx, "alice@github-"+t.Name(), "Alice")
	if err != nil {
		t.Fatalf("re-provision alice: %v", err)
	}
	if aliceAgain.ID != alice.ID {
		t.Fatalf("expected re-provisioning to return the same user, got %s != %s", aliceAgain.ID, alice.ID)
	}

	room, err := s.CreateRoom(ctx, alice.ID, nil, false, []string{bob.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	isMember, err := s.IsRoomMember(ctx, room.ID, bob.ID)
	if err != nil || !isMember {
		t.Fatalf("expected bob to be a member of the room, err=%v isMember=%v", err, isMember)
	}

	msg, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "hello from the integration test")
	if err != nil {
		t.Fatalf("create message: %v", err)
	}

	messages, err := s.ListMessages(ctx, room.ID, time.Time{}, 50)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if len(messages) != 1 || messages[0].ID != msg.ID {
		t.Fatalf("expected exactly the message just created, got %+v", messages)
	}

	found, err := s.SearchMessages(ctx, room.ID, "hello")
	if err != nil {
		t.Fatalf("search messages: %v", err)
	}
	if len(found) != 1 || found[0].ID != msg.ID {
		t.Fatalf("expected search to find the message, got %+v", found)
	}
}
