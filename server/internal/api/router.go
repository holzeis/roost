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
	"roost/server/internal/storage"
	"roost/server/internal/store"
	"roost/server/internal/ws"
)

type Server struct {
	Store    *store.Store
	Hub      *ws.Hub
	LiveKit  *livekit.Minter
	Media    *storage.Store
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

		r.Get("/ws", ws.Handler(s.Hub, s.Store))

		r.Route("/api", func(r chi.Router) {
			r.Get("/me", s.handleGetMe)
			r.Patch("/me", s.handleUpdateMe)
			r.Post("/me/avatar", s.handleUploadAvatar)

			r.Get("/users", s.handleListUsers)

			r.Get("/rooms", s.handleListRooms)
			r.Post("/rooms", s.handleCreateRoom)
			r.Get("/rooms/{roomID}", s.handleGetRoom)
			r.Get("/rooms/{roomID}/messages", s.handleListMessages)
			r.Post("/rooms/{roomID}/messages", s.handleCreateMessage)
			r.Get("/rooms/{roomID}/search", s.handleSearchMessages)
			r.Post("/rooms/{roomID}/media", s.handleUploadMedia)
			r.Post("/rooms/{roomID}/receipts", s.handleAckReceipts)
			r.Post("/rooms/{roomID}/location", s.handleShareLocation)
			r.Post("/rooms/{roomID}/calls", s.handleStartCall)

			r.Get("/media/{mediaID}", s.handleGetMedia)
			r.Delete("/media/{mediaID}", s.handleDeleteMedia)

			r.Put("/messages/{messageID}/reactions/{emoji}", s.handleAddReaction)
			r.Delete("/messages/{messageID}/reactions/{emoji}", s.handleRemoveReaction)
			r.Patch("/messages/{messageID}", s.handleEditMessage)
			r.Post("/messages/{messageID}/forward", s.handleForwardMessage)
			r.Patch("/messages/{messageID}/location", s.handleUpdateLocation)
			r.Post("/messages/{messageID}/location/end", s.handleEndLocationShare)

			r.Post("/calls/{callID}/accept", s.handleAcceptCall)
			r.Post("/calls/{callID}/decline", s.handleDeclineCall)
			r.Post("/calls/{callID}/leave", s.handleLeaveCall)

			r.Get("/link-preview", s.handleLinkPreview)

			r.Post("/livekit/token", s.handleMintLiveKitToken)
		})
	})

	return r
}

func (s *Server) handleHealthz(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}
