// Package textfmt formats numbers for the one-line status summaries the client and the relay print, shared so the two
// lines a person compares agree on what a megabyte is. It is internal because it is how our binaries phrase a log
// line, not a contract to import.
package textfmt

import (
	"fmt"
	"time"
)

// Bytes renders a byte total the way a person reads it, coarse on purpose: it is eyeballed, never computed with.
func Bytes(n uint64) string {
	switch {
	case n >= 1<<30:
		return fmt.Sprintf("%.1f GB", float64(n)/float64(1<<30))
	case n >= 1<<20:
		return fmt.Sprintf("%.1f MB", float64(n)/float64(1<<20))
	case n >= 1<<10:
		return fmt.Sprintf("%.1f KB", float64(n)/float64(1<<10))
	default:
		return fmt.Sprintf("%d B", n)
	}
}

// PerHour states a total as an hourly rate, which a person can compare with a connection or a data cap without
// converting. A process with no uptime yet gets "rate unknown" rather than a division by zero.
func PerHour(n uint64, uptime time.Duration) string {
	if uptime <= 0 {
		return "rate unknown"
	}
	return Bytes(uint64(float64(n)/uptime.Hours())) + "/hour"
}
