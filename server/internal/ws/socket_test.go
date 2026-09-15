package ws

import (
	"context"
	"errors"
	"reflect"
	"sort"
	"testing"
)

// fakeMembership is a small in-memory stand-in for *store.Store's
// ListRoomMemberIDs, used to unit-test handleTypingSignal's decision logic
// without a real database.
type fakeMembership struct {
	members map[string][]string // roomID -> member userIDs
	err     error
}

func (f *fakeMembership) ListRoomMemberIDs(ctx context.Context, roomID string) ([]string, error) {
	if f.err != nil {
		return nil, f.err
	}
	return f.members[roomID], nil
}

func TestHandleTypingSignal_ValidStart(t *testing.T) {
	membership := &fakeMembership{members: map[string][]string{
		"room-1": {"alice", "bob", "carol"},
	}}

	recipients, ev, ok := handleTypingSignal(context.Background(), membership, "alice",
		[]byte(`{"type":"typing.start","payload":{"roomId":"room-1"}}`))
	if !ok {
		t.Fatal("expected ok=true for a valid typing.start from a room member")
	}
	sort.Strings(recipients)
	if !reflect.DeepEqual(recipients, []string{"bob", "carol"}) {
		t.Fatalf("expected recipients to be the other room members, got %v", recipients)
	}
	if ev.Type != "typing" {
		t.Fatalf("expected event type %q, got %q", "typing", ev.Type)
	}
	payload, ok := ev.Payload.(map[string]any)
	if !ok {
		t.Fatalf("expected payload to be a map, got %T", ev.Payload)
	}
	if payload["roomId"] != "room-1" || payload["userId"] != "alice" || payload["typing"] != true {
		t.Fatalf("unexpected payload: %+v", payload)
	}
}

func TestHandleTypingSignal_ValidStop(t *testing.T) {
	membership := &fakeMembership{members: map[string][]string{
		"room-1": {"alice", "bob"},
	}}

	_, ev, ok := handleTypingSignal(context.Background(), membership, "alice",
		[]byte(`{"type":"typing.stop","payload":{"roomId":"room-1"}}`))
	if !ok {
		t.Fatal("expected ok=true for a valid typing.stop from a room member")
	}
	payload := ev.Payload.(map[string]any)
	if payload["typing"] != false {
		t.Fatalf("expected typing=false, got %+v", payload)
	}
}

func TestHandleTypingSignal_MalformedJSON(t *testing.T) {
	membership := &fakeMembership{}
	_, _, ok := handleTypingSignal(context.Background(), membership, "alice", []byte(`not json`))
	if ok {
		t.Fatal("expected ok=false for malformed JSON")
	}
}

func TestHandleTypingSignal_UnknownType(t *testing.T) {
	membership := &fakeMembership{members: map[string][]string{"room-1": {"alice", "bob"}}}
	_, _, ok := handleTypingSignal(context.Background(), membership, "alice",
		[]byte(`{"type":"message.created","payload":{"roomId":"room-1"}}`))
	if ok {
		t.Fatal("expected ok=false for a type other than typing.start/typing.stop")
	}
}

func TestHandleTypingSignal_MissingRoomID(t *testing.T) {
	membership := &fakeMembership{}
	_, _, ok := handleTypingSignal(context.Background(), membership, "alice",
		[]byte(`{"type":"typing.start","payload":{}}`))
	if ok {
		t.Fatal("expected ok=false for an empty roomId")
	}
}

func TestHandleTypingSignal_SenderNotAMember(t *testing.T) {
	membership := &fakeMembership{members: map[string][]string{
		"room-1": {"bob", "carol"}, // alice isn't in this room
	}}
	_, _, ok := handleTypingSignal(context.Background(), membership, "alice",
		[]byte(`{"type":"typing.start","payload":{"roomId":"room-1"}}`))
	if ok {
		t.Fatal("expected ok=false: a client can't signal typing for a room it isn't a member of")
	}
}

func TestHandleTypingSignal_MembershipLookupError(t *testing.T) {
	membership := &fakeMembership{err: errors.New("db unavailable")}
	_, _, ok := handleTypingSignal(context.Background(), membership, "alice",
		[]byte(`{"type":"typing.start","payload":{"roomId":"room-1"}}`))
	if ok {
		t.Fatal("expected ok=false when the membership lookup fails")
	}
}
