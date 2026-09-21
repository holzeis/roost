//go:build integration

package api

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"roost/server/internal/session"
	"roost/server/internal/ws"
)

// TestHandleListUsers_IncludesAvatarMediaID guards the contactDTO carrying
// a contact's own avatarMediaId — without it, other users could never see
// a contact's profile picture, only ever their own (handleGetMe/handleMe
// already return it for the caller).
func TestHandleListUsers_IncludesAvatarMediaID(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	caller, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("list-users-caller-%d@github", run), "Caller")
	if err != nil {
		t.Fatalf("create caller: %v", err)
	}
	withAvatar, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("list-users-avatar-%d@github", run), "Has Avatar")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	mediaObj, err := s.Store.CreateMediaObject(ctx, s.Media.Bucket(), fmt.Sprintf("avatars/%d.jpg", run), "image/jpeg", 3, withAvatar.ID)
	if err != nil {
		t.Fatalf("create media object: %v", err)
	}
	if _, err := s.Store.UpdateUserProfile(ctx, withAvatar.ID, withAvatar.DisplayName, &mediaObj.ID); err != nil {
		t.Fatalf("set avatar: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/users", nil)
	req = req.WithContext(session.WithUser(req.Context(), caller))
	rec := httptest.NewRecorder()

	s.handleListUsers(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var contacts []contactDTO
	if err := json.Unmarshal(rec.Body.Bytes(), &contacts); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	var found *contactDTO
	for i := range contacts {
		if contacts[i].ID == withAvatar.ID {
			found = &contacts[i]
		}
	}
	if found == nil {
		t.Fatal("expected the avatar-having user to be listed")
	}
	if found.AvatarMediaID == nil || *found.AvatarMediaID != mediaObj.ID {
		t.Fatalf("expected avatarMediaId %q, got %v", mediaObj.ID, found.AvatarMediaID)
	}
}
