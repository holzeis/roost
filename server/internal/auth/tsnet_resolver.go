package auth

import (
	"context"
	"fmt"

	"tailscale.com/client/tailscale"
)

// TsnetResolver resolves identity via the LocalAPI of an in-process tsnet
// node (see cmd/server, which constructs the tsnet.Server and passes its
// LocalClient here). This only works for connections actually accepted on
// that node's own tailnet listener.
type TsnetResolver struct {
	Local *tailscale.LocalClient
}

func (r TsnetResolver) WhoIs(ctx context.Context, remoteAddr string) (Identity, error) {
	who, err := r.Local.WhoIs(ctx, remoteAddr)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %v", ErrUnknownIdentity, err)
	}
	if who.UserProfile == nil || who.UserProfile.LoginName == "" {
		return Identity{}, ErrUnknownIdentity
	}
	displayName := who.UserProfile.DisplayName
	if displayName == "" {
		displayName = who.UserProfile.LoginName
	}
	return Identity{
		LoginName:   who.UserProfile.LoginName,
		DisplayName: displayName,
	}, nil
}
