package api

import (
	"context"
	"log/slog"
	"time"

	"roost/server/internal/ws"
)

// CallRingTimeout is how long a call may ring with nobody answering before
// the server itself marks it missed (FR4.8). A little longer than the app's
// own 30-second ring timeout (app/lib/features/call/call_screen.dart's
// ringTimeout), which normally ends the call first. This is the backstop for
// when the caller's app can't: closed, offline, or off the call screen.
const CallRingTimeout = 45 * time.Second

// callExpiryInterval is how often RunCallExpiry checks for such calls.
const callExpiryInterval = 10 * time.Second

// RunCallExpiry expires unanswered calls every callExpiryInterval until ctx
// is done.
func (s *Server) RunCallExpiry(ctx context.Context) {
	ticker := time.NewTicker(callExpiryInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.ExpireUnansweredCalls(ctx, CallRingTimeout)
		}
	}
}

// ExpireUnansweredCalls marks every call that has rung for longer than
// ringFor without an answer as missed, and tells each call's room, so the
// call message stops reading "Ringing…" and any still-ringing phone (e.g. a
// native CallKit ring) stops. Failures are logged; the next run retries.
func (s *Server) ExpireUnansweredCalls(ctx context.Context, ringFor time.Duration) {
	expired, err := s.Store.ExpireUnansweredCalls(ctx, ringFor)
	if err != nil {
		slog.Error("calls: expire unanswered calls failed", "error", err)
		return
	}
	for _, msg := range expired {
		memberIDs, err := s.Store.ListRoomMemberIDs(ctx, msg.RoomID)
		if err != nil {
			slog.Error("calls: list room members failed", "room", msg.RoomID, "error", err)
			continue
		}
		s.Hub.SendToUsers(memberIDs, ws.Event{Type: "message.updated", Payload: msg})
	}
}
