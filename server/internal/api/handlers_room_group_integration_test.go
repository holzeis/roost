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

// roomCall invokes handler as user against /api/rooms/{roomID}.
func roomCall(t *testing.T, handler http.HandlerFunc, user models.User, method, roomID, body string) *httptest.ResponseRecorder {
	t.Helper()
	req := httptest.NewRequest(method, "/api/rooms/"+roomID, strings.NewReader(body))
	req = req.WithContext(session.WithUser(req.Context(), user))
	req = withURLParam(req, "roomID", roomID)
	rec := httptest.NewRecorder()
	handler(rec, req)
	return rec
}

type groupFixture struct {
	s                     *Server
	a, b, c, outsider     models.User
	room                  models.Room
	aConn, bConn, outConn *recordingWSConn
	cConn                 *recordingWSConn
}

// newGroupFixture: a group "Family" of a (creator) and b; c is a known user
// not in it, and outsider is another.
func newGroupFixture(t *testing.T) groupFixture {
	t.Helper()
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()
	mk := func(n string) models.User {
		u, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("rg-%s-%d@github", n, run), n)
		if err != nil {
			t.Fatalf("create user: %v", err)
		}
		return u
	}
	f := groupFixture{s: s, a: mk("A"), b: mk("B"), c: mk("C"), outsider: mk("Out")}
	name := "Family"
	room, err := s.Store.CreateRoom(ctx, f.a.ID, &name, true, []string{f.b.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	f.room = room
	f.aConn, f.bConn, f.cConn, f.outConn = &recordingWSConn{}, &recordingWSConn{}, &recordingWSConn{}, &recordingWSConn{}
	s.Hub.Register(f.a.ID, f.aConn)
	s.Hub.Register(f.b.ID, f.bConn)
	s.Hub.Register(f.c.ID, f.cConn)
	s.Hub.Register(f.outsider.ID, f.outConn)
	return f
}

func eventTypes(c *recordingWSConn) []string {
	var out []string
	for _, e := range c.eventsSnapshot() {
		out = append(out, e.Type)
	}
	return out
}

func TestHandleRenameRoom(t *testing.T) {
	f := newGroupFixture(t)
	ctx := context.Background()

	rec := roomCall(t, f.s.handleRenameRoom, f.b, http.MethodPatch, f.room.ID, `{"name":"  Fam Jam  "}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("a plain member can rename: %d %s", rec.Code, rec.Body.String())
	}
	got, _ := f.s.Store.GetRoom(ctx, f.room.ID)
	if got.Name == nil || *got.Name != "Fam Jam" {
		t.Fatalf("name should be trimmed and stored, got %v", got.Name)
	}
	for who, c := range map[string]*recordingWSConn{"a": f.aConn, "b": f.bConn} {
		if ev := eventTypes(c); len(ev) != 1 || ev[0] != "room.updated" {
			t.Fatalf("%s should get room.updated, got %v", who, ev)
		}
	}
	if ev := eventTypes(f.outConn); len(ev) != 0 {
		t.Fatalf("a non-member must hear nothing, got %v", ev)
	}

	for _, bad := range []string{`{"name":""}`, `{"name":"   "}`, `{"name":"` + strings.Repeat("x", 101) + `"}`, `nope`} {
		if rec := roomCall(t, f.s.handleRenameRoom, f.a, http.MethodPatch, f.room.ID, bad); rec.Code != http.StatusBadRequest {
			t.Fatalf("%q should be 400, got %d", bad, rec.Code)
		}
	}
	if rec := roomCall(t, f.s.handleRenameRoom, f.outsider, http.MethodPatch, f.room.ID, `{"name":"Mine"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("a non-member gets 403, got %d", rec.Code)
	}
	direct, _ := f.s.Store.CreateRoom(ctx, f.a.ID, nil, false, []string{f.b.ID})
	if rec := roomCall(t, f.s.handleRenameRoom, f.a, http.MethodPatch, direct.ID, `{"name":"Mine"}`); rec.Code != http.StatusBadRequest {
		t.Fatalf("a 1:1 room can't be named, got %d", rec.Code)
	}
	if got, _ := f.s.Store.GetRoom(ctx, f.room.ID); *got.Name != "Fam Jam" {
		t.Fatal("refused requests must not change the name")
	}
}

func TestHandleAddRoomMembers(t *testing.T) {
	f := newGroupFixture(t)
	ctx := context.Background()

	body := fmt.Sprintf(`{"userIds":["%s","%s","%s"]}`, f.c.ID, f.c.ID, f.a.ID) // duplicate + already a member
	rec := roomCall(t, f.s.handleAddRoomMembers, f.b, http.MethodPost, f.room.ID, body)
	if rec.Code != http.StatusOK {
		t.Fatalf("a plain member can add people: %d %s", rec.Code, rec.Body.String())
	}
	var updated models.Room
	_ = json.Unmarshal(rec.Body.Bytes(), &updated)
	if len(updated.Members) != 3 {
		t.Fatalf("expected a, b, c as members, got %v", updated.Members)
	}
	for who, c := range map[string]*recordingWSConn{"a": f.aConn, "b": f.bConn, "c (the newcomer)": f.cConn} {
		if ev := eventTypes(c); len(ev) != 1 || ev[0] != "room.updated" {
			t.Fatalf("%s should get room.updated, got %v", who, ev)
		}
	}
	rooms, _ := f.s.Store.ListRoomsForUser(ctx, f.c.ID)
	if len(rooms) != 1 || rooms[0].ID != f.room.ID {
		t.Fatalf("the newcomer should now see the group, got %+v", rooms)
	}

	cases := map[string]struct {
		user models.User
		body string
		want int
	}{
		"non-member":   {f.outsider, fmt.Sprintf(`{"userIds":["%s"]}`, f.outsider.ID), http.StatusForbidden},
		"empty list":   {f.a, `{"userIds":[]}`, http.StatusBadRequest},
		"not a uuid":   {f.a, `{"userIds":["x"]}`, http.StatusBadRequest},
		"unknown user": {f.a, `{"userIds":["00000000-0000-4000-8000-000000000000"]}`, http.StatusNotFound},
		"half unknown": {f.a, fmt.Sprintf(`{"userIds":["%s","00000000-0000-4000-8000-000000000000"]}`, f.outsider.ID), http.StatusNotFound},
	}
	for name, c := range cases {
		if rec := roomCall(t, f.s.handleAddRoomMembers, c.user, http.MethodPost, f.room.ID, c.body); rec.Code != c.want {
			t.Fatalf("%s: want %d, got %d", name, c.want, rec.Code)
		}
	}
	if in, _ := f.s.Store.IsRoomMember(ctx, f.room.ID, f.outsider.ID); in {
		t.Fatal("a partly invalid request must add nobody")
	}
	direct, _ := f.s.Store.CreateRoom(ctx, f.a.ID, nil, false, []string{f.b.ID})
	if rec := roomCall(t, f.s.handleAddRoomMembers, f.a, http.MethodPost, direct.ID, fmt.Sprintf(`{"userIds":["%s"]}`, f.c.ID)); rec.Code != http.StatusBadRequest {
		t.Fatalf("a 1:1 room can't grow, got %d", rec.Code)
	}
}

func TestHandleLeaveRoom(t *testing.T) {
	f := newGroupFixture(t)
	ctx := context.Background()

	// b has a live location share in the group; leaving ends it.
	share, err := f.s.Store.CreateLocationMessage(ctx, f.room.ID, f.b.ID, 1, 2, time.Hour)
	if err != nil {
		t.Fatalf("share: %v", err)
	}

	rec := roomCall(t, f.s.handleLeaveRoom, f.b, http.MethodDelete, f.room.ID, "")
	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
	if in, _ := f.s.Store.IsRoomMember(ctx, f.room.ID, f.b.ID); in {
		t.Fatal("b should be out")
	}
	if ls, _ := f.s.Store.GetLocationShare(ctx, share.ID); ls.EndedAt == nil {
		t.Fatal("the leaver's live location share should have ended")
	}
	if ev := eventTypes(f.bConn); fmt.Sprint(ev) != "[message.updated room.removed]" {
		t.Fatalf("the leaver should hear the share ending and room.removed, got %v", ev)
	}
	if ev := eventTypes(f.aConn); fmt.Sprint(ev) != "[message.updated room.updated]" {
		t.Fatalf("the rest should hear the share ending and room.updated, got %v", ev)
	}
	if rooms, _ := f.s.Store.ListRoomsForUser(ctx, f.b.ID); len(rooms) != 0 {
		t.Fatalf("the group should be gone from b's list, got %+v", rooms)
	}
	if rec := roomCall(t, f.s.handleLeaveRoom, f.b, http.MethodDelete, f.room.ID, ""); rec.Code != http.StatusForbidden {
		t.Fatalf("leaving twice is a 403, got %d", rec.Code)
	}

	// The last member leaving deletes the group.
	if rec := roomCall(t, f.s.handleLeaveRoom, f.a, http.MethodDelete, f.room.ID, ""); rec.Code != http.StatusNoContent {
		t.Fatalf("last member leaves: %d", rec.Code)
	}
	if _, err := f.s.Store.GetRoom(ctx, f.room.ID); err == nil {
		t.Fatal("an empty group should be deleted")
	}

	direct, _ := f.s.Store.CreateRoom(ctx, f.c.ID, nil, false, []string{f.outsider.ID})
	if rec := roomCall(t, f.s.handleLeaveRoom, f.c, http.MethodDelete, direct.ID, ""); rec.Code != http.StatusBadRequest {
		t.Fatalf("a 1:1 chat can't be left, got %d", rec.Code)
	}
}

func TestHandleLeaveRoom_AlertsGroupCannotBeLeft(t *testing.T) {
	f := newGroupFixture(t)
	ctx := context.Background()
	bot, _ := f.s.Store.GetOrCreateUserByTailscaleID(ctx, "tag:roost-alerts-test-"+fmt.Sprint(time.Now().UnixNano()), "Homelab")
	f.s.AlertTag = bot.TailscaleID
	alerts, err := f.s.Store.CreateRoom(ctx, bot.ID, nil, true, []string{f.a.ID})
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	if rec := roomCall(t, f.s.handleLeaveRoom, f.a, http.MethodDelete, alerts.ID, ""); rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", rec.Code)
	}
	if in, _ := f.s.Store.IsRoomMember(ctx, alerts.ID, f.a.ID); !in {
		t.Fatal("still a member")
	}
}

func TestHandleRoomMute(t *testing.T) {
	f := newGroupFixture(t)
	ctx := context.Background()

	decode := func(rec *httptest.ResponseRecorder) models.Room {
		var r models.Room
		_ = json.Unmarshal(rec.Body.Bytes(), &r)
		return r
	}

	rec := roomCall(t, f.s.handlePutRoomMute, f.a, http.MethodPut, f.room.ID, `{"duration":"8h"}`)
	if rec.Code != http.StatusOK {
		t.Fatalf("mute 8h: %d %s", rec.Code, rec.Body.String())
	}
	got := decode(rec)
	if !got.Muted || got.MutedUntil == nil {
		t.Fatalf("expected a timed mute, got %+v", got)
	}
	if d := time.Until(*got.MutedUntil); d < 7*time.Hour+55*time.Minute || d > 8*time.Hour {
		t.Fatalf("8h mute ends in %v", d)
	}
	rec = roomCall(t, f.s.handlePutRoomMute, f.a, http.MethodPut, f.room.ID, `{"duration":"1w"}`)
	if d := time.Until(*decode(rec).MutedUntil); d < 6*24*time.Hour+23*time.Hour {
		t.Fatalf("1w mute ends in %v", d)
	}
	rec = roomCall(t, f.s.handlePutRoomMute, f.a, http.MethodPut, f.room.ID, `{"duration":"always"}`)
	if got := decode(rec); !got.Muted || got.MutedUntil != nil {
		t.Fatalf("always has no end, got %+v", got)
	}

	// Per member: the mute is a's alone, and it shows in a's room list/lookup.
	if rooms, _ := f.s.Store.ListRoomsForUser(ctx, f.a.ID); !rooms[0].Muted {
		t.Fatal("a's list should say muted")
	}
	if rooms, _ := f.s.Store.ListRoomsForUser(ctx, f.b.ID); rooms[0].Muted {
		t.Fatal("b's list must not be muted")
	}
	if got := decode(roomCall(t, f.s.handleGetRoom, f.a, http.MethodGet, f.room.ID, "")); !got.Muted {
		t.Fatal("GET room should carry a's mute")
	}
	// ...and never leaks through the room.updated broadcast.
	roomCall(t, f.s.handleRenameRoom, f.b, http.MethodPatch, f.room.ID, `{"name":"X"}`)
	for _, e := range f.bConn.eventsSnapshot() {
		if e.Type == "room.updated" && e.Payload.(models.Room).Muted {
			t.Fatal("room.updated must not carry anyone's mute")
		}
	}

	rec = roomCall(t, f.s.handleDeleteRoomMute, f.a, http.MethodDelete, f.room.ID, "")
	if rec.Code != http.StatusOK || decode(rec).Muted {
		t.Fatalf("unmute: %d %s", rec.Code, rec.Body.String())
	}

	for _, bad := range []string{`{"duration":"2d"}`, `{}`, `x`} {
		if rec := roomCall(t, f.s.handlePutRoomMute, f.a, http.MethodPut, f.room.ID, bad); rec.Code != http.StatusBadRequest {
			t.Fatalf("%q should be 400, got %d", bad, rec.Code)
		}
	}
	if rec := roomCall(t, f.s.handlePutRoomMute, f.outsider, http.MethodPut, f.room.ID, `{"duration":"always"}`); rec.Code != http.StatusForbidden {
		t.Fatalf("non-member gets 403, got %d", rec.Code)
	}
}

// TestMutedMemberGetsNoMessagePush: a muted member who is offline gets no
// push for a new message, an unmuted one does, and a lapsed timed mute no
// longer counts.
func TestMutedMemberGetsNoMessagePush(t *testing.T) {
	f := newGroupFixture(t)
	ctx := context.Background()
	pushSender := &fakePushSender{}
	f.s.Push = pushSender
	// Nobody is online: take everyone off the hub.
	f.s.Hub = ws.NewHub()

	// a sends; b (muted) and c (timed mute already lapsed) are members too.
	if _, err := f.s.Store.AddRoomMembers(ctx, f.room.ID, []string{f.c.ID}); err != nil {
		t.Fatal(err)
	}
	for _, u := range []models.User{f.b, f.c} {
		if _, err := f.s.Store.UpsertDevice(ctx, u.ID, "android", "fcm-"+u.ID, "fcm", nil); err != nil {
			t.Fatal(err)
		}
	}
	if err := f.s.Store.SetRoomMute(ctx, f.room.ID, f.b.ID, true, nil); err != nil {
		t.Fatal(err)
	}
	past := time.Now().Add(-time.Minute)
	if err := f.s.Store.SetRoomMute(ctx, f.room.ID, f.c.ID, false, &past); err != nil {
		t.Fatal(err)
	}

	if rec := roomCall(t, f.s.handleCreateMessage, f.a, http.MethodPost, f.room.ID, `{"body":"hi"}`); rec.Code != http.StatusCreated {
		t.Fatalf("send: %d %s", rec.Code, rec.Body.String())
	}
	calls := pushSender.messageCallsSnapshot()
	if len(calls) != 1 || calls[0].deviceToken != "fcm-"+f.c.ID {
		t.Fatalf("only c (mute lapsed) should be pushed, got %+v", calls)
	}
}
