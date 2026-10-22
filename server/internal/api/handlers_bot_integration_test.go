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
