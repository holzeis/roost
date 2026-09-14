// Package migrations embeds the SQL migration files so the server binary
// carries its own schema and needs no separate migrations directory at deploy time.
package migrations

import "embed"

//go:embed *.sql
var FS embed.FS
