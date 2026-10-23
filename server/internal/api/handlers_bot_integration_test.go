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

// TestHandleBotMessage_PostsToEveryGroupItWasAddedTo covers the whole alert
// path: the bot posts to each group it is a member of — and only those, no
// 1:1 chat and no group it wasn't invited to — as itself, and a member who
// muted a group gets no push for it.
func TestHandleBotMessage_PostsToEveryGroupItWasAddedTo(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	pushSender := &fakePushSender{}
	s.Push = pushSender
	ctx := context.Background()
	run := time.Now().UnixNano()

	mk := func(login, name string) models.User {
		u, err := s.Store.GetOrCreateUserByTailscaleID(ctx, login, name)
		if err != nil {
			t.Fatalf("create user: %v", err)
		}
		return u
	}
	bot := mk(fmt.Sprintf("tag:test-alerts-%d", run), "Homelab")
	alice := mk(fmt.Sprintf("alerts-alice-%d@github", run), "Alice")
	bob := mk(fmt.Sprintf("alerts-bob-%d@github", run), "Bob")
	name := "Alerts"
	invited, _ := s.Store.CreateRoom(ctx, alice.ID, &name, true, []string{bob.ID})
	if _, err := s.Store.AddRoomMembers(ctx, invited.ID, []string{bot.ID}); err != nil {
		t.Fatalf("add bot: %v", err)
	}
	other := "Other"
	notInvited, _ := s.Store.CreateRoom(ctx, alice.ID, &other, true, []string{bob.ID})
	direct, _ := s.Store.CreateRoom(ctx, alice.ID, nil, false, []string{bot.ID})

	for _, u := range []models.User{alice, bob} {
		if _, err := s.Store.UpsertDevice(ctx, u.ID, "android", "fcm-"+u.ID, "fcm", nil); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.Store.SetRoomMute(ctx, invited.ID, bob.ID, true, nil); err != nil {
		t.Fatal(err)
	}

	rec := postAlert(t, s, bot, `{"body":"🚨 HighCPU"}`)
	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if !strings.Contains(rec.Body.String(), `"groups":1`) {
		t.Fatalf("expected one group, got %s", rec.Body.String())
	}

	messages := func(roomID string) []models.Message {
		got, _ := s.Store.ListMessages(ctx, roomID, time.Now().Add(time.Minute), 10)
		return got
	}
	if got := messages(invited.ID); len(got) != 1 || got[0].SenderID != bot.ID || *got[0].Body != "🚨 HighCPU" {
		t.Fatalf("expected the alert from the bot, got %+v", got)
	}
	if got := messages(notInvited.ID); len(got) != 0 {
		t.Fatalf("a group the bot isn't in must get nothing, got %+v", got)
	}
	if got := messages(direct.ID); len(got) != 0 {
		t.Fatalf("a 1:1 chat must get nothing, got %+v", got)
	}
	calls := pushSender.messageCallsSnapshot()
	if len(calls) != 1 || calls[0].deviceToken != "fcm-"+alice.ID {
		t.Fatalf("only Alice (Bob muted it) should be pushed, got %+v", calls)
	}

	// A second group the bot is added to gets the next alert too.
	second, _ := s.Store.CreateRoom(ctx, bob.ID, &other, true, nil)
	_, _ = s.Store.AddRoomMembers(ctx, second.ID, []string{bot.ID})
	if rec := postAlert(t, s, bot, `{"body":"✅ Resolved"}`); !strings.Contains(rec.Body.String(), `"groups":2`) {
		t.Fatalf("expected two groups, got %s", rec.Body.String())
	}
}

// TestHandleBotMessage_NotInAnyGroupIsAConflict: with nowhere to post, the
// bridge must see a failure (so Alertmanager retries and it is noticed)
// rather than a silent success.
func TestHandleBotMessage_NotInAnyGroupIsAConflict(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	bot, _ := s.Store.GetOrCreateUserByTailscaleID(context.Background(), fmt.Sprintf("tag:test-alerts-none-%d", time.Now().UnixNano()), "Homelab")
	if rec := postAlert(t, s, bot, `{"body":"x"}`); rec.Code != http.StatusConflict {
		t.Fatalf("expected 409, got %d: %s", rec.Code, rec.Body.String())
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
