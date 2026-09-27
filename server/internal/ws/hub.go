// Package ws implements the realtime fan-out for chat events: a client opens
// one WebSocket connection per session, and the Hub delivers events (new
// messages, reactions, call invites, presence) to every connection belonging
// to users in the relevant room.
package ws

import (
	"log/slog"
	"sync"
)

type Event struct {
	Type    string `json:"type"`
	Payload any    `json:"payload"`
}

// Conn is the minimal surface Hub needs from a live connection; the real
// implementation wraps a *websocket.Conn (see server.go), kept behind an
// interface so the hub's fan-out logic is unit-testable without sockets.
type Conn interface {
	Send(Event) error
}

type Hub struct {
	mu sync.RWMutex
	// conns maps userID -> the set of that user's live connections (a user
	// may have more than one device connected at once).
	conns map[string]map[Conn]struct{}
}

func NewHub() *Hub {
	return &Hub{conns: make(map[string]map[Conn]struct{})}
}

func (h *Hub) Register(userID string, conn Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.conns[userID] == nil {
		h.conns[userID] = make(map[Conn]struct{})
	}
	h.conns[userID][conn] = struct{}{}
}

func (h *Hub) Unregister(userID string, conn Conn) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.conns[userID], conn)
	if len(h.conns[userID]) == 0 {
		delete(h.conns, userID)
	}
}

// IsOnline reports whether userID has at least one live connection — the
// basis for the "deliver over the socket, else fall back to push" call flow
// described in the architecture overview.
func (h *Hub) IsOnline(userID string) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.conns[userID]) > 0
}

// SendToUser delivers ev to every live connection for userID and reports
// whether it actually reached at least one of them — the basis callers use
// to decide whether a push fallback is needed (see deliverToRoom/
// deliverMessageEvent in the api package). A registered connection whose
// write fails (the socket is dead but socket.go's heartbeat hasn't pruned it
// yet) must count as unreachable here, not "online" — that gap used to skip
// the push fallback for exactly the case it exists for: an app killed
// outright, whose connection lingers registered until the next failed
// write/ping.
func (h *Hub) SendToUser(userID string, ev Event) bool {
	h.mu.RLock()
	conns := make([]Conn, 0, len(h.conns[userID]))
	for c := range h.conns[userID] {
		conns = append(conns, c)
	}
	h.mu.RUnlock()

	delivered := false
	for _, c := range conns {
		if err := c.Send(ev); err != nil {
			slog.Warn("ws: failed to deliver event", "error", err, "type", ev.Type)
			continue
		}
		delivered = true
	}
	return delivered
}

// SendToUsers delivers ev to each of userIDs, e.g. every member of a room.
func (h *Hub) SendToUsers(userIDs []string, ev Event) {
	for _, id := range userIDs {
		h.SendToUser(id, ev)
	}
}
