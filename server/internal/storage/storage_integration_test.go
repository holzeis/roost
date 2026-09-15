//go:build integration

// Run with S3_ENDPOINT etc. set — the docker-compose stack's minio service
// works: S3_ENDPOINT=localhost:9000 S3_ACCESS_KEY=roost S3_SECRET_KEY=roost-dev-password
// go test -tags=integration ./internal/storage/...
package storage

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"testing"
	"time"
)

func newTestStore(t *testing.T) *Store {
	t.Helper()
	endpoint := os.Getenv("S3_ENDPOINT")
	if endpoint == "" {
		t.Skip("S3_ENDPOINT not set; skipping storage integration test")
	}
	s, err := New(
		context.Background(),
		endpoint,
		os.Getenv("S3_ACCESS_KEY"),
		os.Getenv("S3_SECRET_KEY"),
		fmt.Sprintf("roost-media-test-%d", time.Now().UnixNano()),
		os.Getenv("S3_USE_SSL") == "true",
	)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	return s
}

func TestStore_PutGetDelete(t *testing.T) {
	s := newTestStore(t)
	ctx := context.Background()

	key := "test/hello.txt"
	content := []byte("hello from the integration test")

	if err := s.Put(ctx, key, bytes.NewReader(content), int64(len(content)), "text/plain"); err != nil {
		t.Fatalf("put: %v", err)
	}

	reader, err := s.Get(ctx, key)
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	got, err := io.ReadAll(reader)
	reader.Close()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if !bytes.Equal(got, content) {
		t.Fatalf("expected %q, got %q", content, got)
	}

	if err := s.Delete(ctx, key); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if _, err := s.Get(ctx, key); err == nil {
		t.Fatal("expected an error fetching a deleted object, got nil")
	}
}
