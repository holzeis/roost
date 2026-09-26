//go:build integration

package api

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

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
