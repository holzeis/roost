// Package alertbridge forwards Prometheus Alertmanager webhooks to Roost's
// Alerts room. It posts as the dedicated alert identity: the bridge runs as
// its own tagged tailnet node, and the chat server recognises that tag (see
// server/internal/auth) — there is no token or other credential to leak.
package alertbridge

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"
)

// Sender delivers one text message to the Alerts room.
type Sender interface {
	Send(ctx context.Context, text string) error
}

// ---- Alertmanager webhook payload ----

type Webhook struct {
	Status string  `json:"status"`
	Alerts []Alert `json:"alerts"`
}

type Alert struct {
	Status      string            `json:"status"`
	Labels      map[string]string `json:"labels"`
	Annotations map[string]string `json:"annotations"`
	StartsAt    string            `json:"startsAt"`
	EndsAt      string            `json:"endsAt"`
}

// FormatAlert renders one alert as chat text, with an emoji by severity.
// Empty summary/description lines are left out rather than printed blank.
func FormatAlert(alert Alert) string {
	name := alert.Labels["alertname"]
	if alert.Status == "resolved" {
		return fmt.Sprintf("✅ Resolved Alert: %s", name)
	}

	emoji := "ℹ️"
	switch alert.Labels["severity"] {
	case "critical":
		emoji = "🚨"
	case "warning":
		emoji = "⚠️"
	}

	parts := []string{emoji + " " + name}
	if summary := strings.TrimSpace(alert.Annotations["summary"]); summary != "" {
		parts = append(parts, summary)
	}
	if description := strings.TrimSpace(alert.Annotations["description"]); description != "" {
		parts = append(parts, description)
	}
	return strings.Join(parts, "\n\n")
}

// ---- HTTP handlers ----

// maxWebhookBytes bounds a webhook body; a large alert group is still far
// below this.
const maxWebhookBytes = 4 << 20

// Handler serves the Alertmanager-facing endpoints.
type Handler struct {
	Sender Sender
}

func (h Handler) Routes() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /alerts", h.alerts)
	mux.HandleFunc("POST /watchdog", h.watchdog)
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})
	return mux
}

// alerts posts each alert as its own message. If any send fails the whole
// request answers 502 so Alertmanager retries the group — a lost alert is
// worse than a duplicate.
func (h Handler) alerts(w http.ResponseWriter, r *http.Request) {
	var webhook Webhook
	r.Body = http.MaxBytesReader(w, r.Body, maxWebhookBytes)
	if err := json.NewDecoder(r.Body).Decode(&webhook); err != nil {
		http.Error(w, "invalid alertmanager payload", http.StatusBadRequest)
		return
	}

	var failed []error
	for _, alert := range webhook.Alerts {
		if err := h.Sender.Send(r.Context(), FormatAlert(alert)); err != nil {
			slog.Error("send alert failed", "alert", alert.Labels["alertname"], "error", err)
			failed = append(failed, err)
		}
	}
	if len(failed) > 0 {
		http.Error(w, fmt.Sprintf("%d of %d alerts could not be delivered", len(failed), len(webhook.Alerts)), http.StatusBadGateway)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// watchdog posts the daily "pipeline is alive" message; Alertmanager routes
// the always-firing Watchdog alert here on a long repeat interval.
func (h Handler) watchdog(w http.ResponseWriter, r *http.Request) {
	if err := h.Sender.Send(r.Context(), "✅ Daily Watchdog: All systems operational!"); err != nil {
		slog.Error("send watchdog failed", "error", err)
		http.Error(w, "failed to send watchdog message", http.StatusBadGateway)
		return
	}
	w.WriteHeader(http.StatusOK)
}

// ---- Roost sender ----

// RoostSender posts to the chat server's alerts endpoint. Client must reach
// the server over the tailnet (the server only listens there), which is
// what makes the request carry the bridge's tagged identity.
type RoostSender struct {
	BaseURL string // e.g. http://roost-chat
	Client  *http.Client
}

func (s RoostSender) Send(ctx context.Context, text string) error {
	payload, err := json.Marshal(struct {
		Body string `json:"body"`
	}{text})
	if err != nil {
		return fmt.Errorf("marshal message: %w", err)
	}

	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(s.BaseURL, "/")+"/bot/messages", bytes.NewReader(payload))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := s.Client.Do(req)
	if err != nil {
		return fmt.Errorf("post to roost: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusCreated {
		detail, _ := io.ReadAll(io.LimitReader(resp.Body, 256))
		return errors.New("roost returned " + resp.Status + ": " + strings.TrimSpace(string(detail)))
	}
	return nil
}
