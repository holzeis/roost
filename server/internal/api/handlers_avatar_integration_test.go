//go:build integration

// Run with both DATABASE_URL and the S3_* vars set — the docker-compose
// stack's postgres/minio services work:
// DATABASE_URL=postgres://... S3_ENDPOINT=localhost:9000 S3_ACCESS_KEY=roost S3_SECRET_KEY=roost-dev-password \
//   go test -tags=integration ./internal/api/...
package api

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"github.com/go-chi/chi/v5"

	"roost/server/internal/db"
	"roost/server/internal/models"
	"roost/server/internal/session"
	"roost/server/internal/storage"
	"roost/server/internal/store"
)

// newAPITestServer builds a Server backed by real Postgres and MinIO
// connections (shared by every *_integration_test.go file in this
// package) — skips instead of failing when either isn't configured, same
// as the store/storage packages' own integration test helpers.
func newAPITestServer(t *testing.T) *Server {
	t.Helper()
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		t.Skip("DATABASE_URL not set; skipping integration test")
	}
	s3Endpoint := os.Getenv("S3_ENDPOINT")
	if s3Endpoint == "" {
		t.Skip("S3_ENDPOINT not set; skipping integration test")
	}

	if err := db.Migrate(dbURL); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	pool, err := db.Connect(context.Background(), dbURL)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(pool.Close)

	media, err := storage.New(
		context.Background(),
		s3Endpoint,
		os.Getenv("S3_ACCESS_KEY"),
		os.Getenv("S3_SECRET_KEY"),
		fmt.Sprintf("roost-media-test-%d", time.Now().UnixNano()),
		os.Getenv("S3_USE_SSL") == "true",
	)
	if err != nil {
		t.Fatalf("new media store: %v", err)
	}

	return &Server{Store: store.New(pool), Media: media}
}

// multipartAvatarBody builds a POST body with the same shape the client
// sends: a single "file" form field.
func multipartAvatarBody(t *testing.T, filename string, content []byte) (*bytes.Buffer, string) {
	t.Helper()
	body := &bytes.Buffer{}
	w := multipart.NewWriter(body)
	part, err := w.CreateFormFile("file", filename)
	if err != nil {
		t.Fatalf("create form file: %v", err)
	}
	if _, err := part.Write(content); err != nil {
		t.Fatalf("write form file: %v", err)
	}
	if err := w.Close(); err != nil {
		t.Fatalf("close multipart writer: %v", err)
	}
	return body, w.FormDataContentType()
}

func withURLParam(r *http.Request, key, value string) *http.Request {
	rctx := chi.NewRouteContext()
	rctx.URLParams.Add(key, value)
	return r.WithContext(context.WithValue(r.Context(), chi.RouteCtxKey, rctx))
}

// TestHandleUploadAvatar_SetsAvatarWithoutCreatingAMessageOrTouchingDisplayName
// is the behavioral contract that motivated this handler's own existence
// instead of reusing handleUploadMedia: a profile picture upload must not
// create a chat message (handleUploadMedia's room-scoped side effect) and
// must not require or overwrite the caller's display name (UpdateUserProfile
// sets both columns unconditionally, so the handler has to supply the
// existing name back to it).
func TestHandleUploadAvatar_SetsAvatarWithoutCreatingAMessageOrTouchingDisplayName(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("avatar-test-%d@github", run), "Original Name")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	body, contentType := multipartAvatarBody(t, "avatar.png", []byte("not a real png, just test bytes"))
	req := httptest.NewRequest(http.MethodPost, "/api/me/avatar", body)
	req.Header.Set("Content-Type", contentType)
	req = req.WithContext(session.WithUser(req.Context(), user))
	rec := httptest.NewRecorder()

	s.handleUploadAvatar(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var updated models.User
	if err := json.Unmarshal(rec.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if updated.AvatarMediaID == nil {
		t.Fatal("expected avatarMediaId to be set")
	}
	if updated.DisplayName != "Original Name" {
		t.Fatalf("expected display name to be left alone, got %q", updated.DisplayName)
	}

	// The key behavioral difference from handleUploadMedia: no message was
	// created for this media object.
	if _, err := s.Store.GetMessageByMediaID(ctx, *updated.AvatarMediaID); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("expected no message to reference the avatar media, got err=%v", err)
	}

	// handleGetMedia must still be able to serve it — with no owning
	// message, the ordinary room-membership check can't apply.
	getReq := httptest.NewRequest(http.MethodGet, "/api/media/"+*updated.AvatarMediaID, nil)
	getReq = getReq.WithContext(session.WithUser(getReq.Context(), user))
	getReq = withURLParam(getReq, "mediaID", *updated.AvatarMediaID)
	getRec := httptest.NewRecorder()

	s.handleGetMedia(getRec, getReq)

	if getRec.Code != http.StatusOK {
		t.Fatalf("expected 200 fetching the avatar, got %d: %s", getRec.Code, getRec.Body.String())
	}
}

// TestHandleUploadAvatar_GeneratesAPreview: an avatar is shown small
// everywhere it appears (InitialAvatar/profile_screen.dart), so it gets the
// same faster-loading preview as a chat photo — see storeMediaWithPreview.
func TestHandleUploadAvatar_GeneratesAPreview(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("avatar-preview-test-%d@github", run), "Photogenic")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}

	original := testJPEG(t, 200, 200)
	body, contentType := multipartAvatarBody(t, "avatar.jpg", original)
	req := httptest.NewRequest(http.MethodPost, "/api/me/avatar", body)
	req.Header.Set("Content-Type", contentType)
	req = req.WithContext(session.WithUser(req.Context(), user))
	rec := httptest.NewRecorder()

	s.handleUploadAvatar(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var updated models.User
	if err := json.Unmarshal(rec.Body.Bytes(), &updated); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	getPreview := httptest.NewRequest(http.MethodGet, "/api/media/"+*updated.AvatarMediaID+"?variant=preview", nil)
	getPreview = getPreview.WithContext(session.WithUser(getPreview.Context(), user))
	getPreview = withURLParam(getPreview, "mediaID", *updated.AvatarMediaID)
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
