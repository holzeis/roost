package api

import (
	"net/http"

	"roost/server/internal/auth"
	"roost/server/internal/session"
)

// resolveUser maps the tailnet identity attached by auth.Middleware to a
// local user row, provisioning one on first contact (FR6.1: no separate
// signup — the first authenticated request from a Tailscale identity is
// enough to create the user).
func (s *Server) resolveUser(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		identity, ok := auth.FromContext(r.Context())
		if !ok {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
		user, err := s.Store.GetOrCreateUserByTailscaleID(r.Context(), identity.LoginName, identity.DisplayName)
		if err != nil {
			http.Error(w, "internal error", http.StatusInternalServerError)
			return
		}
		ctx := session.WithUser(r.Context(), user)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}
