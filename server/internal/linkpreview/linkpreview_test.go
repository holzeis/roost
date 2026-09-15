package linkpreview

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"roost/server/internal/models"
)

func TestFetch_ParsesOpenGraphTags(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(`<!doctype html><html><head>
			<meta property="og:title" content="Cabin weekend photos">
			<meta property="og:description" content="Photos from the trip">
			<meta property="og:image" content="/img/cabin.jpg">
			<meta property="og:site_name" content="Example">
			</head><body><h1>ignored</h1></body></html>`))
	}))
	defer srv.Close()

	preview, err := fetchFromTestServer(t, srv.URL)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if preview.Title != "Cabin weekend photos" {
		t.Fatalf("expected og:title, got %q", preview.Title)
	}
	if preview.Description != "Photos from the trip" {
		t.Fatalf("expected og:description, got %q", preview.Description)
	}
	if preview.SiteName != "Example" {
		t.Fatalf("expected og:site_name, got %q", preview.SiteName)
	}
	if !strings.HasSuffix(preview.ImageURL, "/img/cabin.jpg") {
		t.Fatalf("expected a resolved absolute image url, got %q", preview.ImageURL)
	}
}

func TestFetch_FallsBackToTitleTag(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(`<html><head><title>Plain page title</title></head><body></body></html>`))
	}))
	defer srv.Close()

	preview, err := fetchFromTestServer(t, srv.URL)
	if err != nil {
		t.Fatalf("fetch: %v", err)
	}
	if preview.Title != "Plain page title" {
		t.Fatalf("expected <title> fallback, got %q", preview.Title)
	}
}

func TestFetch_NoTitleIsNotAPreview(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html")
		_, _ = w.Write([]byte(`<html><head></head><body>nothing here</body></html>`))
	}))
	defer srv.Close()

	if _, err := fetchFromTestServer(t, srv.URL); err == nil {
		t.Fatal("expected an error for a page with no title/og:title")
	}
}

func TestFetch_RejectsNonHTTPScheme(t *testing.T) {
	if _, err := Fetch(context.Background(), "file:///etc/passwd"); err == nil {
		t.Fatal("expected file:// URLs to be rejected")
	}
}

func TestFetch_RejectsLoopbackAndPrivateAddresses(t *testing.T) {
	// Exercises the real Fetch (not the test-only dialer override), so this
	// is the actual SSRF guard: a family member pasting a link that points
	// at the cluster's own Postgres/MinIO (or localhost) must not connect.
	for _, target := range []string{
		"http://127.0.0.1:5432/",
		"http://localhost/",
		"http://169.254.169.254/latest/meta-data/", // cloud metadata endpoint
	} {
		if _, err := Fetch(context.Background(), target); err == nil {
			t.Fatalf("expected %s to be rejected as non-public", target)
		}
	}
}

// fetchFromTestServer calls Fetch's parsing logic against an httptest
// server without going through the production SSRF-guarded dialer, which
// would otherwise refuse to connect to 127.0.0.1 — exactly what it's
// supposed to do, but not what these parsing-focused tests want to exercise.
func fetchFromTestServer(t *testing.T, url string) (models.LinkPreview, error) {
	t.Helper()
	original := fetchClient
	fetchClient = &http.Client{Timeout: fetchClient.Timeout}
	t.Cleanup(func() { fetchClient = original })
	return Fetch(context.Background(), url)
}
