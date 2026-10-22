//go:build integration

package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"roost/server/internal/auth"
	"roost/server/internal/models"
	"roost/server/internal/session"
	"roost/server/internal/ws"
)

func postAlert(t *testing.T, s *Server, bot models.User, payload string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(http.MethodPost, "/bot/messages", strings.NewReader(payload))
	req = req.WithContext(session.WithUser(req.Context(), bot))
	rec := httptest.NewRecorder()
	s.handleBotMessage(rec, req)
	return rec
}

// TestHandleBotMessage_PostsToSharedAlertsRoom covers the whole alert path:
// the room is created once, every user (including one who joined after the
// first alert) becomes a member, and the message is sent by the bot.
func TestHandleBotMessage_PostsToSharedAlertsRoom(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	bot, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("tag:test-alerts-%d", run), "Alerts")
	if err != nil {
		t.Fatalf("create bot: %v", err)
	}
	early, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alerts-early-%d@github", run), "Early")
	if err != nil {
		t.Fatalf("create early user: %v", err)
	}

	rec := postAlert(t, s, bot, `{"body":"🚨 HighCPU"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var first models.Message
	if err := json.Unmarshal(rec.Body.Bytes(), &first); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if first.SenderID != bot.ID {
		t.Fatalf("expected sender %q, got %q", bot.ID, first.SenderID)
	}
	if ok, _ := s.Store.IsRoomMember(ctx, first.RoomID, early.ID); !ok {
		t.Fatal("existing user should be a member of the alerts room")
	}
	room, err := s.Store.GetRoom(ctx, first.RoomID)
	if err != nil || room.Name == nil || *room.Name != "Alerts" || !room.IsGroup {
		t.Fatalf("expected a group room named Alerts, got %+v (%v)", room, err)
	}

	late, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("alerts-late-%d@github", run), "Late")
	if err != nil {
		t.Fatalf("create late user: %v", err)
	}
	rec = postAlert(t, s, bot, `{"body":"✅ Resolved Alert: HighCPU"}`)
	var second models.Message
	if err := json.Unmarshal(rec.Body.Bytes(), &second); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if second.RoomID != first.RoomID {
		t.Fatalf("expected the same alerts room, got %q then %q", first.RoomID, second.RoomID)
	}
	if ok, _ := s.Store.IsRoomMember(ctx, first.RoomID, late.ID); !ok {
		t.Fatal("a user who joined after the first alert should be added on the next one")
	}
}

func TestHandleBotMessage_RejectsEmptyBody(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	bot, err := s.Store.GetOrCreateUserByTailscaleID(context.Background(), fmt.Sprintf("tag:test-alerts-empty-%d", time.Now().UnixNano()), "Alerts")
	if err != nil {
		t.Fatalf("create bot: %v", err)
	}
	for _, payload := range []string{`{"body":""}`, `{"body":"   "}`, `not json`} {
		if rec := postAlert(t, s, bot, payload); rec.Code != http.StatusBadRequest {
			t.Errorf("payload %q: expected 400, got %d", payload, rec.Code)
		}
	}
}

func TestEnsureAlertsRoom_ConcurrentFirstAlertsCreateOneRoom(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	bot, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("tag:test-alerts-race-%d", time.Now().UnixNano()), "Alerts")
	if err != nil {
		t.Fatalf("create bot: %v", err)
	}

	ids := make(chan string, 8)
	for i := 0; i < cap(ids); i++ {
		go func() {
			room, err := s.Store.EnsureAlertsRoom(ctx, bot.ID)
			if err != nil {
				ids <- "error: " + err.Error()
				return
			}
			ids <- room.ID
		}()
	}
	first := <-ids
	for i := 1; i < cap(ids); i++ {
		if got := <-ids; got != first {
			t.Fatalf("concurrent calls returned different rooms: %q vs %q", first, got)
		}
	}
}

func postBotAvatar(t *testing.T, s *Server, bot models.User, content string) *httptest.ResponseRecorder {
	t.Helper()
	body, contentType := multipartAvatarBody(t, "avatar.jpg", []byte(content))
	req := httptest.NewRequest(http.MethodPost, "/bot/avatar", body)
	req.Header.Set("Content-Type", contentType)
	req = req.WithContext(session.WithUser(req.Context(), bot))
	rec := httptest.NewRecorder()
	s.handleBotAvatar(rec, req)
	return rec
}

// TestHandleBotAvatar_IdenticalUploadIsANoOpButANewImageReplaces covers the
// bridge offering its picture on every start: the same image must not pile
// up a media object per restart, while a changed image must take effect.
func TestHandleBotAvatar_IdenticalUploadIsANoOpButANewImageReplaces(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	bot, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("tag:test-alerts-avatar-%d", time.Now().UnixNano()), "Homelab")
	if err != nil {
		t.Fatalf("create bot: %v", err)
	}

	rec := postBotAvatar(t, s, bot, "first image bytes")
	if rec.Code != http.StatusOK {
		t.Fatalf("first upload: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var first models.User
	if err := json.Unmarshal(rec.Body.Bytes(), &first); err != nil || first.AvatarMediaID == nil {
		t.Fatalf("expected an avatar to be set, got %+v (%v)", first, err)
	}
	if first.DisplayName != "Homelab" {
		t.Fatalf("display name should be untouched, got %q", first.DisplayName)
	}

	// The next request re-loads the user (resolveUser), now with an avatar.
	reloaded, _ := s.Store.GetUser(ctx, bot.ID)
	if rec := postBotAvatar(t, s, reloaded, "first image bytes"); rec.Code != http.StatusNoContent {
		t.Fatalf("identical upload: expected 204, got %d", rec.Code)
	}
	if after, _ := s.Store.GetUser(ctx, bot.ID); after.AvatarMediaID == nil || *after.AvatarMediaID != *first.AvatarMediaID {
		t.Fatalf("avatar should be unchanged, was %v now %v", first.AvatarMediaID, after.AvatarMediaID)
	}

	rec = postBotAvatar(t, s, reloaded, "a different, longer image")
	if rec.Code != http.StatusOK {
		t.Fatalf("new image: expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var second models.User
	if err := json.Unmarshal(rec.Body.Bytes(), &second); err != nil || second.AvatarMediaID == nil || *second.AvatarMediaID == *first.AvatarMediaID {
		t.Fatalf("expected a replaced avatar, got %+v (%v)", second, err)
	}
}

// TestResolveUser_SyncsTheAlertIdentitysName covers renaming: the alert
// user's row already exists under its old name, and must follow the name
// the code now gives that identity, keeping its picture.
func TestResolveUser_SyncsTheAlertIdentitysName(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	login := fmt.Sprintf("tag:test-alerts-rename-%d", time.Now().UnixNano())
	old, err := s.Store.GetOrCreateUserByTailscaleID(ctx, login, "Alerts")
	if err != nil {
		t.Fatalf("create bot: %v", err)
	}
	media, err := s.Store.CreateMediaObject(ctx, s.Media.Bucket(), fmt.Sprintf("avatars/%s.jpg", login), "image/jpeg", 3, old.ID, nil, nil, nil)
	if err != nil {
		t.Fatalf("create media: %v", err)
	}
	if _, err := s.Store.UpdateUserProfile(ctx, old.ID, "Alerts", &media.ID); err != nil {
		t.Fatalf("set avatar: %v", err)
	}

	var got models.User
	handler := s.resolveUser(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, _ = session.UserFromContext(r.Context())
	}))
	req := httptest.NewRequest(http.MethodPost, "/bot/messages", nil)
	req = req.WithContext(auth.WithIdentity(req.Context(), auth.Identity{LoginName: login, DisplayName: "Homelab", Bot: true}))
	handler.ServeHTTP(httptest.NewRecorder(), req)

	if got.DisplayName != "Homelab" {
		t.Fatalf("expected the user to be renamed to Homelab, got %q", got.DisplayName)
	}
	if got.AvatarMediaID == nil || *got.AvatarMediaID != media.ID {
		t.Fatalf("avatar should be kept across the rename, got %v", got.AvatarMediaID)
	}
}
