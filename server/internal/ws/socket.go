package ws

import (
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

// Handler upgrades the connection, registers it with the hub for the
// caller's identity (resolved by auth.Middleware upstream), and reads until
// the client disconnects. Inbound messages beyond the initial upgrade are
// currently just discarded — clients send state changes over the REST API
// and receive fan-out over this socket; a client->server message protocol
// (e.g. typing indicators) can be layered in here later.
func Handler(hub *Hub) http.HandlerFunc {
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
			if _, _, err := conn.ReadMessage(); err != nil {
				return
			}
		}
	}
}
