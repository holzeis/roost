//go:build integration

package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"roost/server/internal/models"
	"roost/server/internal/session"
	"roost/server/internal/ws"
)

// TestLocationShares_OneLiveSharePerPersonPerRoom: starting a new share ends
// the sender's earlier live share in that room (one the app lost track of,
// e.g. after a reinstall, would otherwise stay "live" with a frozen
// position), and the room is told. Other rooms and other people's shares
// are untouched. The sender's active shares are listable for the app to
// resume after a restart.
func TestLocationShares_OneLiveSharePerPersonPerRoom(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	me, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("share-me-%d@github", run), "Me")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	other, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("share-other-%d@github", run), "Other")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, me.ID, nil, false, []string{me.ID, other.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	otherRoom, err := s.Store.CreateRoom(ctx, me.ID, nil, true, []string{me.ID, other.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	otherConn := &recordingConn{}
	s.Hub.Register(other.ID, otherConn)

	share := func(user models.User, roomID string) models.Message {
		t.Helper()
		body, _ := json.Marshal(map[string]any{"lat": 48.2, "lng": 16.37, "ttlSeconds": 3600})
		req := httptest.NewRequest(http.MethodPost, "/api/rooms/"+roomID+"/location", bytes.NewReader(body))
		req = req.WithContext(session.WithUser(req.Context(), user))
		req = withURLParam(req, "roomID", roomID)
		rec := httptest.NewRecorder()
		s.handleShareLocation(rec, req)
		if rec.Code != http.StatusCreated {
			t.Fatalf("share: expected 201, got %d: %s", rec.Code, rec.Body.String())
		}
		var msg models.Message
		if err := json.Unmarshal(rec.Body.Bytes(), &msg); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return msg
	}
	active := func() []string {
		t.Helper()
		req := httptest.NewRequest(http.MethodGet, "/api/me/location-shares", nil)
		req = req.WithContext(session.WithUser(req.Context(), me))
		rec := httptest.NewRecorder()
		s.handleListMyLocationShares(rec, req)
		if rec.Code != http.StatusOK {
			t.Fatalf("list: expected 200, got %d: %s", rec.Code, rec.Body.String())
		}
		var msgs []models.Message
		if err := json.Unmarshal(rec.Body.Bytes(), &msgs); err != nil {
			t.Fatalf("decode: %v", err)
		}
		ids := []string{}
		for _, m := range msgs {
			if m.Location == nil {
				t.Fatalf("listed share %s has no location attached", m.ID)
			}
			ids = append(ids, m.ID)
		}
		return ids
	}
	ended := func(id string) bool {
		t.Helper()
		l, err := s.Store.GetLocationShare(ctx, id)
		if err != nil {
			t.Fatalf("get share: %v", err)
		}
		return l.EndedAt != nil
	}

	first := share(me, room.ID)
	elsewhere := share(me, otherRoom.ID)
	theirs := share(other, room.ID)
	if got := active(); len(got) != 2 {
		t.Fatalf("expected my 2 live shares, got %v", got)
	}

	second := share(me, room.ID)
	if !ended(first.ID) {
		t.Fatal("starting a second share in the same room must end the first")
	}
	if ended(elsewhere.ID) || ended(theirs.ID) || ended(second.ID) {
		t.Fatal("only my earlier share in that room may end")
	}
	var announced bool
	for _, ev := range otherConn.all() {
		if msg, ok := ev.Payload.(models.Message); ok && ev.Type == "message.updated" && msg.ID == first.ID &&
			msg.Location != nil && msg.Location.EndedAt != nil {
			announced = true
		}
	}
	if !announced {
		t.Fatal("the room should be told the earlier share ended")
	}
	if got := active(); len(got) != 2 || got[0] != elsewhere.ID || got[1] != second.ID {
		t.Fatalf("expected [elsewhere, second] live, got %v", got)
	}

	// A deleted share message is no longer live.
	if err := s.Store.DeleteMessage(ctx, second.ID); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if got := active(); len(got) != 1 || got[0] != elsewhere.ID {
		t.Fatalf("expected only [elsewhere] live, got %v", got)
	}
}
