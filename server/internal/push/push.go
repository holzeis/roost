// Package push sends the wake-up notifications described in the call flow
// in docs/architecture-overview.md: when a callee isn't reachable over the
// WebSocket, the server pushes just enough data via APNs/FCM to wake the app
// and let CallKit/ConnectionService show the native incoming-call screen.
// Payloads deliberately carry no LiveKit token (push transport isn't
// guaranteed end-to-end encrypted the way tailnet traffic is) — the app
// calls back over the tailnet to fetch the real token. A message
// notification's preview is the one piece of content that does travel, and
// only end-to-end encrypted to the receiving device (internal/cryptobox):
// Apple and Google see ciphertext.
package push

import (
	"context"
	"encoding/base64"
	"fmt"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"github.com/sideshow/apns2"
	"github.com/sideshow/apns2/token"
	"google.golang.org/api/option"

	"roost/server/internal/cryptobox"
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

// MessagePayload backs FR5.2 — a "new message" notification. SenderName
// is its title, sent as is. Preview (the message text, or "Photo" and the
// like) is never sent as is: it's encrypted to each receiving device's own
// public key, and a device without one gets generic text instead.
type MessagePayload struct {
	RoomID     string
	MessageID  string
	SenderName string
	Preview    string
}

// maxPreviewRunes caps the encrypted preview, keeping the notification well
// within APNs' 4 KB payload limit; the notification shows a line or two.
const maxPreviewRunes = 160

// genericBody is shown when a device can't get an encrypted preview (no
// key registered, e.g. an older app version).
const genericBody = "Sent a message in Roost"

// Sender delivers a wake-up push to a single device. Implementations should
// treat delivery failure as non-fatal to the caller — push is a best-effort
// fallback, not the primary delivery path (that's the WebSocket).
type Sender interface {
	SendCallWake(ctx context.Context, deviceToken, platform string, payload CallWakePayload) error
	// pushPublicKey: the device's X25519 key (base64) to encrypt the
	// preview to, or nil for the generic text.
	SendMessageNotification(ctx context.Context, deviceToken, platform string, pushPublicKey *string, payload MessagePayload) error
}

// NoopSender is used until real APNs/FCM credentials are configured; it logs
// nothing and does nothing, so local dev without push credentials still
// works for everything except actually waking a backgrounded device.
type NoopSender struct{}

func (NoopSender) SendCallWake(ctx context.Context, deviceToken, platform string, payload CallWakePayload) error {
	return nil
}

func (NoopSender) SendMessageNotification(ctx context.Context, deviceToken, platform string, pushPublicKey *string, payload MessagePayload) error {
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
// does. platform still matters: it decides how the encrypted preview is
// delivered (see BuildMessageNotification).
func (m MultiSender) SendMessageNotification(ctx context.Context, deviceToken, platform string, pushPublicKey *string, payload MessagePayload) error {
	if m.FCM == nil {
		return nil
	}
	return m.FCM.SendMessageNotification(ctx, deviceToken, platform, pushPublicKey, payload)
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
	n := &apns2.Notification{
		DeviceToken: deviceToken,
		Topic:       a.bundleID + ".voip",
		PushType:    apns2.PushTypeVOIP,
		Priority:    apns2.PriorityHigh,
		Payload:     apnsCallWakeBody(payload),
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

// apnsCallWakeBody builds the VoIP push body AppDelegate.swift reads — see
// APNsSender's doc comment.
func apnsCallWakeBody(payload CallWakePayload) map[string]any {
	nameCaller := payload.CallerName
	if nameCaller == "" {
		nameCaller = "Incoming call"
	}
	return map[string]any{
		"aps":        map[string]any{},
		"id":         payload.MessageID,
		"nameCaller": nameCaller,
		"handle":     "Roost",
		"isVideo":    true, // every call starts as video (FR4.1/FR4.2)
		"roomId":     payload.RoomID,
		"messageId":  payload.MessageID,
		"callId":     payload.CallID,
		"callerId":   payload.CallerID,
	}
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

// SendMessageNotification (FR5.2) sends one device its notification for a
// new message — see BuildMessageNotification for its shape.
func (f *FCMSender) SendMessageNotification(ctx context.Context, deviceToken, platform string, pushPublicKey *string, payload MessagePayload) error {
	msg, err := BuildMessageNotification(deviceToken, platform, pushPublicKey, payload)
	if err != nil {
		return err
	}
	if _, err := f.client.Send(ctx, msg); err != nil {
		return fmt.Errorf("push: send fcm message notification: %w", err)
	}
	return nil
}

// BuildMessageNotification builds the FCM message for one device:
//   - Without a usable public key: a plain notification the OS shows by
//     itself, with generic text — what every device got before previews
//     existed.
//   - Android: data-only and high priority, like call wake. The app wakes,
//     decrypts the preview and shows the notification itself.
//   - iOS: a real notification with generic text plus "mutable-content",
//     so the app's notification service extension can decrypt the preview
//     and put it in place before it's shown; if the extension can't, the
//     generic text is what appears.
//
// The data carries type "message" (call wake has none), the ids for tap
// routing, the sender's name, and with a key the scheme, the ephemeral
// public key and the ciphertext.
func BuildMessageNotification(deviceToken, platform string, pushPublicKey *string, payload MessagePayload) (*messaging.Message, error) {
	title := payload.SenderName
	if title == "" {
		title = "New message"
	}
	data := map[string]string{
		"type":       "message",
		"roomId":     payload.RoomID,
		"messageId":  payload.MessageID,
		"senderName": title,
	}

	var recipient [32]byte
	encrypt := pushPublicKey != nil
	if encrypt {
		key, err := cryptobox.ParsePublicKey(*pushPublicKey)
		if err != nil {
			encrypt = false // unusable key: fall back to the generic text
		}
		recipient = key
	}
	if !encrypt {
		return &messaging.Message{
			Token:        deviceToken,
			Notification: &messaging.Notification{Title: title, Body: genericBody},
			Data:         data,
		}, nil
	}

	ephemeralPub, ciphertext, err := cryptobox.Seal(recipient, []byte(truncateRunes(payload.Preview, maxPreviewRunes)))
	if err != nil {
		return nil, fmt.Errorf("push: encrypt preview: %w", err)
	}
	data["scheme"] = cryptobox.Scheme
	data["ephemeralPublicKey"] = base64.StdEncoding.EncodeToString(ephemeralPub[:])
	data["ciphertext"] = base64.StdEncoding.EncodeToString(ciphertext)

	msg := &messaging.Message{Token: deviceToken, Data: data}
	if platform == "ios" {
		msg.Notification = &messaging.Notification{Title: title, Body: "New message"}
		msg.APNS = &messaging.APNSConfig{
			Payload: &messaging.APNSPayload{Aps: &messaging.Aps{MutableContent: true}},
		}
	} else {
		msg.Android = &messaging.AndroidConfig{Priority: "high"}
	}
	return msg, nil
}

// truncateRunes shortens s to at most n characters, ending in an ellipsis.
func truncateRunes(s string, n int) string {
	runes := []rune(s)
	if len(runes) <= n {
		return s
	}
	return string(runes[:n-1]) + "…"
}
