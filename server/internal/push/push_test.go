package push

import (
	"encoding/base64"
	"strings"
	"testing"

	"roost/server/internal/cryptobox"
)

func TestAPNsCallWakeBody(t *testing.T) {
	body := apnsCallWakeBody(CallWakePayload{
		RoomID:     "room-1",
		MessageID:  "msg-1",
		CallID:     "call-1",
		CallerID:   "user-1",
		CallerName: "Mom",
	})

	want := map[string]any{
		"id":         "msg-1",
		"nameCaller": "Mom",
		"handle":     "Roost",
		"isVideo":    true,
		"roomId":     "room-1",
		"messageId":  "msg-1",
		"callId":     "call-1",
		"callerId":   "user-1",
	}
	for k, v := range want {
		if body[k] != v {
			t.Errorf("body[%q] = %v, want %v", k, body[k], v)
		}
	}
	if _, ok := body["aps"]; !ok {
		t.Error(`body has no "aps" key; APNs rejects a payload without one`)
	}
}

func TestAPNsCallWakeBodyDefaultsCallerName(t *testing.T) {
	body := apnsCallWakeBody(CallWakePayload{RoomID: "room-1", MessageID: "msg-1"})
	if body["nameCaller"] != "Incoming call" {
		t.Errorf("nameCaller = %v, want %q", body["nameCaller"], "Incoming call")
	}
}

// testDeviceKeys is a device key pair for the message-notification tests
// (the recipient key from cryptobox's shared test vector).
func testDeviceKeys(t *testing.T) (priv [32]byte, pubB64 string) {
	t.Helper()
	privB64 := "ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0A="
	pubB64 = "WGmv9FBUlzLLqu1eXfmzCm2jHLDldCutWtShp2jxpns="
	k, err := cryptobox.ParsePublicKey(privB64)
	if err != nil {
		t.Fatal(err)
	}
	return k, pubB64
}

func openPreview(t *testing.T, priv [32]byte, data map[string]string) string {
	t.Helper()
	eph, err := cryptobox.ParsePublicKey(data["ephemeralPublicKey"])
	if err != nil {
		t.Fatalf("ephemeral key: %v", err)
	}
	ct, err := base64.StdEncoding.DecodeString(data["ciphertext"])
	if err != nil {
		t.Fatalf("ciphertext: %v", err)
	}
	plain, err := cryptobox.Open(priv, eph, ct)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	return string(plain)
}

var testPayload = MessagePayload{RoomID: "room-1", MessageID: "msg-1", SenderName: "Mom", Preview: "Dinner's at 7"}

func TestBuildMessageNotification_WithoutKeyIsGeneric(t *testing.T) {
	for _, platform := range []string{"ios", "android"} {
		msg, err := BuildMessageNotification("token", platform, nil, testPayload)
		if err != nil {
			t.Fatal(err)
		}
		if msg.Notification == nil || msg.Notification.Title != "Mom" || msg.Notification.Body != genericBody {
			t.Fatalf("%s: expected the generic notification, got %+v", platform, msg.Notification)
		}
		if _, ok := msg.Data["ciphertext"]; ok {
			t.Fatalf("%s: nothing encrypted without a key", platform)
		}
		if msg.Data["type"] != "message" || msg.Data["roomId"] != "room-1" {
			t.Fatalf("%s: missing routing data: %v", platform, msg.Data)
		}
	}
	bad := "not-a-key"
	msg, err := BuildMessageNotification("token", "ios", &bad, testPayload)
	if err != nil || msg.Notification.Body != genericBody {
		t.Fatalf("an unusable key falls back to the generic text: %+v, %v", msg, err)
	}
}

func TestBuildMessageNotification_AndroidIsDataOnlyAndEncrypted(t *testing.T) {
	priv, pub := testDeviceKeys(t)
	msg, err := BuildMessageNotification("token", "android", &pub, testPayload)
	if err != nil {
		t.Fatal(err)
	}
	if msg.Notification != nil {
		t.Fatal("Android must get a data-only message, shown by the app after decrypting")
	}
	if msg.Android == nil || msg.Android.Priority != "high" {
		t.Fatal("high priority, so a killed app wakes for it")
	}
	if msg.Data["scheme"] != cryptobox.Scheme || msg.Data["senderName"] != "Mom" {
		t.Fatalf("unexpected data: %v", msg.Data)
	}
	if got := openPreview(t, priv, msg.Data); got != "Dinner's at 7" {
		t.Fatalf("decrypted preview = %q", got)
	}
	for _, v := range msg.Data {
		if strings.Contains(v, "Dinner") {
			t.Fatal("the preview must never travel in plaintext")
		}
	}
}

func TestBuildMessageNotification_IOSIsMutableWithGenericFallback(t *testing.T) {
	priv, pub := testDeviceKeys(t)
	msg, err := BuildMessageNotification("token", "ios", &pub, testPayload)
	if err != nil {
		t.Fatal(err)
	}
	if msg.Notification == nil || msg.Notification.Title != "Mom" || msg.Notification.Body != "New message" {
		t.Fatalf("expected a visible fallback notification, got %+v", msg.Notification)
	}
	if msg.APNS == nil || msg.APNS.Payload == nil || !msg.APNS.Payload.Aps.MutableContent {
		t.Fatal("mutable-content is what lets the notification service extension decrypt it")
	}
	if got := openPreview(t, priv, msg.Data); got != "Dinner's at 7" {
		t.Fatalf("decrypted preview = %q", got)
	}
}

func TestBuildMessageNotification_TruncatesLongPreviews(t *testing.T) {
	priv, pub := testDeviceKeys(t)
	long := MessagePayload{SenderName: "Mom", Preview: strings.Repeat("ä", 500)}
	msg, err := BuildMessageNotification("token", "android", &pub, long)
	if err != nil {
		t.Fatal(err)
	}
	got := openPreview(t, priv, msg.Data)
	if n := len([]rune(got)); n != maxPreviewRunes || !strings.HasSuffix(got, "…") {
		t.Fatalf("expected %d characters ending in an ellipsis, got %d", maxPreviewRunes, n)
	}
}
