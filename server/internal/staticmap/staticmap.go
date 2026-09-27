// Package staticmap fetches a single non-interactive map image for a
// location share once it has ended (FR3.7) — the chat server's third
// outbound-only exception (see docs/architecture-overview.md and
// internal/linkpreview's identical rationale): one HTTPS GET to Google's
// Static Maps API, done server-side so a Google API key never needs to
// reach the client at all. Unlike linkpreview, there's no arbitrary
// user-supplied URL here — only two floats go into the request, and the
// host is always Google's own, fixed at compile time — so the
// private-address-blocking dialer linkpreview needs against SSRF doesn't
// apply here.
package staticmap

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"time"
)

// ErrNotConfigured is returned by Fetch when no API key is set. Callers
// treat this the same as any other fetch failure (see
// handleLocationSnapshot): log it and leave the share without a snapshot,
// never fatal to serving the message itself — the client falls back to its
// own plain-icon placeholder.
var ErrNotConfigured = errors.New("staticmap: no API key configured")

const (
	baseURL = "https://maps.googleapis.com/maps/api/staticmap"
	// Matches the chat bubble's own preview box ratio (see
	// ChatBubbleStyle.mediaMaxWidth / location_message.dart's 220:160
	// comment) — scale=2 renders at 2x pixel density for the same 220x160
	// logical size, crisp on a high-density screen.
	size  = "220x160"
	scale = "2"
	zoom  = "15"
)

var httpClient = &http.Client{Timeout: 5 * time.Second}

// Fetcher is the interface api.Server depends on — kept as an interface
// (like push.Sender) so handleLocationSnapshot is testable with a fake
// rather than hitting Google's real API from a test. GoogleFetcher below is
// the only real implementation.
type Fetcher interface {
	Fetch(ctx context.Context, lat, lng float64) (data []byte, contentType string, err error)
}

// GoogleFetcher holds the API key server-side. The zero value (empty
// apiKey) is safe to use — Fetch just returns ErrNotConfigured — matching
// how push.NoopSender lets FR5.1 degrade gracefully without credentials.
type GoogleFetcher struct {
	apiKey string
}

func NewGoogleFetcher(apiKey string) *GoogleFetcher {
	return &GoogleFetcher{apiKey: apiKey}
}

// Fetch retrieves a static map image centered on lat/lng, returning the raw
// image bytes and the response's Content-Type.
func (f *GoogleFetcher) Fetch(ctx context.Context, lat, lng float64) (data []byte, contentType string, err error) {
	if f.apiKey == "" {
		return nil, "", ErrNotConfigured
	}
	q := url.Values{
		"center":  {fmt.Sprintf("%f,%f", lat, lng)},
		"zoom":    {zoom},
		"size":    {size},
		"scale":   {scale},
		"maptype": {"roadmap"},
		"key":     {f.apiKey},
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, baseURL+"?"+q.Encode(), nil)
	if err != nil {
		return nil, "", fmt.Errorf("staticmap: build request: %w", err)
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, "", fmt.Errorf("staticmap: fetch: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Deliberately not echoing the response body: Google's own error
		// pages for a bad key can include enough of the request back that
		// logging it verbatim risks leaking the key into server logs.
		return nil, "", fmt.Errorf("staticmap: unexpected status %d", resp.StatusCode)
	}
	data, err = io.ReadAll(io.LimitReader(resp.Body, 5<<20))
	if err != nil {
		return nil, "", fmt.Errorf("staticmap: read body: %w", err)
	}
	contentType = resp.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "image/png"
	}
	return data, contentType, nil
}
