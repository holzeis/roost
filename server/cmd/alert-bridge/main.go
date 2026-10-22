// Command alert-bridge forwards Prometheus Alertmanager webhooks to Roost's
// Alerts room as a dedicated alert identity. See internal/alertbridge.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"tailscale.com/tsnet"

	"roost/server/internal/alertbridge"
)

func main() {
	if err := run(); err != nil {
		slog.Error("alert-bridge exited", "error", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	client, cleanup, err := roostClient()
	if err != nil {
		return err
	}
	defer cleanup()

	handler := alertbridge.Handler{Sender: alertbridge.RoostSender{
		BaseURL: getenvDefault("ROOST_URL", "http://roost-chat"),
		Client:  client,
	}}
	server := &http.Server{
		Addr:              getenvDefault("LISTEN_ADDR", ":8080"),
		Handler:           handler.Routes(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		slog.Info("alert-bridge listening", "addr", server.Addr)
		errCh <- server.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return server.Shutdown(shutdownCtx)
	case err := <-errCh:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return err
	}
}

// roostClient returns an HTTP client that reaches the chat server over the
// tailnet as this pod's own node — that node's ACL tag is the bridge's
// identity. DEV_DIRECT=true skips the tailnet for docker-compose, where the
// chat server runs with ENABLE_DEV_AUTH and recognises the bridge by host
// instead; never set it outside local development.
func roostClient() (*http.Client, func(), error) {
	if os.Getenv("DEV_DIRECT") == "true" {
		slog.Warn("DEV_DIRECT=true: talking to the chat server without the tailnet; do not use this outside local development")
		return &http.Client{}, func() {}, nil
	}

	ts := &tsnet.Server{
		Hostname: getenvDefault("TSNET_HOSTNAME", "roost-alerts"),
		Dir:      os.Getenv("TSNET_STATE_DIR"),
		AuthKey:  os.Getenv("TSNET_AUTHKEY"),
	}
	if err := ts.Start(); err != nil {
		return nil, nil, fmt.Errorf("join tailnet: %w", err)
	}
	return ts.HTTPClient(), func() { ts.Close() }, nil
}

func getenvDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
