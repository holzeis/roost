package ws

import "testing"

type fakeConn struct {
	received []Event
	failNext bool
}

func (f *fakeConn) Send(ev Event) error {
	f.received = append(f.received, ev)
	return nil
}

func TestHub_SendToUser_DeliversToAllDevices(t *testing.T) {
	h := NewHub()
	c1 := &fakeConn{}
	c2 := &fakeConn{}
	h.Register("alice", c1)
	h.Register("alice", c2)

	delivered := h.SendToUser("alice", Event{Type: "message.created"})
	if !delivered {
		t.Fatal("expected delivered=true, alice has live connections")
	}
	if len(c1.received) != 1 || len(c2.received) != 1 {
		t.Fatalf("expected both of alice's connections to receive the event, got c1=%d c2=%d", len(c1.received), len(c2.received))
	}
}

func TestHub_SendToUser_OfflineUser(t *testing.T) {
	h := NewHub()
	delivered := h.SendToUser("bob", Event{Type: "message.created"})
	if delivered {
		t.Fatal("expected delivered=false for a user with no live connections")
	}
}

func TestHub_UnregisterStopsDelivery(t *testing.T) {
	h := NewHub()
	c1 := &fakeConn{}
	h.Register("alice", c1)
	h.Unregister("alice", c1)

	if h.IsOnline("alice") {
		t.Fatal("expected alice to be offline after unregistering her only connection")
	}
	h.SendToUser("alice", Event{Type: "message.created"})
	if len(c1.received) != 0 {
		t.Fatal("expected no delivery after unregister")
	}
}

func TestHub_SendToUsers_FansOutToRoom(t *testing.T) {
	h := NewHub()
	alice := &fakeConn{}
	bob := &fakeConn{}
	h.Register("alice", alice)
	h.Register("bob", bob)

	h.SendToUsers([]string{"alice", "bob", "carol"}, Event{Type: "message.created"})

	if len(alice.received) != 1 || len(bob.received) != 1 {
		t.Fatalf("expected both online room members to receive the event")
	}
}
