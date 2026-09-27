//go:build integration

// Run with both DATABASE_URL and the S3_* vars set — the docker-compose
// stack's postgres/minio services work:
// DATABASE_URL=postgres://... S3_ENDPOINT=localhost:9000 S3_ACCESS_KEY=roost S3_SECRET_KEY=roost-dev-password \
//   go test -tags=integration ./internal/api/...
package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"roost/server/internal/models"
	"roost/server/internal/session"
	"roost/server/internal/ws"
)

// fakeStaticMapFetcher records every call so a test can assert the real
// bug this whole feature guards against — never re-fetching (and re-
// billing) a snapshot that already exists — and lets a test force a
// not-configured/failed fetch without hitting Google's real API.
type fakeStaticMapFetcher struct {
	mu    sync.Mutex
	calls []fakeStaticMapCall
	err   error
}

type fakeStaticMapCall struct {
	lat, lng float64
}

func (f *fakeStaticMapFetcher) Fetch(_ context.Context, lat, lng float64) ([]byte, string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls = append(f.calls, fakeStaticMapCall{lat, lng})
	if f.err != nil {
		return nil, "", f.err
	}
	return []byte("fake-png-bytes"), "image/png", nil
}

func (f *fakeStaticMapFetcher) callCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.calls)
}

func TestHandleLocationSnapshot_FetchesStoresAndIsIdempotent(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	fetcher := &fakeStaticMapFetcher{}
	s.StaticMap = fetcher
	ctx := context.Background()
	run := time.Now().UnixNano()

	sender, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("snapshot-sender-%d@github", run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	other, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("snapshot-other-%d@github", run), "Other")
	if err != nil {
		t.Fatalf("create other member: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, false, []string{sender.ID, other.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.Store.CreateLocationMessage(ctx, room.ID, sender.ID, 52.5, 13.4, time.Minute)
	if err != nil {
		t.Fatalf("create location message: %v", err)
	}
	if _, err := s.Store.EndLocationShare(ctx, msg.ID); err != nil {
		t.Fatalf("end location share: %v", err)
	}

	call := func(user models.User) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodPost, "/api/messages/"+msg.ID+"/location/snapshot", nil)
		req = req.WithContext(session.WithUser(req.Context(), user))
		req = withURLParam(req, "messageID", msg.ID)
		rec := httptest.NewRecorder()
		s.handleLocationSnapshot(rec, req)
		return rec
	}

	// First call: the sender views their own ended share — this is the one
	// that actually fetches and stores the snapshot.
	rec := call(sender)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d: %s", rec.Code, rec.Body.String())
	}
	var got struct {
		Location struct {
			SnapshotMediaID *string `json:"snapshotMediaId"`
		} `json:"location"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if got.Location.SnapshotMediaID == nil {
		t.Fatal("expected snapshotMediaId to be set after the first call")
	}
	if fetcher.callCount() != 1 {
		t.Fatalf("expected exactly 1 fetch, got %d", fetcher.callCount())
	}
	firstMediaID := *got.Location.SnapshotMediaID

	// Second call, by the OTHER room member (not the sender) — this must
	// reuse the already-stored snapshot rather than fetching (and billing)
	// it again. This is the actual regression case: an idle re-fetch here
	// would silently multiply Static Maps API cost by however many room
	// members ever open the chat.
	rec = call(other)
	if rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for the second (non-sender) call, got %d: %s", rec.Code, rec.Body.String())
	}
	got = struct {
		Location struct {
			SnapshotMediaID *string `json:"snapshotMediaId"`
		} `json:"location"`
	}{}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("decode second response: %v", err)
	}
	if got.Location.SnapshotMediaID == nil || *got.Location.SnapshotMediaID != firstMediaID {
		t.Fatalf("expected the same snapshotMediaId reused, got %+v (want %s)", got.Location.SnapshotMediaID, firstMediaID)
	}
	if fetcher.callCount() != 1 {
		t.Fatalf("expected still exactly 1 fetch after the second call, got %d", fetcher.callCount())
	}
}

func TestHandleLocationSnapshot_RejectsAnActiveShare(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	fetcher := &fakeStaticMapFetcher{}
	s.StaticMap = fetcher
	ctx := context.Background()
	run := time.Now().UnixNano()

	sender, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("snapshot-active-sender-%d@github", run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, false, []string{sender.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.Store.CreateLocationMessage(ctx, room.ID, sender.ID, 52.5, 13.4, time.Hour)
	if err != nil {
		t.Fatalf("create location message: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/messages/"+msg.ID+"/location/snapshot", nil)
	req = req.WithContext(session.WithUser(req.Context(), sender))
	req = withURLParam(req, "messageID", msg.ID)
	rec := httptest.NewRecorder()
	s.handleLocationSnapshot(rec, req)

	if rec.Code != http.StatusConflict {
		t.Fatalf("expected 409 for a still-active share, got %d: %s", rec.Code, rec.Body.String())
	}
	if fetcher.callCount() != 0 {
		t.Fatalf("expected no fetch for a still-active share, got %d", fetcher.callCount())
	}
}

func TestHandleLocationSnapshot_RequiresRoomMembership(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	fetcher := &fakeStaticMapFetcher{}
	s.StaticMap = fetcher
	ctx := context.Background()
	run := time.Now().UnixNano()

	sender, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("snapshot-member-sender-%d@github", run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	outsider, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("snapshot-outsider-%d@github", run), "Outsider")
	if err != nil {
		t.Fatalf("create outsider: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, false, []string{sender.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.Store.CreateLocationMessage(ctx, room.ID, sender.ID, 52.5, 13.4, time.Minute)
	if err != nil {
		t.Fatalf("create location message: %v", err)
	}
	if _, err := s.Store.EndLocationShare(ctx, msg.ID); err != nil {
		t.Fatalf("end location share: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/messages/"+msg.ID+"/location/snapshot", nil)
	req = req.WithContext(session.WithUser(req.Context(), outsider))
	req = withURLParam(req, "messageID", msg.ID)
	rec := httptest.NewRecorder()
	s.handleLocationSnapshot(rec, req)

	if rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a non-member, got %d: %s", rec.Code, rec.Body.String())
	}
	if fetcher.callCount() != 0 {
		t.Fatalf("expected no fetch for a non-member, got %d", fetcher.callCount())
	}
}

func TestHandleLocationSnapshot_PropagatesFetchFailureWithoutStoringAnything(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	fetcher := &fakeStaticMapFetcher{err: errors.New("staticmap: no API key configured")}
	s.StaticMap = fetcher
	ctx := context.Background()
	run := time.Now().UnixNano()

	sender, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("snapshot-fail-sender-%d@github", run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, false, []string{sender.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.Store.CreateLocationMessage(ctx, room.ID, sender.ID, 52.5, 13.4, time.Minute)
	if err != nil {
		t.Fatalf("create location message: %v", err)
	}
	if _, err := s.Store.EndLocationShare(ctx, msg.ID); err != nil {
		t.Fatalf("end location share: %v", err)
	}

	req := httptest.NewRequest(http.MethodPost, "/api/messages/"+msg.ID+"/location/snapshot", nil)
	req = req.WithContext(session.WithUser(req.Context(), sender))
	req = withURLParam(req, "messageID", msg.ID)
	rec := httptest.NewRecorder()
	s.handleLocationSnapshot(rec, req)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected 503 when the fetch fails, got %d: %s", rec.Code, rec.Body.String())
	}

	share, err := s.Store.GetLocationShare(ctx, msg.ID)
	if err != nil {
		t.Fatalf("get location share: %v", err)
	}
	if share.SnapshotMediaID != nil {
		t.Fatal("expected no snapshotMediaId recorded after a failed fetch")
	}
}

// TestHandleGetMedia_LocationSnapshotScopedToRoomMembers is the privacy
// regression case for the fix in handleGetMedia: an ended share's map
// snapshot is attached via location_shares.snapshot_media_id, a different
// column than the ordinary messages.media_id path GetMessageByMediaID
// checks — without GetMessageByLocationSnapshotMediaID's fallback, this
// would fall through to the same "open to any authenticated user" branch
// an avatar uses, exposing a real past location instance-wide instead of
// scoping it to the room it was shared in.
func TestHandleGetMedia_LocationSnapshotScopedToRoomMembers(t *testing.T) {
	s := newAPITestServer(t)
	s.Hub = ws.NewHub()
	fetcher := &fakeStaticMapFetcher{}
	s.StaticMap = fetcher
	ctx := context.Background()
	run := time.Now().UnixNano()

	sender, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("snapshot-scope-sender-%d@github", run), "Sender")
	if err != nil {
		t.Fatalf("create sender: %v", err)
	}
	outsider, err := s.Store.GetOrCreateUserByTailscaleID(ctx, fmt.Sprintf("snapshot-scope-outsider-%d@github", run), "Outsider")
	if err != nil {
		t.Fatalf("create outsider: %v", err)
	}
	room, err := s.Store.CreateRoom(ctx, sender.ID, nil, false, []string{sender.ID})
	if err != nil {
		t.Fatalf("create room: %v", err)
	}
	msg, err := s.Store.CreateLocationMessage(ctx, room.ID, sender.ID, 52.5, 13.4, time.Minute)
	if err != nil {
		t.Fatalf("create location message: %v", err)
	}
	if _, err := s.Store.EndLocationShare(ctx, msg.ID); err != nil {
		t.Fatalf("end location share: %v", err)
	}

	snapReq := httptest.NewRequest(http.MethodPost, "/api/messages/"+msg.ID+"/location/snapshot", nil)
	snapReq = snapReq.WithContext(session.WithUser(snapReq.Context(), sender))
	snapReq = withURLParam(snapReq, "messageID", msg.ID)
	snapRec := httptest.NewRecorder()
	s.handleLocationSnapshot(snapRec, snapReq)
	if snapRec.Code != http.StatusOK {
		t.Fatalf("expected 200 generating the snapshot, got %d: %s", snapRec.Code, snapRec.Body.String())
	}
	var created struct {
		Location struct {
			SnapshotMediaID *string `json:"snapshotMediaId"`
		} `json:"location"`
	}
	if err := json.Unmarshal(snapRec.Body.Bytes(), &created); err != nil {
		t.Fatalf("decode snapshot response: %v", err)
	}
	if created.Location.SnapshotMediaID == nil {
		t.Fatal("expected a snapshotMediaId")
	}
	mediaID := *created.Location.SnapshotMediaID

	getMedia := func(user models.User) *httptest.ResponseRecorder {
		req := httptest.NewRequest(http.MethodGet, "/api/media/"+mediaID, nil)
		req = req.WithContext(session.WithUser(req.Context(), user))
		req = withURLParam(req, "mediaID", mediaID)
		rec := httptest.NewRecorder()
		s.handleGetMedia(rec, req)
		return rec
	}

	if rec := getMedia(outsider); rec.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for a non-member fetching the snapshot, got %d: %s", rec.Code, rec.Body.String())
	}
	if rec := getMedia(sender); rec.Code != http.StatusOK {
		t.Fatalf("expected 200 for the room member fetching the snapshot, got %d: %s", rec.Code, rec.Body.String())
	}
}
