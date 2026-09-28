package push

import "testing"

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
