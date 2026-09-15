// Package linkpreview fetches Open Graph metadata for a URL shared in chat
// (FR1.14). This is the chat server's second outbound-only exception to
// "no open ports" (see docs/architecture-overview.md) — it makes one HTTPS
// GET to the linked site and reads back <meta property="og:..."> tags, the
// same way link previews work in any chat app. Nothing external ever
// initiates a connection to us for this.
package linkpreview

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"

	"golang.org/x/net/html"

	"roost/server/internal/models"
)

// maxBodyBytes caps how much of the response we read — Open Graph tags live
// in <head>, so a few hundred KiB is generous and keeps a slow/huge page
// from tying up the fetch.
const maxBodyBytes = 512 << 10

// fetchClient uses a dialer that refuses to connect to private/loopback/
// link-local addresses (and re-checks on every redirect hop). Without this,
// "fetch whatever URL a family member pastes" is a server-side-request-
// forgery vector into the cluster-internal network (Postgres, MinIO, etc.)
// that never faces the tailnet directly.
var fetchClient = &http.Client{
	Timeout: 5 * time.Second,
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 5 {
			return fmt.Errorf("linkpreview: too many redirects")
		}
		return nil
	},
	Transport: &http.Transport{
		DialContext: safeDialContext,
	},
}

func safeDialContext(ctx context.Context, network, addr string) (net.Conn, error) {
	host, port, err := net.SplitHostPort(addr)
	if err != nil {
		return nil, err
	}
	ips, err := net.DefaultResolver.LookupIP(ctx, "ip", host)
	if err != nil {
		return nil, err
	}
	var dialErr error
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	for _, ip := range ips {
		if !isPubliclyRoutable(ip) {
			dialErr = fmt.Errorf("linkpreview: refusing to fetch non-public address %s", ip)
			continue
		}
		conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
		if err == nil {
			return conn, nil
		}
		dialErr = err
	}
	if dialErr == nil {
		dialErr = errors.New("linkpreview: no addresses to dial")
	}
	return nil, dialErr
}

func isPubliclyRoutable(ip net.IP) bool {
	if ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() {
		return false
	}
	return true
}

// Fetch retrieves and parses Open Graph metadata for rawURL. It only
// accepts http(s) URLs and never follows a redirect to a non-http(s) scheme.
func Fetch(ctx context.Context, rawURL string) (models.LinkPreview, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return models.LinkPreview{}, fmt.Errorf("linkpreview: invalid url")
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, parsed.String(), nil)
	if err != nil {
		return models.LinkPreview{}, fmt.Errorf("linkpreview: build request: %w", err)
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (compatible; RoostLinkPreview/1.0)")
	req.Header.Set("Accept", "text/html")

	resp, err := fetchClient.Do(req)
	if err != nil {
		return models.LinkPreview{}, fmt.Errorf("linkpreview: fetch: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return models.LinkPreview{}, fmt.Errorf("linkpreview: fetch returned %d", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); ct != "" && !strings.Contains(ct, "html") {
		return models.LinkPreview{}, fmt.Errorf("linkpreview: not html (%s)", ct)
	}

	body := io.LimitReader(resp.Body, maxBodyBytes)
	preview := parseOpenGraph(body, parsed)
	preview.URL = rawURL
	if preview.Title == "" {
		// No og:title — not worth showing a card with nothing in it.
		return models.LinkPreview{}, fmt.Errorf("linkpreview: no title found")
	}
	return preview, nil
}

func parseOpenGraph(body io.Reader, pageURL *url.URL) models.LinkPreview {
	var preview models.LinkPreview
	tokenizer := html.NewTokenizer(body)
	inHead := false

	for {
		tokenType := tokenizer.Next()
		switch tokenType {
		case html.ErrorToken:
			return preview
		case html.StartTagToken, html.SelfClosingTagToken:
			tag, _ := tokenizer.TagName()
			name := string(tag)
			switch name {
			case "head":
				inHead = true
			case "body":
				return preview // Open Graph tags only ever live in <head>.
			case "meta":
				applyMetaTag(tokenizer, pageURL, &preview)
			case "title":
				if inHead && preview.Title == "" {
					if tokenizer.Next() == html.TextToken {
						preview.Title = strings.TrimSpace(string(tokenizer.Text()))
					}
				}
			}
		case html.EndTagToken:
			tag, _ := tokenizer.TagName()
			if string(tag) == "head" {
				return preview
			}
		}
	}
}

func applyMetaTag(tokenizer *html.Tokenizer, pageURL *url.URL, preview *models.LinkPreview) {
	var property, content string
	for {
		key, val, more := tokenizer.TagAttr()
		switch string(key) {
		case "property", "name":
			property = string(val)
		case "content":
			content = string(val)
		}
		if !more {
			break
		}
	}
	content = strings.TrimSpace(content)
	if content == "" {
		return
	}
	switch property {
	case "og:title":
		preview.Title = content
	case "og:description", "description":
		if preview.Description == "" {
			preview.Description = content
		}
	case "og:image", "og:image:url":
		preview.ImageURL = resolveURL(pageURL, content)
	case "og:site_name":
		preview.SiteName = content
	}
}

func resolveURL(base *url.URL, ref string) string {
	parsed, err := url.Parse(ref)
	if err != nil {
		return ref
	}
	return base.ResolveReference(parsed).String()
}
