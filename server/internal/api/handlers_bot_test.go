package api

import (
	"net/http"
	"net/http/httptest"
	"testing"

	"roost/server/internal/models"
	"roost/server/internal/session"
)

// A bot that already has an avatar must be left alone: the bridge offers its
// picture on every start, and this branch must answer before touching the
// store or object storage (the zero-value Server here has neither).
func TestHandleBotAvatar_AlreadySetIsANoOp(t *testing.T) {
	existing := "11111111-1111-1111-1111-111111111111"
	bot := models.User{ID: "bot", DisplayName: "Alerts", AvatarMediaID: &existing}

	req := httptest.NewRequest(http.MethodPost, "/bot/avatar", nil)
	req = req.WithContext(session.WithUser(req.Context(), bot))
	rec := httptest.NewRecorder()

	(&Server{}).handleBotAvatar(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf("expected 204, got %d: %s", rec.Code, rec.Body.String())
	}
}

func TestHandleBotAvatar_NoUserInContextIsForbidden(t *testing.T) {
	rec := httptest.NewRecorder()
	(&Server{}).handleBotAvatar(rec, httptest.NewRequest(http.MethodPost, "/bot/avatar", nil))
	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", rec.Code)
	}
}
