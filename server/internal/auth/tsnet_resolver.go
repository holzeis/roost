package auth

import (
	"context"
	"fmt"
	"slices"

	"tailscale.com/client/tailscale"
	"tailscale.com/client/tailscale/apitype"
)

// AlertDisplayName is the name the alert identity shows up as in chat.
const AlertDisplayName = "Alerts"

// TsnetResolver resolves identity via the LocalAPI of an in-process tsnet
// node (see cmd/server, which constructs the tsnet.Server and passes its
// LocalClient here). This only works for connections actually accepted on
// that node's own tailnet listener.
type TsnetResolver struct {
	Local *tailscale.LocalClient
	// AlertTag is the ACL tag (e.g. "tag:roost-alerts") of the alert
	// bridge's node. Empty disables the alert identity entirely.
	AlertTag string
}

func (r TsnetResolver) WhoIs(ctx context.Context, remoteAddr string) (Identity, error) {
	who, err := r.Local.WhoIs(ctx, remoteAddr)
	if err != nil {
		return Identity{}, fmt.Errorf("%w: %v", ErrUnknownIdentity, err)
	}
	return identityFromWhoIs(who, r.AlertTag)
}

// identityFromWhoIs maps a WhoIs answer to an Identity.
//
// Tagged nodes have no owning user: Tailscale reports every one of them as
// the single login "tagged-devices", so keying on LoginName would merge
// them all into one user. A tagged node is therefore accepted only when it
// carries alertTag, and is keyed by that tag; any other tagged node is
// refused, since none is a family member's device.
func identityFromWhoIs(who *apitype.WhoIsResponse, alertTag string) (Identity, error) {
	if who.Node != nil && who.Node.IsTagged() {
		if alertTag != "" && slices.Contains(who.Node.Tags, alertTag) {
			return Identity{LoginName: alertTag, DisplayName: AlertDisplayName, Bot: true}, nil
		}
		return Identity{}, ErrUnknownIdentity
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
