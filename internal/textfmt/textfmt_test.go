package textfmt

import (
	"testing"
	"time"
)

// This package had no test file at all until 2026-08-27, which is worth saying
// plainly: it exists precisely so the client's and the relay's status lines
// "cannot start disagreeing about what a megabyte is" (see the package doc), and
// that was the one property nothing pinned. Two copies of a formatter agreeing
// today is not the same as two that cannot drift; neither is one copy whose
// thresholds nothing checks.

func TestBytesThresholds(t *testing.T) {
	// The boundaries, not the middles: an off-by-one in a `>=` is the whole
	// class of bug available here, so each case sits exactly on a switch arm or
	// one byte below it.
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
	// A process that has not been up long enough to have an uptime must not
	// produce +Inf or NaN in a line a person is reading. The guard is
	// `uptime <= 0`, so a negative duration -- which a clock adjustment can
	// hand you -- has to take the same branch as zero.
	for _, d := range []time.Duration{0, -time.Second} {
		if got := PerHour(1<<20, d); got != "rate unknown" {
			t.Errorf("PerHour(1MiB, %v) = %q, want %q", d, got, "rate unknown")
		}
	}
}

func TestPerHourScalesToTheHour(t *testing.T) {
	// The point of the function per its own doc: "41 MB/hour" is actionable and
	// "11.7 KB/s" is not, so the rate must be per HOUR and must reuse Bytes.
	if got, want := PerHour(1<<20, time.Hour), "1.0 MB/hour"; got != want {
		t.Errorf("PerHour(1MiB, 1h) = %q, want %q", got, want)
	}
	// Half an hour of the same total is twice the hourly rate.
	if got, want := PerHour(1<<20, 30*time.Minute), "2.0 MB/hour"; got != want {
		t.Errorf("PerHour(1MiB, 30m) = %q, want %q", got, want)
	}
}
