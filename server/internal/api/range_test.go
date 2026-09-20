package api

import "testing"

func TestParseByteRange(t *testing.T) {
	const size = int64(1000)

	cases := []struct {
		name      string
		header    string
		wantStart int64
		wantEnd   int64
		wantOK    bool
	}{
		{"a plain start-end range", "bytes=0-499", 0, 499, true},
		{"an open-ended range reads to the end", "bytes=500-", 500, 999, true},
		{"a suffix range reads the last N bytes", "bytes=-200", 800, 999, true},
		{"a suffix range larger than the object clamps to the whole object", "bytes=-5000", 0, 999, true},
		{"an end past the object size clamps to the last byte", "bytes=900-5000", 900, 999, true},
		{"a start at the object size is unsatisfiable", "bytes=1000-1000", 0, 0, false},
		{"a start past the object size is unsatisfiable", "bytes=1500-", 0, 0, false},
		{"end before start is invalid", "bytes=500-100", 0, 0, false},
		{"multiple ranges aren't supported", "bytes=0-100,200-300", 0, 0, false},
		{"a non-bytes unit is rejected", "items=0-1", 0, 0, false},
		{"garbage is rejected", "nonsense", 0, 0, false},
		{"an empty header is rejected", "", 0, 0, false},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			start, end, ok := parseByteRange(c.header, size)
			if ok != c.wantOK {
				t.Fatalf("ok = %v, want %v", ok, c.wantOK)
			}
			if !ok {
				return
			}
			if start != c.wantStart || end != c.wantEnd {
				t.Fatalf("got [%d, %d], want [%d, %d]", start, end, c.wantStart, c.wantEnd)
			}
		})
	}
}
