// Package push sends the wake-up notifications described in the call flow
// in docs/architecture-overview.md: when a callee isn't reachable over the
// WebSocket, the server pushes just enough data via APNs/FCM to wake the app
// and let CallKit/ConnectionService show the native incoming-call screen.
// Payloads deliberately carry no LiveKit token or message content (push
// transport isn't guaranteed end-to-end encrypted the way tailnet traffic
// is) — the app calls back over the tailnet to fetch the real token.
package push

import (
	"context"
	"fmt"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"
	"google.golang.org/api/option"
)

// CallWakePayload carries what IncomingCallScreen needs to render itself
// (see lib/features/call/incoming_call_screen.dart) — roomId and messageId,
// the same pair the existing WebSocket call.created path already hands the
// client — plus callId, needed separately since it's the calls table's own
// id (not messageId) that /api/calls/{callID}/decline expects, for a
// decline made directly from the native CallKit UI before the app's own
// providers are even running. CallerName is a display-only nicety for the
// native CallKit/notification UI shown before the app itself is reachable.
type CallWakePayload struct {
	RoomID     string
	MessageID  string
	CallID     string
	CallerID   string
	CallerName string
}

// MessagePayload backs FR5.2 — a generic "new message" notification.
// Deliberately carries no message body/preview (see this package's own doc
// comment on why); SenderName is the one bit of context shown, the same
// way CallWakePayload.CallerName is display-only for the call-wake case.
type MessagePayload struct {
	RoomID     string
	MessageID  string
	SenderName string
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

// MultiSender dispatches to APNs or FCM by platform — the one Sender
// actually injected into api.Server once real credentials are configured
// (see server/cmd/server/main.go).
type MultiSender struct {
	APNs *APNsSender
	FCM  *FCMSender
}

func (m MultiSender) SendCallWake(ctx context.Context, deviceToken, platform string, payload CallWakePayload) error {
	switch platform {
	case "ios":
		if m.APNs == nil {
			return nil
		}
		return m.APNs.SendCallWake(ctx, deviceToken, payload)
	case "android":
		if m.FCM == nil {
			return nil
		}
		return m.FCM.SendCallWake(ctx, deviceToken, payload)
	default:
		return fmt.Errorf("push: unknown platform %q", platform)
	}
}

// SendMessageNotification always routes through FCM regardless of
// platform — unlike call-wake, iOS's message-notification token is itself
// an FCM token (obtained via firebase_messaging, not PushKit; see
// lib/services/push_service.dart), since a plain alert notification
// doesn't need PushKit/CallKit's special wake guarantees the way a call
// does. platform is accepted for interface-symmetry with SendCallWake but
// unused here.
func (m MultiSender) SendMessageNotification(ctx context.Context, deviceToken, platform string, payload MessagePayload) error {
	if m.FCM == nil {
		return nil
	}
	return m.FCM.SendMessageNotification(ctx, deviceToken, payload)
}

// APNsSender wakes iOS for CallKit via a PushKit VoIP-type push (Apple's
// HTTP/2 provider API, token-based .p8 auth — see token.AuthKeyFromBytes).
// A plain remote notification can't reliably wake a backgrounded/killed app
// for CallKit; VoIP is the only transport Apple guarantees for this. The
// payload shape (id/nameCaller/handle/isVideo, plus our own roomId/
// messageId/callerId) matches what flutter_callkit_incoming's iOS side
// reads in pushRegistry(_:didReceiveIncomingPushWith:for:completion:) —
// see ios/Runner/AppDelegate.swift and PUSHKIT.md in the installed package.
type APNsSender struct {
	client   *apns2.Client
	bundleID string
}

// NewAPNsSender builds a token-authenticated APNs client. production
// selects Apple's production vs. sandbox push gateway — sandbox for
// development-signed builds, production for TestFlight/App Store builds.
func NewAPNsSender(keyID, teamID string, privateKeyPEM []byte, bundleID string, production bool) (*APNsSender, error) {
	authKey, err := token.AuthKeyFromBytes(privateKeyPEM)
	if err != nil {
		return nil, fmt.Errorf("push: parse apns auth key: %w", err)
	}
	tok := &token.Token{AuthKey: authKey, KeyID: keyID, TeamID: teamID}
	client := apns2.NewTokenClient(tok)
	if production {
		client = client.Production()
	} else {
		client = client.Development()
	}
	return &APNsSender{client: client, bundleID: bundleID}, nil
}

func (a *APNsSender) SendCallWake(ctx context.Context, deviceToken string, payload CallWakePayload) error {
	nameCaller := payload.CallerName
	if nameCaller == "" {
		nameCaller = "Incoming call"
	}
	body := map[string]any{
		"aps":        map[string]any{},
		"id":         payload.MessageID,
		"nameCaller": nameCaller,
		"handle":     "Roost",
		"isVideo":    false,
		"roomId":     payload.RoomID,
		"messageId":  payload.MessageID,
		"callId":     payload.CallID,
		"callerId":   payload.CallerID,
	}
	n := &apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       a.bundleID + ".voip",
		PushType:    apns2.PushTypeVOIP,
		Priority:    apns2.PriorityHigh,
		Payload:     body,
	}
	res, err := a.client.PushWithContext(ctx, n)
	if err != nil {
		return fmt.Errorf("push: send apns call wake: %w", err)
	}
	if !res.Sent() {
		return fmt.Errorf("push: apns rejected call wake: %d %s", res.StatusCode, res.Reason)
	}
	return nil
}

// FCMSender wakes Android for the incoming-call UI via a high-priority,
// data-only FCM message (no "notification" block) — the app's own
// background handler (lib/services/push_service.dart) turns this into
// flutter_callkit_incoming's full-screen call UI itself, the same way the
// APNs side hands a payload to flutter_callkit_incoming natively.
type FCMSender struct {
	client *messaging.Client
}

func NewFCMSender(ctx context.Context, serviceAccountJSON []byte) (*FCMSender, error) {
	app, err := firebase.NewApp(ctx, nil, option.WithCredentialsJSON(serviceAccountJSON))
	if err != nil {
		return nil, fmt.Errorf("push: init firebase app: %w", err)
	}
	client, err := app.Messaging(ctx)
	if err != nil {
		return nil, fmt.Errorf("push: init fcm client: %w", err)
	}
	return &FCMSender{client: client}, nil
}

func (f *FCMSender) SendCallWake(ctx context.Context, deviceToken string, payload CallWakePayload) error {
	_, err := f.client.Send(ctx, &messaging.Message{
		Token: deviceToken,
		Data: map[string]string{
			"roomId":     payload.RoomID,
			"messageId":  payload.MessageID,
			"callId":     payload.CallID,
			"callerId":   payload.CallerID,
			"callerName": payload.CallerName,
		},
		Android: &messaging.AndroidConfig{
			Priority: "high",
		},
	})
	if err != nil {
		return fmt.Errorf("push: send fcm call wake: %w", err)
	}
	return nil
}

// SendMessageNotification (FR5.2) sends a real "notification" message
// (title/body), not a data-only one — unlike call wake, there's no custom
// UI to build ourselves here; the OS shows it natively even while the app
// is backgrounded or fully closed. Body is deliberately generic (see this
// package's own doc comment) — never the actual message text.
func (f *FCMSender) SendMessageNotification(ctx context.Context, deviceToken string, payload MessagePayload) error {
	title := payload.SenderName
	if title == "" {
		title = "New message"
	}
	_, err := f.client.Send(ctx, &messaging.Message{
		Token: deviceToken,
		Notification: &messaging.Notification{
			Title: title,
			Body:  "Sent a message in Roost",
		},
		Data: map[string]string{
			"roomId":    payload.RoomID,
			"messageId": payload.MessageID,
		},
	})
	if err != nil {
		return fmt.Errorf("push: send fcm message notification: %w", err)
	}
	return nil
}
