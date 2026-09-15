//go:build integration

// Run with: DATABASE_URL=postgres://... go test -tags=integration ./internal/store/...
// The CI workflow provides DATABASE_URL via a Postgres service container.
package store

import (
	"context"
	"errors"
	"fmt"
	"os"
	"reflect"
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

	msg, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "hello from the integration test", nil, false)
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
	// Regression check: the client resolves a 1:1 room's display name from
	// its member IDs (it has no room name of its own), so ListRoomsForUser
	// must include members, not just GetRoom.
	if len(rooms[0].Members) != 2 {
		t.Fatalf("expected ListRoomsForUser to include both members, got %+v", rooms[0].Members)
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
	msg, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "react to this", nil, false)
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

func TestStore_MessageReceipts_OneToOne(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-mr1-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	bob, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("bob-mr1-%d@github", run), "Bob")
	if err != nil {
		t.Fatalf("create bob: %v", err)
	}
	room, err := s.CreateRoom(ctx, alice.ID, nil, false, []string{bob.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "read this", nil, false)
	if err != nil {
		t.Fatalf("create message: %v", err)
	}

	assertStatus := func(want models.MessageStatus) {
		t.Helper()
		messages := []models.Message{{ID: msg.ID, RoomID: room.ID}}
		if err := s.AttachStatus(ctx, messages); err != nil {
			t.Fatalf("attach status: %v", err)
		}
		if got := messages[0].Status; got != want {
			t.Fatalf("status = %v, want %v", got, want)
		}
	}

	// Before bob has acked anything, the message is only sent.
	assertStatus(models.MessageStatusSent)

	if err := s.MarkReceipts(ctx, room.ID, bob.ID, []string{msg.ID}, false); err != nil {
		t.Fatalf("mark delivered: %v", err)
	}
	assertStatus(models.MessageStatusDelivered)

	if err := s.MarkReceipts(ctx, room.ID, bob.ID, []string{msg.ID}, true); err != nil {
		t.Fatalf("mark seen: %v", err)
	}
	assertStatus(models.MessageStatusSeen)
}

func TestStore_MessageReceipts_GroupRequiresAllMembers(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-mrg-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	bob, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("bob-mrg-%d@github", run), "Bob")
	if err != nil {
		t.Fatalf("create bob: %v", err)
	}
	carol, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("carol-mrg-%d@github", run), "Carol")
	if err != nil {
		t.Fatalf("create carol: %v", err)
	}
	name := "Family"
	room, err := s.CreateRoom(ctx, alice.ID, &name, true, []string{bob.ID, carol.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "group message", nil, false)
	if err != nil {
		t.Fatalf("create message: %v", err)
	}

	status := func() models.MessageStatus {
		t.Helper()
		messages := []models.Message{{ID: msg.ID, RoomID: room.ID}}
		if err := s.AttachStatus(ctx, messages); err != nil {
			t.Fatalf("attach status: %v", err)
		}
		return messages[0].Status
	}

	// Only one of the two recipients has it: not "delivered" yet.
	if err := s.MarkReceipts(ctx, room.ID, bob.ID, []string{msg.ID}, false); err != nil {
		t.Fatalf("bob mark delivered: %v", err)
	}
	if got := status(); got != models.MessageStatusSent {
		t.Fatalf("status after only bob delivered = %v, want sent", got)
	}

	// The second recipient also has it: now "delivered".
	if err := s.MarkReceipts(ctx, room.ID, carol.ID, []string{msg.ID}, false); err != nil {
		t.Fatalf("carol mark delivered: %v", err)
	}
	if got := status(); got != models.MessageStatusDelivered {
		t.Fatalf("status after both delivered = %v, want delivered", got)
	}

	// Only one of the two has seen it: still "delivered", not "seen".
	if err := s.MarkReceipts(ctx, room.ID, bob.ID, []string{msg.ID}, true); err != nil {
		t.Fatalf("bob mark seen: %v", err)
	}
	if got := status(); got != models.MessageStatusDelivered {
		t.Fatalf("status after only bob saw it = %v, want delivered", got)
	}

	// Both have seen it: "seen".
	if err := s.MarkReceipts(ctx, room.ID, carol.ID, []string{msg.ID}, true); err != nil {
		t.Fatalf("carol mark seen: %v", err)
	}
	if got := status(); got != models.MessageStatusSeen {
		t.Fatalf("status after both saw it = %v, want seen", got)
	}
}

func TestStore_MessageReceipts_ScopedToRoom(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-mrs-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	bob, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("bob-mrs-%d@github", run), "Bob")
	if err != nil {
		t.Fatalf("create bob: %v", err)
	}
	roomA, err := s.CreateRoom(ctx, alice.ID, nil, false, []string{bob.ID})
	if err != nil {
		t.Fatalf("create room a: %v", err)
	}
	roomB, err := s.CreateRoom(ctx, alice.ID, nil, false, []string{bob.ID})
	if err != nil {
		t.Fatalf("create room b: %v", err)
	}
	msgInB, err := s.CreateTextMessage(ctx, roomB.ID, alice.ID, "belongs to room b", nil, false)
	if err != nil {
		t.Fatalf("create message: %v", err)
	}

	// Acking msgInB's id while scoped to roomA must not write a receipt —
	// the WHERE m.room_id = $3 clause should exclude it.
	if err := s.MarkReceipts(ctx, roomA.ID, bob.ID, []string{msgInB.ID}, false); err != nil {
		t.Fatalf("mark receipts scoped to wrong room: %v", err)
	}
	messages := []models.Message{{ID: msgInB.ID, RoomID: roomB.ID}}
	if err := s.AttachStatus(ctx, messages); err != nil {
		t.Fatalf("attach status: %v", err)
	}
	if got := messages[0].Status; got != models.MessageStatusSent {
		t.Fatalf("status = %v, want sent (receipt should not have been written)", got)
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

	msg, err := s.CreateMediaMessage(ctx, room.ID, alice.ID, "image", media.ID, nil, false)
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

// TestStore_EmptyListsAreNeverNil guards against a real bug that shipped:
// json.Marshal encodes a nil Go slice as `null`, which crashed the Dart
// client's `as List<dynamic>` cast the first time a brand-new user (zero
// rooms, zero messages) actually hit the API. `reflect` checks Go-level
// nilness directly, since `len(x) == 0` is true for both nil and non-nil
// empty slices but only one of them marshals to `[]`.
func TestStore_EmptyListsAreNeverNil(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-empty-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}

	rooms, err := s.ListRoomsForUser(ctx, alice.ID)
	if err != nil {
		t.Fatalf("list rooms for user: %v", err)
	}
	if reflect.ValueOf(rooms).IsNil() {
		t.Fatal("ListRoomsForUser returned a nil slice for a user with no rooms; it must marshal to [] not null")
	}

	room, err := s.CreateRoom(ctx, alice.ID, nil, true, nil)
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	messages, err := s.ListMessages(ctx, room.ID, time.Time{}, 50)
	if err != nil {
		t.Fatalf("list messages: %v", err)
	}
	if reflect.ValueOf(messages).IsNil() {
		t.Fatal("ListMessages returned a nil slice for a room with no messages; it must marshal to [] not null")
	}

	found, err := s.SearchMessages(ctx, room.ID, "nonexistent")
	if err != nil {
		t.Fatalf("search messages: %v", err)
	}
	if reflect.ValueOf(found).IsNil() {
		t.Fatal("SearchMessages returned a nil slice for no matches; it must marshal to [] not null")
	}
}

func TestStore_ReplyPreview(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-reply-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	room, err := s.CreateRoom(ctx, alice.ID, nil, true, nil)
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	original, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "the original message", nil, false)
	if err != nil {
		t.Fatalf("create original: %v", err)
	}
	reply, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "replying to it", &original.ID, false)
	if err != nil {
		t.Fatalf("create reply: %v", err)
	}
	if reply.ReplyToMessageID == nil || *reply.ReplyToMessageID != original.ID {
		t.Fatalf("expected reply to reference the original, got %+v", reply)
	}

	messages := []models.Message{reply}
	if err := s.AttachReplyPreviews(ctx, messages); err != nil {
		t.Fatalf("attach reply previews: %v", err)
	}
	if messages[0].ReplyTo == nil || messages[0].ReplyTo.ID != original.ID || messages[0].ReplyTo.Body == nil ||
		*messages[0].ReplyTo.Body != "the original message" {
		t.Fatalf("expected reply preview to snapshot the original message, got %+v", messages[0].ReplyTo)
	}

	// Deleting the original must not break the reply — it should just lose
	// its preview (ON DELETE SET NULL), not fail to load or cascade-delete.
	if _, err := s.pool.Exec(ctx, "DELETE FROM messages WHERE id = $1", original.ID); err != nil {
		t.Fatalf("delete original: %v", err)
	}
	refetched, err := s.GetMessage(ctx, reply.ID)
	if err != nil {
		t.Fatalf("get reply after original deleted: %v", err)
	}
	if refetched.ReplyToMessageID != nil {
		t.Fatalf("expected reply_to_message_id to be nulled out after the original was deleted, got %+v", refetched.ReplyToMessageID)
	}
}

func TestStore_EditMessage(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-edit-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	room, err := s.CreateRoom(ctx, alice.ID, nil, true, nil)
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "typo", nil, false)
	if err != nil {
		t.Fatalf("create message: %v", err)
	}
	if msg.EditedAt != nil {
		t.Fatalf("expected a freshly created message to have no edited_at, got %v", msg.EditedAt)
	}

	edited, err := s.EditMessageBody(ctx, msg.ID, "fixed")
	if err != nil {
		t.Fatalf("edit message: %v", err)
	}
	if edited.Body == nil || *edited.Body != "fixed" {
		t.Fatalf("expected edited body to be updated, got %+v", edited.Body)
	}
	if edited.EditedAt == nil {
		t.Fatal("expected edited_at to be set after an edit")
	}
}

func TestStore_ForwardDuplicatesMedia(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-fwd-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	room, err := s.CreateRoom(ctx, alice.ID, nil, true, nil)
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	src, err := s.CreateMediaObject(ctx, "roost-media", fmt.Sprintf("room/orig-%d.jpg", run), "image/jpeg", 42, alice.ID)
	if err != nil {
		t.Fatalf("create source media: %v", err)
	}
	dup, err := s.CreateMediaObject(ctx, "roost-media", fmt.Sprintf("room/dup-%d.jpg", run), "image/jpeg", 42, alice.ID)
	if err != nil {
		t.Fatalf("create duplicated media: %v", err)
	}
	if dup.ID == src.ID {
		t.Fatal("expected the duplicated media object to have its own id, distinct from the source")
	}

	forwarded, err := s.CreateMediaMessage(ctx, room.ID, alice.ID, "image", dup.ID, nil, true)
	if err != nil {
		t.Fatalf("create forwarded message: %v", err)
	}
	if !forwarded.Forwarded {
		t.Fatalf("expected forwarded message to have Forwarded=true, got %+v", forwarded)
	}
	if forwarded.MediaID == nil || *forwarded.MediaID != dup.ID {
		t.Fatalf("expected forwarded message to reference the duplicated media object, got %+v", forwarded.MediaID)
	}

	// Deleting the duplicate must not affect the source — independent
	// ownership/delete semantics is the whole point of duplicating.
	if err := s.DeleteMediaObject(ctx, dup.ID); err != nil {
		t.Fatalf("delete duplicated media: %v", err)
	}
	if _, err := s.GetMediaObject(ctx, src.ID); err != nil {
		t.Fatalf("expected source media to survive deleting its duplicate, got %v", err)
	}
}

func TestStore_LocationShare_CreateAttachUpdateEnd(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-loc-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	bob, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("bob-loc-%d@github", run), "Bob")
	if err != nil {
		t.Fatalf("create bob: %v", err)
	}
	room, err := s.CreateRoom(ctx, alice.ID, nil, false, []string{bob.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	msg, err := s.CreateLocationMessage(ctx, room.ID, alice.ID, 52.5, 13.4, 15*time.Minute)
	if err != nil {
		t.Fatalf("create location message: %v", err)
	}
	if msg.Kind != models.MessageKindLocation {
		t.Fatalf("expected kind=location, got %v", msg.Kind)
	}
	if msg.Location == nil || msg.Location.Lat != 52.5 || msg.Location.Lng != 13.4 {
		t.Fatalf("expected the create response to already carry the share, got %+v", msg.Location)
	}

	// AttachLocations must independently reproduce the same data on a
	// freshly-fetched message (the path every list/search response uses).
	fetched := []models.Message{{ID: msg.ID, Kind: models.MessageKindLocation}}
	if err := s.AttachLocations(ctx, fetched); err != nil {
		t.Fatalf("attach locations: %v", err)
	}
	share := fetched[0].Location
	if share == nil || share.Lat != 52.5 || share.Lng != 13.4 || share.EndedAt != nil {
		t.Fatalf("unexpected attached share: %+v", share)
	}
	if !share.Active(time.Now()) {
		t.Fatal("expected a freshly created 15-minute share to be active")
	}

	updated, err := s.UpdateLocationPosition(ctx, msg.ID, 52.52, 13.41)
	if err != nil {
		t.Fatalf("update position: %v", err)
	}
	if updated.Lat != 52.52 || updated.Lng != 13.41 {
		t.Fatalf("expected updated coordinates, got %+v", updated)
	}

	ended, err := s.EndLocationShare(ctx, msg.ID)
	if err != nil {
		t.Fatalf("end share: %v", err)
	}
	if ended.EndedAt == nil {
		t.Fatal("expected EndedAt to be set after ending the share")
	}
	// Anchored to ended.EndedAt itself rather than time.Now() — the DB
	// server's clock and this test process's clock can differ by tens of
	// milliseconds, which is enough to flake a comparison made this close
	// to the write (the same reason handleEditMessage's editWindow check
	// tolerates only server-observed durations, not cross-clock instants).
	if ended.Active(ended.EndedAt.Add(time.Second)) {
		t.Fatal("expected an ended share to no longer be active shortly after ending")
	}

	// Ending an already-ended share is idempotent — the second call must not
	// error or move EndedAt forward.
	endedAgain, err := s.EndLocationShare(ctx, msg.ID)
	if err != nil {
		t.Fatalf("end already-ended share: %v", err)
	}
	if !endedAgain.EndedAt.Equal(*ended.EndedAt) {
		t.Fatalf("expected EndedAt to stay the same, got %v then %v", ended.EndedAt, endedAgain.EndedAt)
	}
}

func TestStore_LocationShare_MultipleActiveSharesInARoom(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-locg-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	bob, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("bob-locg-%d@github", run), "Bob")
	if err != nil {
		t.Fatalf("create bob: %v", err)
	}
	name := "Family"
	room, err := s.CreateRoom(ctx, alice.ID, &name, true, []string{bob.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	// FR3.8: when multiple members share location in the same room, each
	// share must come back independently correct from a single batch call.
	aliceShare, err := s.CreateLocationMessage(ctx, room.ID, alice.ID, 10, 10, time.Hour)
	if err != nil {
		t.Fatalf("alice share: %v", err)
	}
	bobShare, err := s.CreateLocationMessage(ctx, room.ID, bob.ID, 20, 20, time.Hour)
	if err != nil {
		t.Fatalf("bob share: %v", err)
	}

	messages := []models.Message{
		{ID: aliceShare.ID, Kind: models.MessageKindLocation},
		{ID: bobShare.ID, Kind: models.MessageKindLocation},
	}
	if err := s.AttachLocations(ctx, messages); err != nil {
		t.Fatalf("attach locations: %v", err)
	}
	if messages[0].Location == nil || messages[0].Location.Lat != 10 {
		t.Fatalf("expected alice's own share at lat=10, got %+v", messages[0].Location)
	}
	if messages[1].Location == nil || messages[1].Location.Lat != 20 {
		t.Fatalf("expected bob's own share at lat=20, got %+v", messages[1].Location)
	}
}

func TestStore_LocationShare_GetLocationShareNotFound(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	alice, err := s.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alice-locnf-%d@github", run), "Alice")
	if err != nil {
		t.Fatalf("create alice: %v", err)
	}
	room, err := s.CreateRoom(ctx, alice.ID, nil, true, nil)
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	// A plain text message has no location_shares row.
	textMsg, err := s.CreateTextMessage(ctx, room.ID, alice.ID, "not a location", nil, false)
	if err != nil {
		t.Fatalf("create text message: %v", err)
	}

	if _, err := s.GetLocationShare(ctx, textMsg.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected ErrNotFound for a message with no location share, got %v", err)
	}
}
