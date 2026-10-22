package auth

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"

	"tailscale.com/client/tailscale/apitype"
	"tailscale.com/tailcfg"
)

func TestIdentityFromWhoIs(t *testing.T) {
	user := &tailcfg.UserProfile{LoginName: "alice@github", DisplayName: "Alice"}
	cases := []struct {
		name    string
		who     *apitype.WhoIsResponse
		tag     string
		want    Identity
		wantErr bool
	}{
		{
			name: "user-owned device",
			who:  &apitype.WhoIsResponse{Node: &tailcfg.Node{}, UserProfile: user},
			tag:  "tag:roost-alerts",
			want: Identity{LoginName: "alice@github", DisplayName: "Alice"},
		},
		{
			name: "alert bridge node",
			who: &apitype.WhoIsResponse{
				Node:        &tailcfg.Node{Tags: []string{"tag:roost-alerts"}},
				UserProfile: &tailcfg.UserProfile{LoginName: "tagged-devices"},
			},
			tag:  "tag:roost-alerts",
			want: Identity{LoginName: "tag:roost-alerts", DisplayName: AlertDisplayName, Bot: true},
		},
		{
			name: "alert tag among several tags",
			who: &apitype.WhoIsResponse{
				Node:        &tailcfg.Node{Tags: []string{"tag:other", "tag:roost-alerts"}},
				UserProfile: &tailcfg.UserProfile{LoginName: "tagged-devices"},
			},
			tag:  "tag:roost-alerts",
			want: Identity{LoginName: "tag:roost-alerts", DisplayName: AlertDisplayName, Bot: true},
		},
		{
			name: "some other tagged node is refused, not merged into tagged-devices",
			who: &apitype.WhoIsResponse{
				Node:        &tailcfg.Node{Tags: []string{"tag:server"}},
				UserProfile: &tailcfg.UserProfile{LoginName: "tagged-devices"},
			},
			tag:     "tag:roost-alerts",
			wantErr: true,
		},
		{
			name: "alert identity disabled when no tag is configured",
			who: &apitype.WhoIsResponse{
				Node:        &tailcfg.Node{Tags: []string{"tag:roost-alerts"}},
				UserProfile: &tailcfg.UserProfile{LoginName: "tagged-devices"},
			},
			tag:     "",
			wantErr: true,
		},
		{
			name:    "no user profile",
			who:     &apitype.WhoIsResponse{Node: &tailcfg.Node{}},
			tag:     "tag:roost-alerts",
			wantErr: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := identityFromWhoIs(tc.who, tc.tag)
			if tc.wantErr {
				if !errors.Is(err, ErrUnknownIdentity) {
					t.Fatalf("expected ErrUnknownIdentity, got %v", err)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("got %+v, want %+v", got, tc.want)
			}
		})
	}
}

func statusFor(t *testing.T, mw func(http.Handler) http.Handler, identity Identity) int {
	t.Helper()
	handler := Middleware(fakeResolver{identity: identity})(mw(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})))
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/", nil))
	return rec.Code
}

func TestDenyBots(t *testing.T) {
	if got := statusFor(t, DenyBots, Identity{LoginName: "alice@github"}); got != http.StatusNoContent {
		t.Errorf("family member: got %d, want 204", got)
	}
	if got := statusFor(t, DenyBots, Identity{LoginName: "tag:roost-alerts", Bot: true}); got != http.StatusForbidden {
		t.Errorf("alert identity: got %d, want 403", got)
	}
}

func TestRequireBot(t *testing.T) {
	if got := statusFor(t, RequireBot, Identity{LoginName: "tag:roost-alerts", Bot: true}); got != http.StatusNoContent {
		t.Errorf("alert identity: got %d, want 204", got)
	}
	if got := statusFor(t, RequireBot, Identity{LoginName: "alice@github"}); got != http.StatusForbidden {
		t.Errorf("family member: got %d, want 403", got)
	}
}

func TestDevResolver_BotHost(t *testing.T) {
	fixed := Identity{LoginName: "dev@localhost", DisplayName: "Dev User"}

	r := DevResolver{Identity: fixed, BotHost: "localhost"}
	got, err := r.WhoIs(context.Background(), "127.0.0.1:5555")
	if err != nil || !got.Bot {
		t.Fatalf("connection from the bot host: got %+v, %v; want bot", got, err)
	}

	got, err = r.WhoIs(context.Background(), "203.0.113.9:5555")
	if err != nil || got != fixed {
		t.Fatalf("connection from elsewhere: got %+v, %v; want fixed dev identity", got, err)
	}

	got, _ = DevResolver{Identity: fixed}.WhoIs(context.Background(), "127.0.0.1:5555")
	if got.Bot {
		t.Fatal("no BotHost configured: must never yield the alert identity")
	}
}
