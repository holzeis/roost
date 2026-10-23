package store

import (
	"testing"
	"time"
)

func TestEffectiveMute(t *testing.T) {
	now := time.Date(2026, 10, 23, 12, 0, 0, 0, time.UTC)
	future, past := now.Add(time.Hour), now.Add(-time.Hour)

	cases := []struct {
		name      string
		muted     bool
		until     *time.Time
		wantMuted bool
		wantUntil *time.Time
	}{
		{"not muted", false, nil, false, nil},
		{"muted until turned off", true, nil, true, nil},
		{"timed mute in force", false, &future, true, &future},
		{"lapsed timed mute", false, &past, false, nil},
		{"forever wins over a leftover end time", true, &past, true, nil},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			muted, until := effectiveMute(c.muted, c.until, now)
			if muted != c.wantMuted {
				t.Fatalf("muted = %v, want %v", muted, c.wantMuted)
			}
			if (until == nil) != (c.wantUntil == nil) || (until != nil && !until.Equal(*c.wantUntil)) {
				t.Fatalf("until = %v, want %v", until, c.wantUntil)
			}
		})
	}
}
