// Command server runs the Roost chat server: it joins the tailnet as its own
// node (via tsnet), serves the REST API and WebSocket fan-out described in
// docs/architecture-overview.md, and mints LiveKit tokens for calls.
package main

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"tailscale.com/tsnet"

	"roost/server/internal/api"
	"roost/server/internal/auth"
	"roost/server/internal/config"
	"roost/server/internal/db"
	"roost/server/internal/livekit"
	"roost/server/internal/storage"
	"roost/server/internal/store"
	"roost/server/internal/ws"
)

const shutdownTimeout = 10 * time.Second

func main() {
	if err := run(); err != nil {
		slog.Error("server exited", "error", err)
		os.Exit(1)
	}
}

func run() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	cfg, err := config.Load()
	if err != nil {
		return err
	}

	pool, err := db.Connect(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	if err := db.Migrate(cfg.DatabaseURL); err != nil {
		return err
	}

	media, err := storage.New(ctx, cfg.S3Endpoint, cfg.S3AccessKey, cfg.S3SecretKey, cfg.S3Bucket, cfg.S3UseSSL)
	if err != nil {
		return err
	}

	srv := &api.Server{
		Store:   store.New(pool),
		Hub:     ws.NewHub(),
		LiveKit: livekit.NewMinter(cfg.LiveKitAPIKey, cfg.LiveKitAPISecret),
		Media:   media,
	}

	listener, cleanup, err := newListener(ctx, cfg.ListenAddr, &srv.Resolver)
	if err != nil {
		return err
	}
	defer cleanup()

	httpServer := &http.Server{Handler: srv.Router()}
	errCh := make(chan error, 1)
	go func() {
		slog.Info("roost chat server listening", "addr", listener.Addr())
		errCh <- httpServer.Serve(listener)
	}()

	// In production the app's only listener is inside the tailnet (tsnet),
	// which kubelet can't reach for liveness/readiness probes. This second
	// server exists purely for that: bound to loopback only, so it adds no
	// externally reachable surface, and kubelet-to-pod traffic is already
	// cluster-internal.
	probeServer := &http.Server{Addr: "127.0.0.1:9000", Handler: probeMux()}
	go func() {
		if err := probeServer.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			slog.Error("probe server exited", "error", err)
		}
	}()
	defer probeServer.Close()

	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), shutdownTimeout)
		defer cancel()
		return httpServer.Shutdown(shutdownCtx)
	case err := <-errCh:
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	}
}

// newListener returns either a real tsnet listener (production, joining the
// tailnet as its own node so auth.TsnetResolver can look up per-connection
// identity) or a plain local listener paired with auth.DevResolver, when
// ENABLE_DEV_AUTH=true — for docker-compose local development where there is
// no tailnet to join. DevResolver trusts every connection unconditionally,
// so this path must never be used outside local dev.
func newListener(ctx context.Context, listenAddr string, resolver *auth.Resolver) (net.Listener, func(), error) {
	if os.Getenv("ENABLE_DEV_AUTH") == "true" {
		slog.Warn("ENABLE_DEV_AUTH=true: every request will be trusted as a fixed dev identity; do not use this outside local development")
		*resolver = auth.DevResolver{Identity: auth.Identity{
			LoginName:   getenvDefault("DEV_AUTH_LOGIN", "dev@localhost"),
			DisplayName: getenvDefault("DEV_AUTH_DISPLAY_NAME", "Dev User"),
		}}
		l, err := net.Listen("tcp", listenAddr)
		if err != nil {
			return nil, nil, err
		}
		return l, func() {}, nil
	}

	ts := &tsnet.Server{
		Hostname: getenvDefault("TSNET_HOSTNAME", "roost-chat"),
		Dir:      os.Getenv("TSNET_STATE_DIR"),
		AuthKey:  os.Getenv("TSNET_AUTHKEY"),
	}
	if err := ts.Start(); err != nil {
		return nil, nil, err
	}
	local, err := ts.LocalClient()
	if err != nil {
		ts.Close()
		return nil, nil, err
	}
	*resolver = auth.TsnetResolver{Local: local}

	l, err := ts.Listen("tcp", ":80")
	if err != nil {
		ts.Close()
		return nil, nil, err
	}
	return l, func() { ts.Close() }, nil
}

func probeMux() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	return mux
}

func getenvDefault(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
