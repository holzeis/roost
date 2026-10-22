//go:build integration

package api

import (
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

func setRoomAvatar(t *testing.T, s *Server, user models.User, roomID string) *httptest.ResponseRecorder {
	t.Helper()
	body, contentType := multipartAvatarBody(t, "group.jpg", []byte("not a real jpeg, just test bytes"))
	req := httptest.NewRequest(http.MethodPost, "/api/rooms/"+roomID+"/avatar", body)
	req.Header.Set("Content-Type", contentType)
	req = req.WithContext(session.WithUser(req.Context(), user))
	req = withURLParam(req, "roomID", roomID)
	rec := httptest.NewRecorder()
	s.handleSetRoomAvatar(rec, req)
	return rec
}

// TestHandleSetRoomAvatar_AnyMemberCanSetAndEveryoneIsTold covers the whole
// feature: a plain member (not the creator) changes the group's picture, it
// is stored on the room and shows up in the room list and room lookup, and
// every member — the changer included — gets a live room.updated.
func TestHandleSetRoomAvatar_AnyMemberCanSetAndEveryoneIsTold(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	creator, _ := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("ra-creator-%d@github", run), "Creator")
	member, _ := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("ra-member-%d@github", run), "Member")
	name := "Family"
	room, err := s.Store.CreateRoom(ctx, creator.ID, &name, true, []string{member.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	creatorConn, memberConn := &recordingWSConn{}, &recordingWSConn{}
	s.Hub.Register(creator.ID, creatorConn)
	s.Hub.Register(member.ID, memberConn)

	rec := setRoomAvatar(t, s, member, room.ID)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var updated models.Room
	if err := json.Unmarshal(rec.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if updated.AvatarMediaID == nil {
		t.Fatal("expected avatarMediaId on the response")
	}
	if updated.Name == nil || *updated.Name != "Family" || len(updated.Members) != 2 {
		t.Fatalf("name and members should be untouched, got %+v", updated)
	}

	got, err := s.Store.GetRoom(ctx, room.ID)
	if err != nil || got.AvatarMediaID == nil || *got.AvatarMediaID != *updated.AvatarMediaID {
		t.Fatalf("GetRoom should return the new picture, got %+v (%v)", got, err)
	}
	listed, err := s.Store.ListRoomsForUser(ctx, creator.ID)
	if err != nil {
		t.Fatalf("list rooms: %v", err)
	}
	var found bool
	for _, r := range listed {
		if r.ID == room.ID {
			found = true
			if r.AvatarMediaID == nil || *r.AvatarMediaID != *updated.AvatarMediaID {
				t.Fatalf("the room list should carry the picture, got %v", r.AvatarMediaID)
			}
		}
	}
	if !found {
		t.Fatal("room missing from the creator's list")
	}

	for who, conn := range map[string]*recordingWSConn{"creator": creatorConn, "member": memberConn} {
		events := conn.eventsSnapshot()
		if len(events) != 1 || events[0].Type != "room.updated" {
			t.Fatalf("%s should get exactly one room.updated, got %+v", who, events)
		}
	}
}

func TestHandleSetRoomAvatar_NonMemberIsRefusedAndNothingChanges(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	owner, _ := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("ra-owner-%d@github", run), "Owner")
	outsider, _ := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("ra-outsider-%d@github", run), "Outsider")
	room, err := s.Store.CreateRoom(ctx, owner.ID, nil, true, nil)
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	if rec := setRoomAvatar(t, s, outsider, room.ID); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d: %s", rec.Code, rec.Body.String())
	}
	if got, _ := s.Store.GetRoom(ctx, room.ID); got.AvatarMediaID != nil {
		t.Fatalf("a refused upload must not change the room, got %v", got.AvatarMediaID)
	}
}

func TestHandleSetRoomAvatar_DirectRoomHasNoPicture(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	a, _ := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("ra-a-%d@github", run), "A")
	b, _ := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("ra-b-%d@github", run), "B")
	room, err := s.Store.CreateRoom(ctx, a.ID, nil, false, []string{b.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	if rec := setRoomAvatar(t, s, a, room.ID); rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400 for a 1:1 room, got %d: %s", rec.Code, rec.Body.String())
	}
}
