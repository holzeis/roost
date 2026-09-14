// Package auth resolves the calling Tailscale identity for each request.
//
// Per the architecture decision "Tailscale identity instead of a custom auth
// system" (docs/architecture-overview.md), there is no password or session
// system: the network identity of the connecting device *is* the application
// identity. In production the server joins the tailnet itself as a node
// (via tsnet) so it can ask the embedded tailscaled "who owns this
// connection" for every request — this is what lets a Service exposed by the
// Tailscale Kubernetes operator resolve per-request identity rather than
// only gating network access at the edge.
package auth

import (
	"context"
	"errors"
	"net/http"
)

// Identity is the Tailscale-derived identity of a connected device/user.
type Identity struct {
	// LoginName is the stable Tailscale login (e.g. "alice@github"), used as
	// the durable key for provisioning/looking up the local user row.
	LoginName string
	// DisplayName is a human-friendly name, used only to seed a new user's
	// display name on first contact — the user can rename themselves after.
	DisplayName string
}

// Resolver maps a connection's remote address to the Tailscale identity that
// owns it. RemoteAddr is the same string as http.Request.RemoteAddr.
type Resolver interface {
	WhoIs(ctx context.Context, remoteAddr string) (Identity, error)
}

var ErrUnknownIdentity = errors.New("auth: could not resolve a tailnet identity for this connection")

type contextKey struct{}

// Middleware resolves the caller's identity via resolver and stores it on
// the request context; handlers read it back with FromContext. Requests
// whose identity can't be resolved are rejected with 403 — under the
// "trust follows the network" principle, an unresolvable connection has no
// legitimate way to authenticate itself.
func Middleware(resolver Resolver) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			identity, err := resolver.WhoIs(r.Context(), r.RemoteAddr)
			if err != nil {
				http.Error(w, "forbidden: not a recognized tailnet identity", http.StatusForbidden)
				return
			}
			ctx := context.WithValue(r.Context(), contextKey{}, identity)
			next.ServeHTTP(w, r.WithContext(ctx))
		})
	}
}

// FromContext returns the identity attached by Middleware.
func FromContext(ctx context.Context) (Identity, bool) {
	identity, ok := ctx.Value(contextKey{}).(Identity)
	return identity, ok
}
