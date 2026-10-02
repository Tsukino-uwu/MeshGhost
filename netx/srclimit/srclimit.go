// Package srclimit keeps the relay's only per-source state: how many connections each client address holds open, and
// how many wrong room codes it has recently tried. Global bounds alone are what one machine walks straight through:
// it could hold every slot, or guess room codes as fast as it can open connections.
//
// # Addresses stay here
//
// The relay does not read a client's IP: relay, core and cmd/ have no RemoteAddr call site (internal/gameblind pins
// that). This package lives in netx, which already knew addresses to demultiplex udp, and keeps them in memory only:
// nothing is logged, written or handed upward. The relay passes the net.Conn through relay.Server.SourceGuard, so
// what a caller learns from a Table is a yes, a no and a count.
//
// # Bounded
//
// The map is capped at MaxEntries. When it is full a newcomer evicts the oldest idle entry (no open connection, empty
// bucket), and if none is idle the newcomer is refused: a full table of active entries is thousands of addresses at
// once, not a room of friends.
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
	// AuthBurst is how many failed room-code attempts an address may make before it is blocked;
	// AuthRefillPerSecond is how fast that allowance comes back. Zero AuthBurst means failures are not tracked.
	AuthBurst           int
	AuthRefillPerSecond float64
	// MaxEntries caps the number of addresses remembered. Zero means DefaultMaxEntries.
	MaxEntries int
}

// DefaultMaxEntries is the table cap when Options.MaxEntries is zero: thousands of distinct addresses at once to fill
// it, a few hundred kilobytes at most to a host.
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

// Key is the part of an address a Table is keyed by: an IPv4 host, or the /64 an IPv6 host sits in, with any zone
// stripped. Empty when addr is not host:port shaped (net.Pipe says "pipe"); the Table counts nothing for it.
//
// A home IPv6 line is handed a whole /64 and one machine can bind any address in it, so keying the full address
// would give it a fresh budget per address; the /64 is the IPv6 shape of one NAT household's public IPv4. An
// IPv4-mapped address is keyed as its IPv4, so a dual-stack listener counts a v4 client once.
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

// Acquire records one more open connection from addr. False means the address already holds MaxOpenPerSource, or
// the table is full of active entries; the caller closes the connection and must not call Release for it. An
// unkeyable address is always acquired and never counted.
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

// NoteAuthFailure records one wrong room code from conn's address. Implements relay.Server.SourceGuard.
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
		return // table full of active entries: the attempt goes uncounted
	}
	t.leakLocked(e)
	e.level++
}

// NoteAuthSuccess refunds one attempt charged by NoteAuthFailure, because the proof it paid for came out right. The
// relay charges when a proof begins, so a player who types the right code pays nothing. Implements
// relay.Server.SourceGuard.
func (t *Table) NoteAuthSuccess(conn net.Conn) {
	if t.opts.AuthBurst <= 0 || conn == nil {
		return
	}
	key := Key(conn.RemoteAddr())
	if key == "" {
		return
	}
	t.mu.Lock()
	defer t.mu.Unlock()
	e := t.entries[key]
	if e == nil {
		return
	}
	t.leakLocked(e)
	if e.level >= 1 {
		e.level--
	} else {
		e.level = 0
	}
}

// Blocked reports whether conn's address has used up its allowance of wrong room codes and must be refused before
// the code is even compared. Implements relay.Server.SourceGuard.
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

// Counts are the running totals a listener's throttled log line prints: connections refused because one address
// held too many, connections refused because the table was full, and hellos refused because the address was
// blocked. Never addresses.
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

// leakLocked brings e's bucket up to date. Tokens come back whole, one per 1/AuthRefillPerSecond: with a continuous
// drain an address blocked at level == burst would be unblocked a millisecond later (2.999 < 3).
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

// lookupLocked returns key's entry, creating it (evicting the oldest idle entry when the table is full), or nil when
// the table is full of active entries.
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
