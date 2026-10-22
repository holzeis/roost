package auth

import (
	"context"
	"net"
	"slices"
)

// DevResolver is a fixed, non-network identity used only for local
// docker-compose development, where there's no real tailnet to join. It must
// never be wired up outside ENABLE_DEV_AUTH=true (see cmd/server) — it grants
// every connection the same fake identity with no verification at all.
type DevResolver struct {
	Identity Identity
	// BotHost, when set, is a hostname (the alert-bridge compose service)
	// whose connections get the alert identity instead, so the bridge can be
	// exercised end to end locally.
	BotHost string
}

func (r DevResolver) WhoIs(ctx context.Context, remoteAddr string) (Identity, error) {
	if r.BotHost != "" {
		host, _, err := net.SplitHostPort(remoteAddr)
		if err == nil {
			if addrs, err := net.DefaultResolver.LookupHost(ctx, r.BotHost); err == nil && slices.Contains(addrs, host) {
				return Identity{LoginName: "tag:dev-alerts", DisplayName: AlertDisplayName, Bot: true}, nil
			}
		}
	}
	return r.Identity, nil
}
