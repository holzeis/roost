package models

import (
	"testing"
	"time"
)

func TestLocationShare_Active(t *testing.T) {
	now := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)

	cases := []struct {
		name  string
		share LocationShare
		want  bool
	}{
		{
			name:  "before expiry, never ended",
			share: LocationShare{ExpiresAt: now.Add(time.Minute)},
			want:  true,
		},
		{
			name:  "past expiry",
			share: LocationShare{ExpiresAt: now.Add(-time.Minute)},
			want:  false,
		},
		{
			name: "manually ended before expiry",
			share: LocationShare{
				ExpiresAt: now.Add(time.Hour),
				EndedAt:   timePtr(now.Add(-time.Second)),
			},
			want: false,
		},
		{
			name: "ends exactly now",
			share: LocationShare{
				ExpiresAt: now.Add(time.Hour),
				EndedAt:   timePtr(now),
			},
			want: false,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := tc.share.Active(now); got != tc.want {
				t.Errorf("Active() = %v, want %v", got, tc.want)
			}
		})
	}
}

func timePtr(t time.Time) *time.Time { return &t }
