// Package api wires the REST endpoints and the /ws upgrade behind the
// tailnet-identity auth middleware, and is the composition root that maps a
// resolved Tailscale identity to a local user row for the rest of a request.
package api

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"

	"roost/server/internal/auth"
	"roost/server/internal/livekit"
	"roost/server/internal/store"
	"roost/server/internal/ws"
)

type Server struct {
	Store    *store.Store
	Hub      *ws.Hub
	LiveKit  *livekit.Minter
	Resolver auth.Resolver
}

func (s *Server) Router() http.Handler {
	r := chi.NewRouter()
	r.Use(middleware.RequestID)
	r.Use(middleware.RealIP)
	r.Use(middleware.Logger)
	r.Use(middleware.Recoverer)

	// Unauthenticated: used by the k8s liveness/readiness probes.
	r.Get("/healthz", s.handleHealthz)

	r.Group(func(r chi.Router) {
		r.Use(auth.Middleware(s.Resolver))
		r.Use(s.resolveUser)

		r.Get("/ws", ws.Handler(s.Hub))

		r.Route("/api", func(r chi.Router) {
			r.Get("/me", s.handleGetMe)
			r.Patch("/me", s.handleUpdateMe)

			r.Get("/rooms", s.handleListRooms)
			r.Post("/rooms", s.handleCreateRoom)
			r.Get("/rooms/{roomID}/messages", s.handleListMessages)
			r.Post("/rooms/{roomID}/messages", s.handleCreateMessage)
			r.Get("/rooms/{roomID}/search", s.handleSearchMessages)

			r.Post("/livekit/token", s.handleMintLiveKitToken)
		})
	})

	return r
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}
