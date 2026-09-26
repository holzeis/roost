//go:build integration

// Run with both DATABASE_URL and the S3_* vars set — the docker-compose
// stack's postgres/minio services work:
// DATABASE_URL=postgres://... S3_ENDPOINT=localhost:9000 S3_ACCESS_KEY=roost S3_SECRET_KEY=roost-dev-password \
//   go test -tags=integration ./internal/api/...
package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"roost/server/internal/push"
	"roost/server/internal/session"
	"roost/server/internal/ws"
)

// fakeWSConn is the minimal ws.Conn a test needs to mark a user "online"
// via Hub.Register, without a real socket.
type fakeWSConn struct{}

func (fakeWSConn) Send(ws.Event) error { return nil }

// recordingWSConn is fakeWSConn plus a record of every event actually sent
// to it — for asserting who did (or didn't) receive something over the
// socket, not just who got pushed to.
type recordingWSConn struct {
	mu     sync.Mutex
	events []ws.Event
}

func (c *recordingWSConn) Send(ev ws.Event) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.events = append(c.events, ev)
	return nil
}

func (c *recordingWSConn) eventsSnapshot() []ws.Event {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]ws.Event(nil), c.events...)
}

// fakePushSender records every SendCallWake/SendMessageNotification call so
// a test can assert exactly who got pushed to (and who didn't) — this
// project's established fakes-over-mocks convention (see
// app/test/fakes.dart's FakeApiClient).
type fakePushSender struct {
	mu           sync.Mutex
	calls        []fakePushCall
	messageCalls []fakeMessagePushCall
}

type fakePushCall struct {
	deviceToken string
	platform    string
	payload     push.CallWakePayload
}

type fakeMessagePushCall struct {
	deviceToken string
	platform    string
	payload     push.MessagePayload
}

func (f *fakePushSender) SendCallWake(_ context.Context, deviceToken, platform string, payload push.CallWakePayload) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, fakePushCall{deviceToken, platform, payload})
	return nil
}

func (f *fakePushSender) SendMessageNotification(_ context.Context, deviceToken, platform string, payload push.MessagePayload) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.messageCalls = append(f.messageCalls, fakeMessagePushCall{deviceToken, platform, payload})
	return nil
}

func (f *fakePushSender) callsSnapshot() []fakePushCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakePushCall(nil), f.calls...)
}

func (f *fakePushSender) messageCallsSnapshot() []fakeMessagePushCall {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]fakeMessagePushCall(nil), f.messageCalls...)
}

// TestHandleRegisterDevice_UpsertsAndReturnsTheDevice covers the client
// half of FR5.1 — POST /api/devices records a push-capable device for the
// caller.
func TestHandleRegisterDevice_UpsertsAndReturnsTheDevice(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("register-device-%d@github", run), "Registrant")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	body := strings.NewReader(`{"platform":"ios","pushToken":"voip-abc123","tokenType":"voip"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/devices", body)
	req = req.WithContext(session.WithUser(req.Context(), user))
	rec := httptest.NewRecorder()

	s.handleRegisterDevice(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var got struct {
		ID        string `json:"id"`
		UserID    string `json:"userId"`
		Platform  string `json:"platform"`
		TokenType string `json:"tokenType"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got.UserID != user.ID || got.Platform != "ios" || got.TokenType != "voip" {
		t.Fatalf("unexpected device in response: %+v", got)
	}

	devices, err := s.Store.ListDevicesForUser(ctx, user.ID)
	if err != nil {
		t.Fatalf("list devices: %v", err)
	}
	if len(devices) != 1 || devices[0].PushToken != "voip-abc123" || devices[0].TokenType != "voip" {
		t.Fatalf("expected the registered device to be stored, got %+v", devices)
	}
}

// TestHandleRegisterDevice_DefaultsTokenTypeToFCM covers a client that
// doesn't send tokenType at all — the common case, since only the VoIP
// registration path (FR5.1) ever sets it explicitly.
func TestHandleRegisterDevice_DefaultsTokenTypeToFCM(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("default-token-type-%d@github", run), "Default")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	body := strings.NewReader(`{"platform":"android","pushToken":"fcm-abc123"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/devices", body)
	req = req.WithContext(session.WithUser(req.Context(), user))
	rec := httptest.NewRecorder()

	s.handleRegisterDevice(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	devices, err := s.Store.ListDevicesForUser(ctx, user.ID)
	if err != nil {
		t.Fatalf("list devices: %v", err)
	}
	if len(devices) != 1 || devices[0].TokenType != "fcm" {
		t.Fatalf("expected tokenType to default to fcm, got %+v", devices)
	}
}

// TestHandleRegisterDevice_RejectsUnknownTokenType mirrors the platform
// check — a clean 400 rather than a raw DB constraint-violation error.
func TestHandleRegisterDevice_RejectsUnknownTokenType(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("bad-token-type-%d@github", run), "Bad Token Type")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	body := strings.NewReader(`{"platform":"ios","pushToken":"abc","tokenType":"carrier-pigeon"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/devices", body)
	req = req.WithContext(session.WithUser(req.Context(), user))
	rec := httptest.NewRecorder()

	s.handleRegisterDevice(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestHandleRegisterDevice_RejectsUnknownPlatform guards the platform CHECK
// constraint (migration 0001: platform IN ('ios','android')) with a clean
// 400 rather than a raw DB constraint-violation error reaching the client.
func TestHandleRegisterDevice_RejectsUnknownPlatform(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("bad-platform-%d@github", run), "Bad Platform")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	body := strings.NewReader(`{"platform":"windows-phone","pushToken":"abc"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/devices", body)
	req = req.WithContext(session.WithUser(req.Context(), user))
	rec := httptest.NewRecorder()

	s.handleRegisterDevice(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d: %s", rec.Code, rec.Body.String())
	}
}

// TestHandleStartCall_PushesTheOfflineCalleeButNotAnOnlineOne is FR5.1's
// core behavior: a callee with no live WebSocket connection gets a push
// call-wake to each of their registered devices; a callee who's actually
// online gets none, since the WebSocket delivery already reached them.
func TestHandleStartCall_PushesTheOfflineCalleeButNotAnOnlineOne(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	pushSender := &fakePushSender{}
	s.Push = pushSender
	ctx := context.Background()
	run := time.Now().UnixNano()

	caller, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("caller-%d@github", run), "Caller")
	if err != nil {
		t.Fatalf("create caller: %v", err)
	}
	offlineCallee, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("offline-callee-%d@github", run), "Offline Callee")
	if err != nil {
		t.Fatalf("create offline callee: %v", err)
	}
	onlineCallee, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("online-callee-%d@github", run), "Online Callee")
	if err != nil {
		t.Fatalf("create online callee: %v", err)
	}
	if _, err := s.Store.UpsertDevice(ctx, offlineCallee.ID, "ios", "voip-offline-callee", "voip"); err != nil {
		t.Fatalf("register offline callee's device: %v", err)
	}
	if _, err := s.Store.UpsertDevice(ctx, onlineCallee.ID, "android", "fcm-online-callee", "fcm"); err != nil {
		t.Fatalf("register online callee's device: %v", err)
	}
	// Only onlineCallee has a live WS connection — offlineCallee has none,
	// which is exactly the "fall back to push" signal (Hub.SendToUser
	// returns false for them).
	s.Hub.Register(onlineCallee.ID, fakeWSConn{})

	room, err := s.Store.CreateRoom(ctx, caller.ID, nil, true, []string{caller.ID, offlineCallee.ID, onlineCallee.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/rooms/"+room.ID+"/calls", nil)
	req = req.WithContext(session.WithUser(req.Context(), caller))
	req = withURLParam(req, "roomID", room.ID)
	rec := httptest.NewRecorder()

	s.handleStartCall(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var created struct {
		ID   string `json:"id"`
		Call struct {
			ID string `json:"id"`
		} `json:"call"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	calls := pushSender.callsSnapshot()
	if len(calls) != 1 {
		t.Fatalf("expected exactly 1 push call-wake (to the offline callee only), got %d: %+v", len(calls), calls)
	}
	got := calls[0]
	if got.deviceToken != "voip-offline-callee" || got.platform != "ios" {
		t.Fatalf("push went to the wrong device: %+v", got)
	}
	if got.payload.RoomID != room.ID || got.payload.MessageID != created.ID ||
		got.payload.CallID != created.Call.ID || got.payload.CallerID != caller.ID {
		t.Fatalf("unexpected push payload: %+v (want room=%s message=%s call=%s caller=%s)",
			got.payload, room.ID, created.ID, created.Call.ID, caller.ID)
	}
	if created.Call.ID == "" {
		t.Fatal("expected the created call message to carry a non-empty call id")
	}
	if got.payload.CallerName != caller.DisplayName {
		t.Fatalf("expected caller name %q in payload, got %q", caller.DisplayName, got.payload.CallerName)
	}
}

// TestHandleStartCall_NoPushWhenEveryoneIsOnline guards against pushing
// unnecessarily — push is a fallback, not sent alongside a successful
// WebSocket delivery.
func TestHandleStartCall_NoPushWhenEveryoneIsOnline(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	pushSender := &fakePushSender{}
	s.Push = pushSender
	ctx := context.Background()
	run := time.Now().UnixNano()

	caller, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("all-online-caller-%d@github", run), "Caller")
	if err != nil {
		t.Fatalf("create caller: %v", err)
	}
	callee, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("all-online-callee-%d@github", run), "Callee")
	if err != nil {
		t.Fatalf("create callee: %v", err)
	}
	if _, err := s.Store.UpsertDevice(ctx, callee.ID, "ios", "voip-should-not-be-used", "voip"); err != nil {
		t.Fatalf("register callee's device: %v", err)
	}
	s.Hub.Register(callee.ID, fakeWSConn{})

	room, err := s.Store.CreateRoom(ctx, caller.ID, nil, false, []string{caller.ID, callee.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/rooms/"+room.ID+"/calls", nil)
	req = req.WithContext(session.WithUser(req.Context(), caller))
	req = withURLParam(req, "roomID", room.ID)
	rec := httptest.NewRecorder()

	s.handleStartCall(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if calls := pushSender.callsSnapshot(); len(calls) != 0 {
		t.Fatalf("expected no push calls when the callee is online, got %+v", calls)
	}
}

// TestHandleCreateMessage_PushesMessageNotificationToOfflineRecipientsOnly
// is FR5.2's core behavior — the same "WS, else push" pattern as FR5.1's
// call wake, now generalized (deliverMessageEvent) to every message-
// creating handler.
func TestHandleCreateMessage_PushesMessageNotificationToOfflineRecipientsOnly(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	pushSender := &fakePushSender{}
	s.Push = pushSender
	ctx := context.Background()
	run := time.Now().UnixNano()

	sender, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("msg-sender-%d@github", run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	offline, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("msg-offline-%d@github", run), "Offline")
	if err != nil {
		t.Fatalf("create offline recipient: %v", err)
	}
	online, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("msg-online-%d@github", run), "Online")
	if err != nil {
		t.Fatalf("create online recipient: %v", err)
	}
	if _, err := s.Store.UpsertDevice(ctx, offline.ID, "android", "fcm-offline-recipient", "fcm"); err != nil {
		t.Fatalf("register offline recipient's device: %v", err)
	}
	if _, err := s.Store.UpsertDevice(ctx, online.ID, "android", "fcm-online-recipient", "fcm"); err != nil {
		t.Fatalf("register online recipient's device: %v", err)
	}
	s.Hub.Register(online.ID, fakeWSConn{})

	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, true, []string{sender.ID, offline.ID, online.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	body := strings.NewReader(`{"body":"anyone home?"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/rooms/"+room.ID+"/messages", body)
	req = req.WithContext(session.WithUser(req.Context(), sender))
	req = withURLParam(req, "roomID", room.ID)
	rec := httptest.NewRecorder()

	s.handleCreateMessage(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	calls := pushSender.messageCallsSnapshot()
	if len(calls) != 1 {
		t.Fatalf("expected exactly 1 message-notification push (to the offline recipient only), got %d: %+v",
			len(calls), calls)
	}
	got := calls[0]
	if got.deviceToken != "fcm-offline-recipient" {
		t.Fatalf("push went to the wrong device: %+v", got)
	}
	if got.payload.RoomID != room.ID || got.payload.MessageID != created.ID || got.payload.SenderName != sender.DisplayName {
		t.Fatalf("unexpected push payload: %+v (want room=%s message=%s sender=%s)",
			got.payload, room.ID, created.ID, sender.DisplayName)
	}
}

// TestHandleCreateMessage_BroadcastsToSenderOverWebSocket guards a real
// regression: deliverMessageEvent originally reused deliverToRoom's
// "exclude the sender" behavior, copied from handleStartCall's caller (who
// genuinely doesn't need it). But the app has no local optimistic append —
// see chat_providers.dart's send() — so excluding the sender from the
// message.created broadcast meant a sent message never appeared in the
// sender's own chat at all. The sender must still never be pushed about
// their own message, though.
func TestHandleCreateMessage_BroadcastsToSenderOverWebSocket(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	pushSender := &fakePushSender{}
	s.Push = pushSender
	ctx := context.Background()
	run := time.Now().UnixNano()

	sender, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("msg-sender-ws-%d@github", run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	other, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("msg-other-ws-%d@github", run), "Other")
	if err != nil {
		t.Fatalf("create other member: %v", err)
	}

	senderConn := &recordingWSConn{}
	s.Hub.Register(sender.ID, senderConn)

	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, true, []string{sender.ID, other.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	body := strings.NewReader(`{"body":"can you see this?"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/rooms/"+room.ID+"/messages", body)
	req = req.WithContext(session.WithUser(req.Context(), sender))
	req = withURLParam(req, "roomID", room.ID)
	rec := httptest.NewRecorder()

	s.handleCreateMessage(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}

	events := senderConn.eventsSnapshot()
	if len(events) != 1 || events[0].Type != "message.created" {
		t.Fatalf("expected exactly one message.created event sent to the sender's own socket, got %+v", events)
	}

	// other has no registered device, so this only proves the sender
	// specifically was excluded, not just that no push happened at all.
	if calls := pushSender.messageCallsSnapshot(); len(calls) != 0 {
		t.Fatalf("sender should never get a push notification about their own message, got %+v", calls)
	}
}

// TestHandleCreateMessage_SkipsAVoipOnlyDeviceForMessageNotifications
// guards the token_type filter added in migration 0005 — a device that's
// only ever registered its PushKit VoIP token (FR5.1) can't receive a
// plain alert-type push, so it must never be sent a message notification.
func TestHandleCreateMessage_SkipsAVoipOnlyDeviceForMessageNotifications(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	pushSender := &fakePushSender{}
	s.Push = pushSender
	ctx := context.Background()
	run := time.Now().UnixNano()

	sender, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("voip-only-sender-%d@github", run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	offline, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("voip-only-offline-%d@github", run), "Offline")
	if err != nil {
		t.Fatalf("create offline recipient: %v", err)
	}
	if _, err := s.Store.UpsertDevice(ctx, offline.ID, "ios", "voip-only-token", "voip"); err != nil {
		t.Fatalf("register offline recipient's voip-only device: %v", err)
	}

	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, false, []string{sender.ID, offline.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	body := strings.NewReader(`{"body":"hello"}`)
	req := httptest.NewRequest(http.MethodPost, "/api/rooms/"+room.ID+"/messages", body)
	req = req.WithContext(session.WithUser(req.Context(), sender))
	req = withURLParam(req, "roomID", room.ID)
	rec := httptest.NewRecorder()

	s.handleCreateMessage(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	if calls := pushSender.messageCallsSnapshot(); len(calls) != 0 {
		t.Fatalf("expected no message-notification push to a voip-only device, got %+v", calls)
	}
}
