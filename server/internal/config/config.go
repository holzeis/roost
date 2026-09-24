// Package config loads server configuration from the environment.
package config

import (
	"fmt"
	"os"
)

type Config struct {
	// ListenAddr is the tailnet-facing address the HTTP/WS server binds to.
	ListenAddr string
	// DatabaseURL is a Postgres connection string (postgres://...).
	DatabaseURL string
	// S3Endpoint, S3AccessKey, S3SecretKey, S3Bucket configure the MinIO client.
	S3Endpoint  string
	S3AccessKey string
	S3SecretKey string
	S3Bucket    string
	S3UseSSL    bool
	// LiveKitURL is the tailnet address of the LiveKit server the clients connect to.
	LiveKitURL       string
	LiveKitAPIKey    string
	LiveKitAPISecret string
	// APNS*/FCMServiceAccountJSON configure the FR5.1 push-fallback senders
	// (server/internal/push) — left unset in local dev, which falls back to
	// push.NoopSender (see server/cmd/server/main.go).
	APNSKeyID             string
	APNSTeamID            string
	APNSPrivateKey        string
	APNSBundleID          string
	APNSProduction        bool
	FCMServiceAccountJSON string
}

func Load() (Config, error) {
	cfg := Config{
		ListenAddr:       getenv("LISTEN_ADDR", ":8080"),
		DatabaseURL:      os.Getenv("DATABASE_URL"),
		S3Endpoint:       os.Getenv("S3_ENDPOINT"),
		S3AccessKey:      os.Getenv("S3_ACCESS_KEY"),
		S3SecretKey:      os.Getenv("S3_SECRET_KEY"),
		S3Bucket:         getenv("S3_BUCKET", "roost-media"),
		S3UseSSL:         os.Getenv("S3_USE_SSL") == "true",
		LiveKitURL:       os.Getenv("LIVEKIT_URL"),
		LiveKitAPIKey:    os.Getenv("LIVEKIT_API_KEY"),
		LiveKitAPISecret: os.Getenv("LIVEKIT_API_SECRET"),

		APNSKeyID:             os.Getenv("APNS_KEY_ID"),
		APNSTeamID:            os.Getenv("APNS_TEAM_ID"),
		APNSPrivateKey:        os.Getenv("APNS_PRIVATE_KEY"),
		APNSBundleID:          getenv("APNS_BUNDLE_ID", "me.holzeis.roost.roost"),
		APNSProduction:        os.Getenv("APNS_PRODUCTION") == "true",
		FCMServiceAccountJSON: os.Getenv("FCM_SERVICE_ACCOUNT_JSON"),
	}

	var missing []string
	if cfg.DatabaseURL == "" {
		missing = append(missing, "DATABASE_URL")
	}
	if len(missing) > 0 {
		return cfg, fmt.Errorf("missing required environment variables: %v", missing)
	}
	return cfg, nil
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
