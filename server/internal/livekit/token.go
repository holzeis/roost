// Package livekit mints LiveKit access tokens. Per the architecture
// decision "chat server brokers signaling, never touches media", this is
// the server's entire involvement in a call: it hands the client a
// short-lived token and gets out of the way — audio/video flows directly
// between the client and the LiveKit SFU.
package livekit

import (
	"time"

	auth "github.com/livekit/protocol/auth"
)

type Minter struct {
	apiKey    string
	apiSecret string
	ttl       time.Duration
}

func NewMinter(apiKey, apiSecret string) *Minter {
	return &Minter{apiKey: apiKey, apiSecret: apiSecret, ttl: time.Hour}
}

// Token mints a token granting identity (the local user ID) permission to
// join roomName, with permission to publish and subscribe to audio/video.
func (m *Minter) Token(identity, roomName string) (string, error) {
	grant := &auth.VideoGrant{
		RoomJoin:     true,
		Room:         roomName,
		CanPublish:   boolPtr(true),
		CanSubscribe: boolPtr(true),
	}
	at := auth.NewAccessToken(m.apiKey, m.apiSecret).
		AddGrant(grant).
		SetIdentity(identity).
		SetValidFor(m.ttl)
	return at.ToJWT()
}

func boolPtr(b bool) *bool { return &b }
