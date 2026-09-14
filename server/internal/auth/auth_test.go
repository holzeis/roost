package auth

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

type fakeResolver struct {
	identity Identity
	err      error
}

func (f fakeResolver) WhoIs(ctx context.Context, remoteAddr string) (Identity, error) {
	return f.identity, f.err
}

func TestMiddleware_AttachesIdentity(t *testing.T) {
	resolver := fakeResolver{identity: Identity{LoginName: "alice@github", DisplayName: "Alice"}}
	var got Identity
	var ok bool

	handler := Middleware(resolver)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got, ok = FromContext(r.Context())
		w.WriteHeader(http.StatusOK)
	}))

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "100.64.0.1:12345"
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", rec.Code)
	}
	if !ok {
		t.Fatal("expected identity to be attached to context")
	}
	if got.LoginName != "alice@github" {
		t.Fatalf("expected login name alice@github, got %q", got.LoginName)
	}
}

func TestMiddleware_RejectsUnresolvedIdentity(t *testing.T) {
	resolver := fakeResolver{err: errors.New("no such node")}
	handler := Middleware(resolver)(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Fatal("handler should not be called when identity resolution fails")
	}))

	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rec.Code)
	}
}
