// Package srclimit keeps the relay's only per-source state: how many
// connections each client address holds open, and how many wrong room codes
// it has recently tried.
//
// WHY IT EXISTS. Every bound the relay had before 2026-09-15 was global: 64
// open connections per listener, 256 handshaked quic connections waiting for
// a stream, one room-code guess per connection. Global bounds are what a
// single machine walks straight through -- one address could hold all 64
// slots and refuse every real player with a bare close (finding A5 of the
// fourth adversarial review, 2026-09-13), and could guess room codes at the
// rate it could open connections, hundreds a second (finding A3). Both need
// the one thing the relay had never kept: who is asking.
//
// WHAT IT DELIBERATELY IS NOT. docs/security.md's privacy section: the
// relay does not read a client's IP, and relay, core and cmd/ contain no
// RemoteAddr call site (internal/gameblind pins that). This package lives in
// netx, the layer that already had to know addresses to demultiplex udp, and
// it keeps them in memory only: nothing here is logged, written, or handed
// upward. The relay reaches it through relay.Server.SourceGuard by passing
// the net.Conn, so the address is read on this side of that line. What a
// caller can learn from a Table is a yes or a no and a count.
//
// BOUNDED, AND THE ATTACKER PAYS. The map is capped at MaxEntries. When it
// is full a newcomer evicts the oldest idle entry (no open connection, empty
// bucket), and if none is idle the newcomer is refused -- every entry that
// is not idle was used within the last few seconds, so a full table means
// thousands of distinct addresses active at once, which is not a room of
// friends. ADR 0064.
package srclimit

import (
	"net"
	"strings"
	"sync"
	"time"
)

// Options sizes a Table. Zero values mean "no limit of that kind".
type Options struct {
	// MaxOpenPerSource bounds connections one address may hold open at once.
	MaxOpenPerSource int
	// AuthBurst is how many failed room-code attempts an address may make
	// before it is blocked; AuthRefillPerSecond is how fast that allowance
	// comes back. Zero AuthBurst means room-code failures are not tracked.
	AuthBurst           int
	AuthRefillPerSecond float64
	// MaxEntries caps the number of addresses remembered. Zero means
	// DefaultMaxEntries.
	MaxEntries int
}

// DefaultMaxEntries is the table cap when Options.MaxEntries is zero. Sized
// so that an attacker needs thousands of distinct addresses at once to fill
// it, while the memory it can cost a host is a few hundred kilobytes.
const DefaultMaxEntries = 4096

// Table is the per-source state. Safe for concurrent use.
type Table struct {
	opts Options
	now  func() time.Time

	mu      sync.Mutex
	entries map[string]*entry
	// Counts only, for the throttled log lines the listeners print.
	refusedOpen  int64
	refusedFull  int64
	blockedAuths int64
}

type entry struct {
	open     int
	level    float64   // the failed-attempt bucket, leaking at AuthRefillPerSecond
	leakedAt time.Time // when level was last brought up to date
	lastSeen time.Time
}

// New makes an empty Table.
func New(o Options) *Table {
	if o.MaxEntries <= 0 {
		o.MaxEntries = DefaultMaxEntries
	}
	return &Table{opts: o, now: time.Now, entries: make(map[string]*entry)}
}

// Key is the part of an address a Table is keyed by: an IPv4 host, or the
// /64 an IPv6 host sits in, with any zone stripped. Empty when addr is not
// host:port shaped (net.Pipe says "pipe"), in which case the Table counts
// nothing for it -- a connection with no address cannot be a stranger's.
//
// Why the /64 and not the address (pass 5 of the adversarial review,
// 2026-09-16, P1b-2): an ordinary home IPv6 line is handed a whole /64, and
// one machine can bind any address in it, so keying by the full address gave
// that machine a fresh wrong-room-code budget and a fresh connection share
// per source address it chose to use -- the guessing rate the budget exists
// to stop, bounded again only by the listener-wide caps. A /64 is the
// smallest block a single subscriber is given; it is the IPv6 shape of the
// one public IPv4 a NAT household already shares. An IPv4-mapped IPv6
// address is keyed as the IPv4 it carries, so a dual-stack listener counts a
// v4 client once whichever form the socket reports.
func Key(addr net.Addr) string {
	if addr == nil {
		return ""
	}
	host, _, err := net.SplitHostPort(addr.String())
	if err != nil {
		return ""
	}
	if i := strings.IndexByte(host, '%'); i >= 0 {
		host = host[:i]
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return host
	}
	if v4 := ip.To4(); v4 != nil {
		return v4.String()
	}
	return ip.Mask(net.CIDRMask(64, 128)).String() + "/64"
}

// Acquire records one more open connection from addr. False means the
// address already holds MaxOpenPerSource, or the table is full of active
// entries; the caller closes the connection and must NOT call Release for
// it. An unkeyable address is always acquired and never counted.
func (t *Table) Acquire(addr net.Addr) bool {
	key := Key(addr)
	if key == "" {
		return true
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.lookupLocked(key)
	if e == nil {
		t.refusedFull++
		return false
	}
	if t.opts.MaxOpenPerSource > 0 && e.open >= t.opts.MaxOpenPerSource {
		t.refusedOpen++
		return false
	}
	e.open++
	return true
}

// Release undoes one Acquire that returned true.
func (t *Table) Release(addr net.Addr) {
	key := Key(addr)
	if key == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	if e := t.entries[key]; e != nil && e.open > 0 {
		e.open--
		e.lastSeen = t.now()
	}
}

// NoteAuthFailure records one wrong room code from conn's address.
// Implements relay.Server.SourceGuard.
func (t *Table) NoteAuthFailure(conn net.Conn) {
	if t.opts.AuthBurst <= 0 || conn == nil {
		return
	}
	key := Key(conn.RemoteAddr())
	if key == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.lookupLocked(key)
	if e == nil {
		return // table full of active entries: the attempt goes uncounted, not unrefused elsewhere
	}
	t.leakLocked(e)
	e.level++
}

// Blocked reports whether conn's address has used up its allowance of wrong
// room codes and must be refused before the code is even compared.
// Implements relay.Server.SourceGuard.
func (t *Table) Blocked(conn net.Conn) bool {
	if t.opts.AuthBurst <= 0 || conn == nil {
		return false
	}
	key := Key(conn.RemoteAddr())
	if key == "" {
		return false
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.entries[key]
	if e == nil {
		return false
	}
	t.leakLocked(e)
	if e.level >= float64(t.opts.AuthBurst) {
		t.blockedAuths++
		return true
	}
	return false
}

// Counts are the running totals a listener's throttled log line prints:
// connections refused because one address held too many, connections
// refused because the table was full, and hellos refused because the
// address was blocked. Never addresses.
func (t *Table) Counts() (refusedOpen, refusedFull, blockedAuths int64) {
	t.mu.Lock()
	defer t.mu.Unlock()
	return t.refusedOpen, t.refusedFull, t.blockedAuths
}

// Len is how many addresses are remembered. For tests.
func (t *Table) Len() int {
	t.mu.Lock()
	defer t.mu.Unlock()
	return len(t.entries)
}

// leakLocked brings e's bucket up to date. Tokens come back WHOLE, one per
// 1/AuthRefillPerSecond, not as a continuous drain: with a continuous drain
// an address blocked at level == burst is unblocked a millisecond later
// (level 2.999 < 3), so "blocked" would be a window nothing could rely on.
// Whole tokens make it a full interval, which is the rate the relay's tests
// assert against.
func (t *Table) leakLocked(e *entry) {
	now := t.now()
	e.lastSeen = now
	if t.opts.AuthRefillPerSecond <= 0 {
		e.leakedAt = now
		return
	}
	if e.level <= 0 {
		e.level = 0
		e.leakedAt = now
		return
	}
	interval := time.Duration(float64(time.Second) / t.opts.AuthRefillPerSecond)
	if interval <= 0 {
		interval = time.Nanosecond
	}
	whole := now.Sub(e.leakedAt) / interval
	if whole <= 0 {
		return
	}
	e.level -= float64(whole)
	e.leakedAt = e.leakedAt.Add(whole * interval)
	if e.level <= 0 {
		e.level = 0
		e.leakedAt = now
	}
}

func (t *Table) idleLocked(e *entry) bool {
	if e.open > 0 {
		return false
	}
	t.leakLocked(e)
	return e.level == 0
}

// lookupLocked returns key's entry, creating it -- evicting the oldest idle
// entry when the table is full -- or nil when the table is full of active
// entries.
func (t *Table) lookupLocked(key string) *entry {
	if e := t.entries[key]; e != nil {
		e.lastSeen = t.now()
		return e
	}
	if len(t.entries) >= t.opts.MaxEntries {
		var victimKey string
		var victim *entry
		for k, e := range t.entries {
			if !t.idleLocked(e) {
				continue
			}
			if victim == nil || e.lastSeen.Before(victim.lastSeen) {
				victimKey, victim = k, e
			}
		}
		if victim == nil {
			return nil
		}
		delete(t.entries, victimKey)
	}
	now := t.now()
	e := &entry{leakedAt: now, lastSeen: now}
	t.entries[key] = e
	return e
}
