// Package textfmt formats numbers for the one-line status summaries the client
// and the relay print for a human to read.
//
// It is deliberately tiny, and it exists for one reason: Bytes was written twice,
// byte-for-byte identically, in core/stats.go and relay/introspect.go -- two
// packages that share no code path and never call each other. Two copies of a
// formatter is not expensive to keep, but it IS how two status lines start
// disagreeing about what a megabyte is, and the whole point of these lines is
// that a person compares them.
//
// Deliberately internal/. This is how OUR binaries phrase a log line, not a
// contract anyone should import -- unlike the six library packages at the repo
// root, which are public on purpose.
//
// Nothing here knows anything about a game, and nothing here may learn: it is
// below the level internal/gameblind polices, and it is shared by the client and
// the server, which is exactly the boundary CLAUDE.md keeps them on opposite
// sides of.
package textfmt

import (
	"fmt"
	"time"
)

// Bytes renders a byte total the way a person reads it. Deliberately coarse:
// this is a number someone eyeballs in a terminal to decide whether a difference
// is worth caring about, not one anything computes with.
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

// PerHour states a total as a rate in units a person can act on. "41 MB/hour" is
// a number someone can compare against their connection or their data cap;
// "11.7 KB/s" is one they have to convert first.
//
// Returns "rate unknown" rather than dividing by zero for a process that has not
// been up long enough to have an uptime.
func PerHour(n uint64, uptime time.Duration) string {
	if uptime <= 0 {
		return "rate unknown"
	}
	return Bytes(uint64(float64(n)/uptime.Hours())) + "/hour"
}
