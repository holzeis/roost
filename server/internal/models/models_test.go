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

func TestValidShareTTL(t *testing.T) {
	cases := []struct {
		name string
		d    time.Duration
		want bool
	}{
		{"15 minutes (a real preset)", 15 * time.Minute, true},
		{"1 hour (a real preset)", time.Hour, true},
		{"8 hours (\"until I arrive\")", 8 * time.Hour, true},
		{"exactly the minimum", time.Minute, true},
		{"exactly the maximum", 12 * time.Hour, true},
		{"zero", 0, false},
		{"negative", -time.Minute, false},
		{"below the minimum", 30 * time.Second, false},
		{"above the maximum", 13 * time.Hour, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ValidShareTTL(tc.d); got != tc.want {
				t.Errorf("ValidShareTTL(%v) = %v, want %v", tc.d, got, tc.want)
			}
		})
	}
}

func TestValidCoordinate(t *testing.T) {
	cases := []struct {
		name     string
		lat, lng float64
		want     bool
	}{
		{"null island", 0, 0, true},
		{"a real place", 52.5200, 13.4050, true},
		{"north pole", 90, 0, true},
		{"south pole", -90, 0, true},
		{"antimeridian east", 0, 180, true},
		{"antimeridian west", 0, -180, true},
		{"lat too high", 90.1, 0, false},
		{"lat too low", -90.1, 0, false},
		{"lng too high", 0, 180.1, false},
		{"lng too low", 0, -180.1, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ValidCoordinate(tc.lat, tc.lng); got != tc.want {
				t.Errorf("ValidCoordinate(%v, %v) = %v, want %v", tc.lat, tc.lng, got, tc.want)
			}
		})
	}
}
