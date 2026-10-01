package textfmt

import (
	"testing"
	"time"
)

func TestBytesThresholds(t *testing.T) {
	// The boundaries, not the middles: each case sits exactly on a switch arm or one byte below it.
	cases := []struct {
		in   uint64
		want string
	}{
		{0, "0 B"},
		{1, "1 B"},
		{(1 << 10) - 1, "1023 B"},
		{1 << 10, "1.0 KB"},
		{(1 << 20) - 1, "1024.0 KB"},
		{1 << 20, "1.0 MB"},
		{(1 << 30) - 1, "1024.0 MB"},
		{1 << 30, "1.0 GB"},
		{3 << 30, "3.0 GB"},
	}
	for _, c := range cases {
		if got := Bytes(c.in); got != c.want {
			t.Errorf("Bytes(%d) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestPerHourReportsUnknownRatherThanDividingByZero(t *testing.T) {
	// A negative duration, which a clock adjustment can hand you, must take zero's branch, not print +Inf or NaN.
	for _, d := range []time.Duration{0, -time.Second} {
		if got := PerHour(1<<20, d); got != "rate unknown" {
			t.Errorf("PerHour(1MiB, %v) = %q, want %q", d, got, "rate unknown")
		}
	}
}

func TestPerHourScalesToTheHour(t *testing.T) {
	if got, want := PerHour(1<<20, time.Hour), "1.0 MB/hour"; got != want {
		t.Errorf("PerHour(1MiB, 1h) = %q, want %q", got, want)
	}
	// Half an hour of the same total is twice the hourly rate.
	if got, want := PerHour(1<<20, 30*time.Minute), "2.0 MB/hour"; got != want {
		t.Errorf("PerHour(1MiB, 30m) = %q, want %q", got, want)
	}
}
