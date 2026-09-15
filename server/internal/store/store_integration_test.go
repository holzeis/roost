//go:build integration

// Run with: DATABASE_URL=postgres://... go test -tags=integration ./internal/store/...
// The CI workflow provides DATABASE_URL via a Postgres service container.
package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"roost/server/internal/db"
	"roost/server/internal/models"
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

	// A unique suffix per run: the DB persists across test runs (it's a
	// docker-compose volume, not reset per invocation), so a fixed identity
	// would accumulate rooms/messages from previous runs and make
	// assertions like "exactly 1 room" flaky.
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	bob, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("bob-%d@github", run), "Bob")
	if err != nil {
		t.Fatalf("create bob: %v", err)
	}

	// Re-provisioning the same identity must return the same user, not a duplicate.
	aliceAgain, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-%d@github", run), "Alice")
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

	fetched, err := s.GetRoom(ctx, room.ID)
	if err != nil {
		t.Fatalf("get room: %v", err)
	}
	if len(fetched.Members) != 2 {
		t.Fatalf("expected 2 members on the fetched room, got %+v", fetched.Members)
	}

	rooms, err := s.ListRoomsForUser(ctx, alice.ID)
	if err != nil {
		t.Fatalf("list rooms for user: %v", err)
	}
	if len(rooms) != 1 {
		t.Fatalf("expected alice to have exactly 1 room, got %+v", rooms)
	}
	if rooms[0].LastMessageBody == nil || *rooms[0].LastMessageBody != "hello from the integration test" {
		t.Fatalf("expected the room list to carry the last message preview, got %+v", rooms[0])
	}

	users, err := s.ListUsers(ctx)
	if err != nil {
		t.Fatalf("list users: %v", err)
	}
	var sawAlice, sawBob bool
	for _, u := range users {
		sawAlice = sawAlice || u.ID == alice.ID
		sawBob = sawBob || u.ID == bob.ID
	}
	if !sawAlice || !sawBob {
		t.Fatalf("expected ListUsers to include both provisioned users, got %+v", users)
	}

	direct, err := s.FindDirectRoom(ctx, alice.ID, bob.ID)
	if err != nil {
		t.Fatalf("find direct room: %v", err)
	}
	if direct.ID != room.ID {
		t.Fatalf("expected FindDirectRoom to return the existing 1:1 room %s, got %s", room.ID, direct.ID)
	}
	// Order shouldn't matter.
	if reverse, err := s.FindDirectRoom(ctx, bob.ID, alice.ID); err != nil || reverse.ID != room.ID {
		t.Fatalf("expected FindDirectRoom(bob, alice) to also find %s, got %+v, err=%v", room.ID, reverse, err)
	}

	carol, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("carol-%d@github", run), "Carol")
	if err != nil {
		t.Fatalf("create carol: %v", err)
	}
	if _, err := s.FindDirectRoom(ctx, alice.ID, carol.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a pair with no direct room, got %v", err)
	}
}

func TestStore_Reactions(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-r-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	bob, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("bob-r-%d@github", run), "Bob")
	if err != nil {
		t.Fatalf("create bob: %v", err)
	}
	room, err := s.CreateRoom(ctx, alice.ID, nil, false, []string{bob.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "react to this")
	if err != nil {
		t.Fatalf("create message: %v", err)
	}

	if err := s.AddReaction(ctx, msg.ID, alice.ID, "👍"); err != nil {
		t.Fatalf("alice react: %v", err)
	}
	if err := s.AddReaction(ctx, msg.ID, bob.ID, "👍"); err != nil {
		t.Fatalf("bob react: %v", err)
	}
	// Reacting twice with the same emoji must be a no-op, not an error or a duplicate count.
	if err := s.AddReaction(ctx, msg.ID, alice.ID, "👍"); err != nil {
		t.Fatalf("alice react again: %v", err)
	}
	if err := s.AddReaction(ctx, msg.ID, bob.ID, "❤️"); err != nil {
		t.Fatalf("bob react heart: %v", err)
	}

	messages := []models.Message{msg}
	if err := s.AttachReactions(ctx, alice.ID, messages); err != nil {
		t.Fatalf("attach reactions: %v", err)
	}
	reactions := messages[0].Reactions
	if len(reactions) != 2 {
		t.Fatalf("expected 2 distinct emoji, got %+v", reactions)
	}
	var thumbsUp, heart *models.ReactionSummary
	for i := range reactions {
		switch reactions[i].Emoji {
		case "👍":
			thumbsUp = &reactions[i]
		case "❤️":
			heart = &reactions[i]
		}
	}
	if thumbsUp == nil || thumbsUp.Count != 2 || !thumbsUp.ReactedByMe {
		t.Fatalf("expected 👍 count=2 reactedByMe=true (caller is alice), got %+v", thumbsUp)
	}
	if heart == nil || heart.Count != 1 || heart.ReactedByMe {
		t.Fatalf("expected ❤️ count=1 reactedByMe=false (caller is alice, bob reacted), got %+v", heart)
	}

	if err := s.RemoveReaction(ctx, msg.ID, alice.ID, "👍"); err != nil {
		t.Fatalf("remove reaction: %v", err)
	}
	messages = []models.Message{{ID: msg.ID}}
	if err := s.AttachReactions(ctx, alice.ID, messages); err != nil {
		t.Fatalf("attach reactions after removal: %v", err)
	}
	for _, r := range messages[0].Reactions {
		if r.Emoji == "👍" && r.Count != 1 {
			t.Fatalf("expected 👍 count=1 after alice removed hers, got %+v", messages[0].Reactions)
		}
	}
}

func TestStore_MediaMessages(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-m-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	room, err := s.CreateRoom(ctx, alice.ID, nil, true, nil)
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	objectKey := fmt.Sprintf("room/photo-%d.jpg", run)
	media, err := s.CreateMediaObject(ctx, "roost-media", objectKey, "image/jpeg", 12345, alice.ID)
	if err != nil {
		t.Fatalf("create media object: %v", err)
	}
	if media.ID == "" {
		t.Fatal("expected a generated media object id")
	}

	fetched, err := s.GetMediaObject(ctx, media.ID)
	if err != nil {
		t.Fatalf("get media object: %v", err)
	}
	if fetched.ObjectKey != objectKey || fetched.SizeBytes != 12345 {
		t.Fatalf("expected fetched media object to match what was created, got %+v", fetched)
	}

	msg, err := s.CreateMediaMessage(ctx, room.ID, alice.ID, "image", media.ID)
	if err != nil {
		t.Fatalf("create media message: %v", err)
	}
	if msg.Kind != models.MessageKindImage || msg.MediaID == nil || *msg.MediaID != media.ID {
		t.Fatalf("expected an image message referencing the media object, got %+v", msg)
	}

	if err := s.DeleteMediaObject(ctx, media.ID); err != nil {
		t.Fatalf("delete media object: %v", err)
	}
	if _, err := s.GetMediaObject(ctx, media.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound after deleting media object, got %v", err)
	}
}
