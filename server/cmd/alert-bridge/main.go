// Command alert-bridge forwards Prometheus Alertmanager webhooks to Roost's
// Alerts room as a dedicated alert identity. See internal/alertbridge.
package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"tailscale.com/tsnet"

	"roost/server/internal/alertbridge"
)

// tailnetUpTimeout bounds the wait for the first tailnet login.
const tailnetUpTimeout = 2 * time.Minute

func main() {
	if err := run(); err != nil {
		slog.Error("alert-bridge exited", "error", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	client, cleanup, err := roostClient(ctx)
	if err != nil {
		return err
	}
	defer cleanup()

	sender := alertbridge.RoostSender{
		BaseURL: getenvDefault("ROOST_URL", "http://roost-chat"),
		Client:  client,
	}
	go offerAvatar(ctx, sender)
	handler := alertbridge.Handler{Sender: sender}
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

// offerAvatar keeps the alert identity's profile picture up to date. It retries because
// the chat server may be restarting alongside the bridge, and gives up
// quietly: a missing picture must never stop alerts from flowing.
func offerAvatar(ctx context.Context, sender alertbridge.RoostSender) {
	const attempts = 10
	for i := 1; i <= attempts; i++ {
		err := sender.EnsureAvatar(ctx)
		if err == nil {
			return
		}
		slog.Warn("could not set alert avatar", "attempt", i, "error", err)
		select {
		case <-ctx.Done():
			return
		case <-time.After(30 * time.Second):
		}
	}
}

// roostClient returns an HTTP client that reaches the chat server over the
// tailnet as this pod's own node — that node's ACL tag is the bridge's
// identity. DEV_DIRECT=true skips the tailnet for docker-compose, where the
// chat server runs with ENABLE_DEV_AUTH and recognises the bridge by host
// instead; never set it outside local development.
func roostClient(ctx context.Context) (*http.Client, func(), error) {
	if os.Getenv("DEV_DIRECT") == "true" {
		slog.Warn("DEV_DIRECT=true: talking to the chat server without the tailnet; do not use this outside local development")
		return &http.Client{}, func() {}, nil
	}

	ts := &tsnet.Server{
		Hostname: getenvDefault("TSNET_HOSTNAME", "roost-alerts"),
		Dir:      os.Getenv("TSNET_STATE_DIR"),
		AuthKey:  os.Getenv("TSNET_AUTHKEY"),
	}
	// TSNET_VERBOSE=true shows tailscale's own logs, which say why a login
	// is being refused (bad/expired key, tag not permitted, approval pending).
	if os.Getenv("TSNET_VERBOSE") == "true" {
		ts.Logf = log.Printf
	}

	// Wait for the node to actually be on the tailnet. Without this the
	// bridge serves happily while every send hangs until it times out, and
	// nothing says why; failing here puts the reason in the pod's logs.
	upCtx, cancel := context.WithTimeout(ctx, tailnetUpTimeout)
	defer cancel()
	if _, err := ts.Up(upCtx); err != nil {
		ts.Close()
		return nil, nil, fmt.Errorf("join tailnet (is TSNET_AUTHKEY valid, tagged, and approved? set TSNET_VERBOSE=true for details): %w", err)
	}
	slog.Info("joined tailnet", "hostname", ts.Hostname)
	return ts.HTTPClient(), func() { ts.Close() }, nil
}

func getenvDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
