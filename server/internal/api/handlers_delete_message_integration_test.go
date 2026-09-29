//go:build integration

package api

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"roost/server/internal/models"
	"roost/server/internal/session"
	"roost/server/internal/store"
	"roost/server/internal/ws"
)

// TestHandleDeleteMessage_SenderCanDeleteTheirOwnTextMessage implements
// FR1.15: the sender can remove one of their own text messages, and it's
// then really gone rather than merely hidden.
func TestHandleDeleteMessage_SenderCanDeleteTheirOwnTextMessage(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("delete-msg-test-%d@github", run), "Deleter")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, user.ID, nil, false, []string{user.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.Store.CreateTextMessage(ctx, room.ID, user.ID, "delete me", nil, false)
	if err != nil {
		t.Fatalf("create text message: %v", err)
	}

	req := httptest.NewRequest(http.MethodDelete, "/api/messages/"+msg.ID, nil)
	req = req.WithContext(session.WithUser(req.Context(), user))
	req = withURLParam(req, "messageID", msg.ID)
	rec := httptest.NewRecorder()

	s.handleDeleteMessage(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if _, err := s.Store.GetMessage(ctx, msg.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("expected message to be gone, got err=%v", err)
	}
}

// TestHandleDeleteMessage_RejectsAnotherUsersMessage guards the ownership
// check — a room member shouldn't be able to delete someone else's message
// just because they're in the same room.
func TestHandleDeleteMessage_RejectsAnotherUsersMessage(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	sender, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("delete-msg-sender-%d@github", run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	other, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("delete-msg-other-%d@github", run), "Other")
	if err != nil {
		t.Fatalf("create other user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, true, []string{sender.ID, other.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.Store.CreateTextMessage(ctx, room.ID, sender.ID, "not yours", nil, false)
	if err != nil {
		t.Fatalf("create text message: %v", err)
	}

	req := httptest.NewRequest(http.MethodDelete, "/api/messages/"+msg.ID, nil)
	req = req.WithContext(session.WithUser(req.Context(), other))
	req = withURLParam(req, "messageID", msg.ID)
	rec := httptest.NewRecorder()

	s.handleDeleteMessage(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d: %s", rec.Code, rec.Body.String())
	}
	if _, err := s.Store.GetMessage(ctx, msg.ID); err != nil {
		t.Fatalf("expected message to still exist, got err=%v", err)
	}
}

// TestHandleDeleteMessage_RejectsImageAndVideoKinds points callers at
// handleDeleteMedia instead, which also removes the underlying file —
// something a plain row delete here can't do.
func TestHandleDeleteMessage_RejectsImageAndVideoKinds(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("delete-msg-media-%d@github", run), "Shutterbug")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, user.ID, nil, false, []string{user.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	mediaObj, err := s.Store.CreateMediaObject(ctx, s.Media.Bucket(), fmt.Sprintf("test/%d.jpg", run), "image/jpeg", 3, user.ID, nil, nil, nil)
	if err != nil {
		t.Fatalf("create media object: %v", err)
	}
	msg, err := s.Store.CreateMediaMessage(ctx, room.ID, user.ID, "image", mediaObj.ID, nil, nil, false)
	if err != nil {
		t.Fatalf("create media message: %v", err)
	}

	req := httptest.NewRequest(http.MethodDelete, "/api/messages/"+msg.ID, nil)
	req = req.WithContext(session.WithUser(req.Context(), user))
	req = withURLParam(req, "messageID", msg.ID)
	rec := httptest.NewRecorder()

	s.handleDeleteMessage(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
	if _, err := s.Store.GetMessage(ctx, msg.ID); err != nil {
		t.Fatalf("expected message to still exist, got err=%v", err)
	}
}

// deleteTestRoom creates a sender and a recipient sharing a 1:1 room, plus
// one text message from the sender — the fixture every FR1.15
// seen-vs-unseen test below starts from.
func deleteTestRoom(t *testing.T, s *Server, name string) (sender, recipient models.User, roomID string, msg models.Message) {
	t.Helper()
	ctx := context.Background()
	run := time.Now().UnixNano()
	var err error
	sender, err = s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("%s-sender-%d@github", name, run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	recipient, err = s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("%s-recipient-%d@github", name, run), "Recipient")
	if err != nil {
		t.Fatalf("create recipient: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, false, []string{sender.ID, recipient.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err = s.Store.CreateTextMessage(ctx, room.ID, sender.ID, "secret plans", nil, false)
	if err != nil {
		t.Fatalf("create text message: %v", err)
	}
	return sender, recipient, room.ID, msg
}

func deleteMessageAs(t *testing.T, s *Server, user models.User, messageID string) {
	t.Helper()
	req := httptest.NewRequest(http.MethodDelete, "/api/messages/"+messageID, nil)
	req = req.WithContext(session.WithUser(req.Context(), user))
	req = withURLParam(req, "messageID", messageID)
	rec := httptest.NewRecorder()
	s.handleDeleteMessage(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestHandleDeleteMessage_SeenMessageBecomesPlaceholder implements FR1.15's
// placeholder rule: once the recipient has seen a message, deleting it
// keeps the row but wipes its content, and it's labelled as deleted
// wherever it surfaces (room preview, a reply's quote).
func TestHandleDeleteMessage_SeenMessageBecomesPlaceholder(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	sender, recipient, roomID, msg := deleteTestRoom(t, s, "delete-seen")

	if err := s.Store.MarkReceipts(ctx, roomID, recipient.ID, []string{msg.ID}, true); err != nil {
		t.Fatalf("mark seen: %v", err)
	}
	if err := s.Store.AddReaction(ctx, msg.ID, recipient.ID, "👍"); err != nil {
		t.Fatalf("add reaction: %v", err)
	}
	reply, err := s.Store.CreateTextMessage(ctx, roomID, recipient.ID, "what plans?", &msg.ID, false)
	if err != nil {
		t.Fatalf("create reply: %v", err)
	}

	deleteMessageAs(t, s, sender, msg.ID)

	placeholder, err := s.Store.GetMessage(ctx, msg.ID)
	if err != nil {
		t.Fatalf("expected the message to remain as a placeholder, got err=%v", err)
	}
	if placeholder.DeletedAt == nil {
		t.Fatal("expected deletedAt to be set")
	}
	if placeholder.Body != nil {
		t.Fatalf("expected the body to be wiped, got %q", *placeholder.Body)
	}

	messages := []models.Message{placeholder}
	if err := s.Store.AttachReactions(ctx, sender.ID, messages); err != nil {
		t.Fatalf("attach reactions: %v", err)
	}
	if len(messages[0].Reactions) != 0 {
		t.Fatalf("expected reactions to be removed, got %v", messages[0].Reactions)
	}

	replies := []models.Message{reply}
	if err := s.Store.AttachReplyPreviews(ctx, replies); err != nil {
		t.Fatalf("attach reply previews: %v", err)
	}
	if replies[0].ReplyTo == nil || replies[0].ReplyTo.Kind != models.MessageKindDeleted || replies[0].ReplyTo.Body != nil {
		t.Fatalf("expected the reply to quote a deleted message with no body, got %+v", replies[0].ReplyTo)
	}

	// Deleting the reply too leaves the placeholder as the room's latest message.
	if err := s.Store.DeleteMessage(ctx, reply.ID); err != nil {
		t.Fatalf("delete reply: %v", err)
	}
	rooms, err := s.Store.ListRoomsForUser(ctx, recipient.ID)
	if err != nil {
		t.Fatalf("list rooms: %v", err)
	}
	for _, room := range rooms {
		if room.ID != roomID {
			continue
		}
		if room.LastMessageKind == nil || *room.LastMessageKind != models.MessageKindDeleted || room.LastMessageBody != nil {
			t.Fatalf("expected the room preview to show a deleted message, got kind=%v body=%v", room.LastMessageKind, room.LastMessageBody)
		}
	}

	// Deleting it again is a no-op, not an error.
	deleteMessageAs(t, s, sender, msg.ID)
}

// TestHandleDeleteMessage_UnseenMessageIsRemovedEntirely: delivered but not
// yet seen still means a full delete, as before FR1.15's placeholder rule.
func TestHandleDeleteMessage_UnseenMessageIsRemovedEntirely(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	sender, recipient, roomID, msg := deleteTestRoom(t, s, "delete-unseen")

	if err := s.Store.MarkReceipts(ctx, roomID, recipient.ID, []string{msg.ID}, false); err != nil {
		t.Fatalf("mark delivered: %v", err)
	}

	deleteMessageAs(t, s, sender, msg.ID)

	if _, err := s.Store.GetMessage(ctx, msg.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("expected message to be gone, got err=%v", err)
	}
}

// TestDeletedPlaceholder_CannotBeActedOn: reacting to, editing, forwarding
// or replying to a placeholder all treat it as gone.
func TestDeletedPlaceholder_CannotBeActedOn(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	sender, recipient, roomID, msg := deleteTestRoom(t, s, "delete-act")

	if err := s.Store.MarkReceipts(ctx, roomID, recipient.ID, []string{msg.ID}, true); err != nil {
		t.Fatalf("mark seen: %v", err)
	}
	deleteMessageAs(t, s, sender, msg.ID)

	req := httptest.NewRequest(http.MethodPut, "/api/messages/"+msg.ID+"/reactions/👍", nil)
	req = req.WithContext(session.WithUser(req.Context(), recipient))
	rctx := chi.NewRouteContext()
	rctx.URLParams.Add("messageID", msg.ID)
	rctx.URLParams.Add("emoji", "👍")
	req = req.WithContext(context.WithValue(req.Context(), chi.RouteCtxKey, rctx))
	rec := httptest.NewRecorder()
	s.handleAddReaction(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("react: expected 404, got %d: %s", rec.Code, rec.Body.String())
	}

	if _, err := s.Store.EditMessageBody(ctx, msg.ID, "rewritten"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("edit: expected ErrNotFound, got %v", err)
	}

	if _, err := s.liveMessage(ctx, msg.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("forward/reply lookup: expected ErrNotFound, got %v", err)
	}
}

// TestHandleDeleteMedia_SeenPhotoBecomesPlaceholder: FR2.5 + FR1.15 — the
// file and media record are removed either way, but a photo someone
// already saw leaves its message behind as a placeholder instead of the
// migration 0002 cascade removing it.
func TestHandleDeleteMedia_SeenPhotoBecomesPlaceholder(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	sender, recipient, roomID, _ := deleteTestRoom(t, s, "delete-media-seen")

	objectKey := fmt.Sprintf("test/delete-seen-%d.jpg", time.Now().UnixNano())
	content := []byte{1, 2, 3}
	if err := s.Media.Put(ctx, objectKey, bytes.NewReader(content), int64(len(content)), "image/jpeg"); err != nil {
		t.Fatalf("put object: %v", err)
	}
	mediaObj, err := s.Store.CreateMediaObject(ctx, s.Media.Bucket(), objectKey, "image/jpeg", int64(len(content)), sender.ID, nil, nil, nil)
	if err != nil {
		t.Fatalf("create media object: %v", err)
	}
	msg, err := s.Store.CreateMediaMessage(ctx, roomID, sender.ID, "image", mediaObj.ID, nil, nil, false)
	if err != nil {
		t.Fatalf("create media message: %v", err)
	}
	if err := s.Store.MarkReceipts(ctx, roomID, recipient.ID, []string{msg.ID}, true); err != nil {
		t.Fatalf("mark seen: %v", err)
	}

	req := httptest.NewRequest(http.MethodDelete, "/api/media/"+mediaObj.ID, nil)
	req = req.WithContext(session.WithUser(req.Context(), sender))
	req = withURLParam(req, "mediaID", mediaObj.ID)
	rec := httptest.NewRecorder()
	s.handleDeleteMedia(rec, req)
	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}

	if _, err := s.Store.GetMediaObject(ctx, mediaObj.ID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("expected the media record to be gone, got err=%v", err)
	}
	placeholder, err := s.Store.GetMessage(ctx, msg.ID)
	if err != nil {
		t.Fatalf("expected the message to remain as a placeholder, got err=%v", err)
	}
	if placeholder.DeletedAt == nil || placeholder.MediaID != nil {
		t.Fatalf("expected a placeholder with no media, got deletedAt=%v mediaId=%v", placeholder.DeletedAt, placeholder.MediaID)
	}
}
