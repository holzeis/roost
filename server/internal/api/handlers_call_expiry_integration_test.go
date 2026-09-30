//go:build integration

package api

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"roost/server/internal/models"
	"roost/server/internal/ws"
)

// recordingConn captures what the hub sends to one user.
type recordingConn struct {
	mu     sync.Mutex
	events []ws.Event
}

func (c *recordingConn) Send(ev ws.Event) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.events = append(c.events, ev)
	return nil
}

func (c *recordingConn) all() []ws.Event {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]ws.Event(nil), c.events...)
}

// TestExpireUnansweredCalls implements FR4.8's backstop: a call that rang
// out with nobody answering becomes "missed" server-side and the room is
// told, even when the caller's app never ends it. Calls still within the
// ring window, answered calls and already-finished calls are left alone.
func TestExpireUnansweredCalls(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	caller, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("expiry-caller-%d@github", run), "Caller")
	if err != nil {
		t.Fatalf("create caller: %v", err)
	}
	callee, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("expiry-callee-%d@github", run), "Callee")
	if err != nil {
		t.Fatalf("create callee: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, caller.ID, nil, false, []string{caller.ID, callee.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	calleeConn := &recordingConn{}
	s.Hub.Register(callee.ID, calleeConn)

	startCall := func() models.Message {
		t.Helper()
		msg, err := s.Store.CreateCall(ctx, room.ID, caller.ID)
		if err != nil {
			t.Fatalf("create call: %v", err)
		}
		return msg
	}
	statusOf := func(msg models.Message) models.CallStatus {
		t.Helper()
		call, err := s.Store.GetCall(ctx, msg.Call.ID)
		if err != nil {
			t.Fatalf("get call: %v", err)
		}
		return call.Status
	}

	unanswered := startCall()
	answered := startCall()
	if err := s.Store.JoinCall(ctx, answered.Call.ID, callee.ID); err != nil {
		t.Fatalf("join call: %v", err)
	}
	declined := startCall()
	if _, err := s.Store.DeclineCall(ctx, declined.Call.ID); err != nil {
		t.Fatalf("decline call: %v", err)
	}

	// Still within the ring window: nothing changes.
	s.ExpireUnansweredCalls(ctx, time.Hour)
	if got := statusOf(unanswered); got != models.CallStatusRinging {
		t.Fatalf("a call still ringing within the window should stay ringing, got %q", got)
	}

	// Past the window (ringFor 0): only the unanswered call expires.
	s.ExpireUnansweredCalls(ctx, 0)
	if got := statusOf(unanswered); got != models.CallStatusMissed {
		t.Fatalf("unanswered call: expected missed, got %q", got)
	}
	if got := statusOf(answered); got != models.CallStatusRinging {
		t.Fatalf("answered call must be left to its participants, got %q", got)
	}
	if got := statusOf(declined); got != models.CallStatusDeclined {
		t.Fatalf("declined call must stay declined, got %q", got)
	}

	var updated []models.Message
	for _, ev := range calleeConn.all() {
		if msg, ok := ev.Payload.(models.Message); ok && ev.Type == "message.updated" {
			updated = append(updated, msg)
		}
	}
	if len(updated) != 1 || updated[0].ID != unanswered.ID || updated[0].Call == nil ||
		updated[0].Call.Status != models.CallStatusMissed {
		t.Fatalf("expected one message.updated with the missed call, got %+v", updated)
	}

	// Running again finds nothing new to expire or announce.
	s.ExpireUnansweredCalls(ctx, 0)
	if n := len(calleeConn.all()); n != 1 {
		t.Fatalf("expected no further events, got %d total", n)
	}
}
