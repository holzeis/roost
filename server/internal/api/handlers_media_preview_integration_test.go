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

	"roost/server/internal/models"
	"roost/server/internal/session"
	"roost/server/internal/ws"
)

// TestHandleUploadMedia_CapturesDimensionsAndGeneratesAPreview covers the
// whole point of this feature: the chat bubble gets a smaller, faster
// preview at the same pixel dimensions, and the full-quality original is
// still there, unchanged, for the full-screen viewer.
func TestHandleUploadMedia_CapturesDimensionsAndGeneratesAPreview(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("preview-test-%d@github", run), "Photographer")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, user.ID, nil, false, []string{user.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	original := testJPEG(t, 400, 300)
	body, contentType := multipartMediaBody(t, map[string]string{"kind": "image"}, "photo.jpg", original)
	req := httptest.NewRequest(http.MethodPost, "/api/rooms/"+room.ID+"/media", body)
	req.Header.Set("Content-Type", contentType)
	req = req.WithContext(session.WithUser(req.Context(), user))
	req = withURLParam(req, "roomID", room.ID)
	rec := httptest.NewRecorder()

	s.handleUploadMedia(rec, req)

	if rec.Code != http.StatusCreated {
		t.Fatalf("expected 201, got %d: %s", rec.Code, rec.Body.String())
	}
	var msg models.Message
	if err := json.Unmarshal(rec.Body.Bytes(), &msg); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if msg.Media == nil {
		t.Fatal("expected Media dimensions on the upload response")
	}
	// "Do not reduce the dimensions, just the quality."
	if msg.Media.Width != 400 || msg.Media.Height != 300 {
		t.Fatalf("expected 400x300, got %dx%d", msg.Media.Width, msg.Media.Height)
	}

	// The full-quality original is untouched.
	getOriginal := httptest.NewRequest(http.MethodGet, "/api/media/"+*msg.MediaID, nil)
	getOriginal = getOriginal.WithContext(session.WithUser(getOriginal.Context(), user))
	getOriginal = withURLParam(getOriginal, "mediaID", *msg.MediaID)
	recOriginal := httptest.NewRecorder()
	s.handleGetMedia(recOriginal, getOriginal)
	if recOriginal.Code != http.StatusOK {
		t.Fatalf("expected 200 for the original, got %d", recOriginal.Code)
	}
	if recOriginal.Body.Len() != len(original) {
		t.Fatalf("expected the original's exact byte size (%d), got %d", len(original), recOriginal.Body.Len())
	}

	// The smaller preview variant, for the chat bubble.
	getPreview := httptest.NewRequest(http.MethodGet, "/api/media/"+*msg.MediaID+"?variant=preview", nil)
	getPreview = getPreview.WithContext(session.WithUser(getPreview.Context(), user))
	getPreview = withURLParam(getPreview, "mediaID", *msg.MediaID)
	recPreview := httptest.NewRecorder()
	s.handleGetMedia(recPreview, getPreview)
	if recPreview.Code != http.StatusOK {
		t.Fatalf("expected 200 for the preview, got %d", recPreview.Code)
	}
	if got := recPreview.Header().Get("Content-Type"); got != "image/jpeg" {
		t.Fatalf("expected preview Content-Type image/jpeg, got %q", got)
	}
	if recPreview.Body.Len() >= len(original) {
		t.Fatalf("expected the preview to be smaller than the original (%d bytes), got %d",
			len(original), recPreview.Body.Len())
	}
}

// TestHandleGetMedia_FallsBackToOriginalWithoutAPreview guards messages
// uploaded before this feature existed, and any upload the server
// couldn't decode as an image (WebP/HEIC, or genuinely corrupt bytes) —
// ?variant=preview must never 404 or error just because there's no preview
// to give back; the client always has something to display either way.
func TestHandleGetMedia_FallsBackToOriginalWithoutAPreview(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("no-preview-test-%d@github", run), "Plain")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, user.ID, nil, false, []string{user.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	// Not a real, decodable image — generateImagePreview will skip it.
	original := []byte("not a real jpg, just test bytes")
	body, contentType := multipartMediaBody(t, map[string]string{"kind": "image"}, "photo.jpg", original)
	req := httptest.NewRequest(http.MethodPost, "/api/rooms/"+room.ID+"/media", body)
	req.Header.Set("Content-Type", contentType)
	req = req.WithContext(session.WithUser(req.Context(), user))
	req = withURLParam(req, "roomID", room.ID)
	rec := httptest.NewRecorder()
	s.handleUploadMedia(rec, req)

	var msg models.Message
	if err := json.Unmarshal(rec.Body.Bytes(), &msg); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if msg.Media != nil {
		t.Fatalf("expected no Media dimensions for an undecodable upload, got %+v", msg.Media)
	}

	getPreview := httptest.NewRequest(http.MethodGet, "/api/media/"+*msg.MediaID+"?variant=preview", nil)
	getPreview = getPreview.WithContext(session.WithUser(getPreview.Context(), user))
	getPreview = withURLParam(getPreview, "mediaID", *msg.MediaID)
	recPreview := httptest.NewRecorder()
	s.handleGetMedia(recPreview, getPreview)

	if recPreview.Code != http.StatusOK {
		t.Fatalf("expected 200 (falling back to the original), got %d", recPreview.Code)
	}
	if recPreview.Body.Len() != len(original) {
		t.Fatalf("expected the original's exact bytes as the fallback, got %d bytes", recPreview.Body.Len())
	}
}
