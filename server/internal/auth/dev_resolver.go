package auth

import "context"

// DevResolver is a fixed, non-network identity used only for local
// docker-compose development, where there's no real tailnet to join. It must
// never be wired up outside ENABLE_DEV_AUTH=true (see cmd/server) — it grants
// every connection the same fake identity with no verification at all.
type DevResolver struct {
	Identity Identity
}

func (r DevResolver) WhoIs(ctx context.Context, remoteAddr string) (Identity, error) {
	return r.Identity, nil
}
