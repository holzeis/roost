// Package session carries the resolved local user (see store.Store) through
// a request, once auth.Middleware's tailnet identity has been mapped to it.
// It's a separate package from auth (raw Tailscale identity) and api (route
// wiring) purely to avoid an import cycle between api and ws, which both
// need to read "who is this request for" without depending on each other.
package session

import (
	"context"

	"roost/server/internal/models"
)

type contextKey struct{}

func WithUser(ctx context.Context, u models.User) context.Context {
	return context.WithValue(ctx, contextKey{}, u)
}

func UserFromContext(ctx context.Context) (models.User, bool) {
	u, ok := ctx.Value(contextKey{}).(models.User)
	return u, ok
}
