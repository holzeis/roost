// Package push sends the wake-up notifications described in the call flow
// in docs/architecture-overview.md: when a callee isn't reachable over the
// WebSocket, the server pushes just enough data via APNs/FCM to wake the app
// and let CallKit/ConnectionService show the native incoming-call screen.
// Payloads deliberately carry no LiveKit token or message content (push
// transport isn't guaranteed end-to-end encrypted the way tailnet traffic
// is) — the app calls back over the tailnet to fetch the real token.
//
// The concrete APNs/FCM clients are not wired up yet; Sender is the
// integration point once real credentials exist (see .env.example).
package push

import "context"

type CallWakePayload struct {
	CallID   string
	RoomID   string
	CallerID string
}

type MessagePayload struct {
	RoomID    string
	MessageID string
}

// Sender delivers a wake-up push to a single device. Implementations should
// treat delivery failure as non-fatal to the caller — push is a best-effort
// fallback, not the primary delivery path (that's the WebSocket).
type Sender interface {
	SendCallWake(ctx context.Context, deviceToken, platform string, payload CallWakePayload) error
	SendMessageNotification(ctx context.Context, deviceToken, platform string, payload MessagePayload) error
}

// NoopSender is used until real APNs/FCM credentials are configured; it logs
// nothing and does nothing, so local dev without push credentials still
// works for everything except actually waking a backgrounded device.
type NoopSender struct{}

func (NoopSender) SendCallWake(ctx context.Context, deviceToken, platform string, payload CallWakePayload) error {
	return nil
}

func (NoopSender) SendMessageNotification(ctx context.Context, deviceToken, platform string, payload MessagePayload) error {
	return nil
}
