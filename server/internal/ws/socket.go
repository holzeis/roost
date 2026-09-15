package ws

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"sync"

	"github.com/gorilla/websocket"

	"roost/server/internal/session"
)

var upgrader = websocket.Upgrader{
	// Origin checking is not meaningful here: every caller is already
	// authenticated by tailnet identity (see internal/auth), and the app is
	// never loaded cross-origin in a browser.
	CheckOrigin: func(r *http.Request) bool { return true },
}

// socketConn adapts a *websocket.Conn to the Hub's Conn interface, guarding
// writes with a mutex since gorilla's Conn is not safe for concurrent writers.
type socketConn struct {
	mu   sync.Mutex
	conn *websocket.Conn
}

func (s *socketConn) Send(ev Event) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.conn.WriteJSON(ev)
}

// MembershipChecker is the minimal store dependency Handler needs to
// authorize inbound typing signals (FR1.7) — kept as an interface (like
// Conn above) so the decision logic is unit-testable without a real
// Store/DB. *store.Store already implements this via its existing
// ListRoomMemberIDs method.
type MembershipChecker interface {
	ListRoomMemberIDs(ctx context.Context, roomID string) ([]string, error)
}

// Handler upgrades the connection, registers it with the hub for the
// caller's identity (resolved by auth.Middleware upstream), and reads until
// the client disconnects. Most state changes still go over the REST API,
// with fan-out over this socket — the one exception is the typing signal
// (FR1.7), which is ephemeral enough (no persistence, best-effort delivery)
// that round-tripping it through REST would be pure overhead; see
// handleTypingSignal.
func Handler(hub *Hub, membership MembershipChecker) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		user, ok := session.UserFromContext(r.Context())
		if !ok {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}

		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			slog.Warn("ws: upgrade failed", "error", err)
			return
		}
		defer conn.Close()

		sc := &socketConn{conn: conn}
		hub.Register(user.ID, sc)
		defer hub.Unregister(user.ID, sc)

		for {
			_, raw, err := conn.ReadMessage()
			if err != nil {
				return
			}
			if recipients, ev, ok := handleTypingSignal(r.Context(), membership, user.ID, raw); ok {
				hub.SendToUsers(recipients, ev)
			}
		}
	}
}

// handleTypingSignal decodes one inbound {"type": "typing.start"|"typing.stop",
// "payload": {"roomId": "..."}} frame from userID and, if it's valid and
// userID is actually a member of that room, returns the room's other
// members and the Event to broadcast to them. ok is false for anything that
// should be silently ignored: malformed JSON, an unrecognized type, a
// missing roomId, a membership lookup failure, or userID not being a member
// of the room it claims to be typing in (the authorization check — a client
// can't spoof a typing signal for a room it doesn't belong to).
func handleTypingSignal(ctx context.Context, membership MembershipChecker, userID string, raw []byte) (recipients []string, ev Event, ok bool) {
	var inbound struct {
		Type    string `json:"type"`
		Payload struct {
			RoomID string `json:"roomId"`
		} `json:"payload"`
	}
	if err := json.Unmarshal(raw, &inbound); err != nil {
		return nil, Event{}, false
	}

	var typing bool
	switch inbound.Type {
	case "typing.start":
		typing = true
	case "typing.stop":
		typing = false
	default:
		return nil, Event{}, false
	}
	if inbound.Payload.RoomID == "" {
		return nil, Event{}, false
	}

	memberIDs, err := membership.ListRoomMemberIDs(ctx, inbound.Payload.RoomID)
	if err != nil {
		return nil, Event{}, false
	}
	isMember := false
	others := make([]string, 0, len(memberIDs))
	for _, id := range memberIDs {
		if id == userID {
			isMember = true
			continue
		}
		others = append(others, id)
	}
	if !isMember {
		return nil, Event{}, false
	}

	ev = Event{Type: "typing", Payload: map[string]any{
		"roomId": inbound.Payload.RoomID,
		"userId": userID,
		"typing": typing,
	}}
	return others, ev, true
}
