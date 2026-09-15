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

func TestComputeMessageStatus(t *testing.T) {
	cases := []struct {
		name                        string
		recipients, delivered, seen int
		want                        MessageStatus
	}{
		{"no recipients", 0, 0, 0, MessageStatusSent},
		{"1:1, no receipts yet", 1, 0, 0, MessageStatusSent},
		{"1:1, delivered", 1, 1, 0, MessageStatusDelivered},
		{"1:1, seen", 1, 1, 1, MessageStatusSeen},
		{"group, one of two delivered", 2, 1, 0, MessageStatusSent},
		{"group, both delivered", 2, 2, 0, MessageStatusDelivered},
		{"group, one of two seen", 2, 2, 1, MessageStatusDelivered},
		{"group, both seen", 2, 2, 2, MessageStatusSeen},
		{"seen without delivered count (defensive)", 1, 0, 1, MessageStatusSeen},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ComputeMessageStatus(tc.recipients, tc.delivered, tc.seen); got != tc.want {
				t.Errorf("ComputeMessageStatus(%d, %d, %d) = %v, want %v",
					tc.recipients, tc.delivered, tc.seen, got, tc.want)
			}
		})
	}
}
