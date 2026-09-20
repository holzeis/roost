//go:build integration

package api

import (
	"bytes"
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"roost/server/internal/session"
)

// TestHandleGetMedia_ServesPartialContentForARangeRequest guards against the
// bug that motivated storage.GetRange and handleGetMedia's Range handling in
// the first place: without it, a video never starts playing at all, since
// video_player's AVPlayer backend seeks via Range requests before it can
// even begin, and a server that ignores Range and always returns the whole
// object from byte 0 leaves that seek unsatisfied.
func TestHandleGetMedia_ServesPartialContentForARangeRequest(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("range-test-%d@github", run), "Ranger")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, user.ID, nil, false, []string{user.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	content := []byte("0123456789abcdefghij") // 20 bytes
	objectKey := fmt.Sprintf("test/%d.bin", run)
	if err := s.Media.Put(ctx, objectKey, bytes.NewReader(content), int64(len(content)), "video/mp4"); err != nil {
		t.Fatalf("put object: %v", err)
	}
	mediaObj, err := s.Store.CreateMediaObject(ctx, s.Media.Bucket(), objectKey, "video/mp4", int64(len(content)), user.ID)
	if err != nil {
		t.Fatalf("create media object: %v", err)
	}
	if _, err := s.Store.CreateMediaMessage(ctx, room.ID, user.ID, "video", mediaObj.ID, nil, false); err != nil {
		t.Fatalf("create media message: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/media/"+mediaObj.ID, nil)
	req.Header.Set("Range", "bytes=5-9")
	req = req.WithContext(session.WithUser(req.Context(), user))
	req = withURLParam(req, "mediaID", mediaObj.ID)
	rec := httptest.NewRecorder()

	s.handleGetMedia(rec, req)

	if rec.Code != http.StatusPartialContent {
		t.Fatalf("expected 206, got %d: %s", rec.Code, rec.Body.String())
	}
	if got, want := rec.Header().Get("Content-Range"), "bytes 5-9/20"; got != want {
		t.Fatalf("Content-Range = %q, want %q", got, want)
	}
	if got, want := rec.Header().Get("Accept-Ranges"), "bytes"; got != want {
		t.Fatalf("Accept-Ranges = %q, want %q", got, want)
	}
	if got, want := rec.Body.String(), "56789"; got != want {
		t.Fatalf("body = %q, want %q", got, want)
	}
}

func TestHandleGetMedia_RejectsAnUnsatisfiableRange(t *testing.T) {
	s := newAPITestServer(t)
	ctx := context.Background()
	run := time.Now().UnixNano()

	user, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("range-test-bad-%d@github", run), "Ranger")
	if err != nil {
		t.Fatalf("create user: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, user.ID, nil, false, []string{user.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}

	content := []byte("short")
	objectKey := fmt.Sprintf("test/%d-bad.bin", run)
	if err := s.Media.Put(ctx, objectKey, bytes.NewReader(content), int64(len(content)), "video/mp4"); err != nil {
		t.Fatalf("put object: %v", err)
	}
	mediaObj, err := s.Store.CreateMediaObject(ctx, s.Media.Bucket(), objectKey, "video/mp4", int64(len(content)), user.ID)
	if err != nil {
		t.Fatalf("create media object: %v", err)
	}
	if _, err := s.Store.CreateMediaMessage(ctx, room.ID, user.ID, "video", mediaObj.ID, nil, false); err != nil {
		t.Fatalf("create media message: %v", err)
	}

	req := httptest.NewRequest(http.MethodGet, "/api/media/"+mediaObj.ID, nil)
	req.Header.Set("Range", "bytes=1000-2000")
	req = req.WithContext(session.WithUser(req.Context(), user))
	req = withURLParam(req, "mediaID", mediaObj.ID)
	rec := httptest.NewRecorder()

	s.handleGetMedia(rec, req)

	if rec.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("expected 416, got %d: %s", rec.Code, rec.Body.String())
	}
}
