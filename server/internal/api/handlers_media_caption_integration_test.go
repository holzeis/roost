//go:build integration

package api

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"mime/multipart"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"roost/server/internal/models"
	"roost/server/internal/session"
	"roost/server/internal/ws"
)

// multipartMediaBody builds a POST body matching the client's actual
// upload shape: form fields alongside the file, not just the file alone
// (multipartAvatarBody, defined in handlers_avatar_integration_test.go,
// only covers the avatar upload's simpler single-field case).
func multipartMediaBody(t *testing.T, fields map[string]string, filename string, content []byte) (*bytes.Buffer, string) {
	t.Helper()
	body := &bytes.Buffer{}
	w := multipart.NewWriter(body)
	for key, value := range fields {
		if err := w.WriteField(key, value); err != nil {
			t.Fatalf("write field %s: %v", key, err)
		}
	}
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

// TestHandleUploadMedia_AttachesAnOptionalCaption implements FR2.6: a
// caption sent alongside the file becomes the media message's own body,
// the same column a text message's body lives in.
func TestHandleUploadMedia_AttachesAnOptionalCaption(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("caption-test-%d@github", run), "Captioner")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, user.ID, nil, false, []string{user.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	body, contentType := multipartMediaBody(t,
		map[string]string{"kind": "image", "caption": "Weekend trip!"},
		"photo.jpg", []byte("not a real jpg, just test bytes"))
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
	if msg.Body == nil || *msg.Body != "Weekend trip!" {
		t.Fatalf("expected caption %q, got %v", "Weekend trip!", msg.Body)
	}
}

// TestHandleUploadMedia_LeavesBodyUnsetWithoutACaption guards the "optional"
// half of FR2.6 — no caption field sent should behave exactly as before
// this feature existed, not a message with an empty-string caption.
func TestHandleUploadMedia_LeavesBodyUnsetWithoutACaption(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("no-caption-test-%d@github", run), "Plain")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, user.ID, nil, false, []string{user.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	body, contentType := multipartMediaBody(t,
		map[string]string{"kind": "image"},
		"photo.jpg", []byte("not a real jpg, just test bytes"))
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
	if msg.Body != nil {
		t.Fatalf("expected no caption, got %q", *msg.Body)
	}
}
