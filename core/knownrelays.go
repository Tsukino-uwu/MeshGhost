package core

// The client's memory of which relay is which: trust on first use, the SSH
// model. A relay's certificate is self-signed and connect_to is a bare IP,
// so nothing external can vouch for it; what a client CAN do is remember the
// fingerprint it saw the first time and notice when it changes. That is
// what this file is (ADR 0066, agent_docs/tls-planning.md).
//
// What happens on a mismatch is deliberately mild for now: the entry is
// updated, the connection goes ahead (still encrypted), and the log says
// so LOUDLY, naming both fingerprints. Refusing, as SSH does, would need a
// manual step from a player every time a host reinstalls, and "nothing
// manual" is the user's requirement. The room code is what will settle a
// change instead -- a PAKE bound to the connection, the plan's step 5,
// deliberately a separate later piece so each half is tested on its own.
// Until then a changed identity is warned about, not proven.

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// KnownRelaysFileName is the store's file, beside the client's config.json.
// Not in the relay's private/ folder: this file is a memory, not a secret,
// and a client has nothing to keep private (it holds no certificate).
const KnownRelaysFileName = "known_servers.json"

// knownRelaysFileVersion is written into every file and checked on read; a
// later shape bumps it and reads the older one explicitly.
const knownRelaysFileVersion = 1

// maxKnownRelaysFileBytes bounds what the loader will read. The file is
// written by this process and edited, at most, by a hand; a megabyte is a
// thousand relays with room to spare, and anything past it is not this
// file.
const maxKnownRelaysFileBytes = 1 << 20

// KnownRelays remembers, per relay address as configured, the fingerprint
// of the certificate it presented. Safe for concurrent use: the discovery
// leg and the session leg can verify in parallel, and both may record.
//
// A nil *KnownRelays behaves as an in-memory store (see Core.KnownRelays):
// the first connection in the process trusts and remembers, and no later
// one in the same process is unchecked. So no code path ever trusts
// blindly, and a Core built without a store -- every existing test -- works
// unchanged.
type KnownRelays struct {
	// Logf receives the three lines this store writes: first trust, a
	// changed identity, and a file it could not write. Nil means log.Printf.
	Logf func(format string, args ...any)

	mu      sync.Mutex
	path    string // "" means memory only
	entries map[string]knownRelay
	loaded  bool
	loadErr error
	// writeFailed is set after the first failed save so a read-only install
	// warns once, not on every connection.
	writeFailed bool
}

// knownRelay is one entry as written to the file. The times are for a human
// reading the file; the loader trusts only the fingerprint.
type knownRelay struct {
	Fingerprint string `json:"fingerprint"`
	FirstSeen   string `json:"first_seen,omitempty"`
	LastChanged string `json:"last_changed,omitempty"`
}

type knownRelaysFile struct {
	Version int                   `json:"version"`
	Relays  map[string]knownRelay `json:"relays"`
}

// NewKnownRelays returns a store backed by the file at path, read on first
// use and rewritten atomically on every change. An empty path is memory
// only.
func NewKnownRelays(path string) *KnownRelays {
	return &KnownRelays{path: path}
}

// NewKnownRelaysInDir is NewKnownRelays for the conventional place: beside
// the config.json in dir.
func NewKnownRelaysInDir(dir string) *KnownRelays {
	return NewKnownRelays(filepath.Join(dir, KnownRelaysFileName))
}

// Path is where the store persists, or "" for memory only.
func (k *KnownRelays) Path() string {
	if k == nil {
		return ""
	}
	return k.path
}

func (k *KnownRelays) logf(format string, args ...any) {
	if k != nil && k.Logf != nil {
		k.Logf(format, args...)
		return
	}
	log.Printf(format, args...)
}

// Lookup reports the fingerprint remembered for addr, if any.
func (k *KnownRelays) Lookup(addr string) (string, bool) {
	if k == nil {
		return "", false
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.loadLocked(); err != nil {
		return "", false
	}
	e, ok := k.entries[addr]
	return e.Fingerprint, ok
}

// Verifier returns the tlsx.Verifier for connections to the relay
// configured as addr -- the SAME addr for every leg to that relay, tcp
// discovery, tcp session and quic session alike, whatever port the session
// leg dials. One relay has one identity (its tcp and quic listeners serve
// one certificate since 2026-09-15), so one entry covers all of them.
func (k *KnownRelays) Verifier(addr string) tlsx.Verifier {
	return func(leafDER []byte) error {
		return k.verify(addr, tlsx.Fingerprint(leafDER))
	}
}

func (k *KnownRelays) verify(addr, fp string) error {
	// A nil store is legal (Core.KnownRelays's doc): the zero-value in-memory
	// behaviour. The Core allocates one on first use so that nil never reaches
	// here from production code, but a caller holding a nil pointer must not
	// crash -- and must not be trusted blindly either, so it errs.
	if k == nil {
		return errors.New("core: no known-relays store -- refusing to trust a relay without one")
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.loadLocked(); err != nil {
		// A corrupt file is refused, not overwritten: whoever can write it can
		// also change a fingerprint in it, so a file that does not parse is a
		// question for the player, named here, not something to quietly
		// replace.
		return fmt.Errorf("core: %w", err)
	}
	now := time.Now().UTC().Format(time.RFC3339)
	known, ok := k.entries[addr]
	switch {
	case !ok:
		k.entries[addr] = knownRelay{Fingerprint: fp, FirstSeen: now}
		k.saveLocked()
		k.logf("core: trusting server %s, fingerprint %s (first connection; remembered in %s -- "+
			"from now on a different certificate at this address is warned about)", addr, fp, k.whereLocked())
		return nil
	case known.Fingerprint == fp:
		return nil
	default:
		k.entries[addr] = knownRelay{Fingerprint: fp, FirstSeen: known.FirstSeen, LastChanged: now}
		k.saveLocked()
		k.logf("core: WARNING: the server at %s has a DIFFERENT identity than the one remembered.\n"+
			"    remembered: %s\n"+
			"    presented:  %s\n"+
			"  If the host reinstalled or moved the server, this is expected and the new identity is "+
			"now remembered. If they did not, something between you and the server may be "+
			"impersonating it -- ask the host to compare the fingerprint their server prints at "+
			"startup with the one presented above. The connection is going ahead, encrypted, "+
			"because this client has no way yet to prove which it is (%s).", addr, known.Fingerprint, fp,
			k.whereLocked())
		return nil
	}
}

func (k *KnownRelays) whereLocked() string {
	if k.path == "" {
		return "this process only; no file configured"
	}
	return k.path
}

// loadLocked reads the file once. A missing file is an empty store; an
// unreadable or unparsable one is an error every later call repeats.
func (k *KnownRelays) loadLocked() error {
	if k.loaded {
		return k.loadErr
	}
	k.loaded = true
	k.entries = map[string]knownRelay{}
	if k.path == "" {
		return nil
	}
	data, err := os.ReadFile(k.path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		k.loadErr = fmt.Errorf("the known-servers file %s cannot be read: %w", k.path, err)
		return k.loadErr
	}
	entries, err := parseKnownRelays(data)
	if err != nil {
		k.loadErr = fmt.Errorf("the known-servers file %s does not parse: %w (fix it, or delete it to "+
			"forget every remembered server -- each will then be trusted again on its next connection)",
			k.path, err)
		return k.loadErr
	}
	k.entries = entries
	return nil
}

// parseKnownRelays decodes the file's bytes. Every fingerprint is
// normalized through tlsx.NormalizeFingerprint, so a hand-edited entry with
// colons or capitals compares equal to what a relay presents; an entry that
// is not a fingerprint at all is an error rather than an entry that can
// never match. Never panics on any input (FuzzKnownRelaysFileNeverPanics).
func parseKnownRelays(data []byte) (map[string]knownRelay, error) {
	if len(data) > maxKnownRelaysFileBytes {
		return nil, fmt.Errorf("%d bytes is far larger than this file ever is", len(data))
	}
	var f knownRelaysFile
	if err := json.Unmarshal(data, &f); err != nil {
		return nil, err
	}
	if f.Version != knownRelaysFileVersion {
		return nil, fmt.Errorf("version %d is not the %d this build writes", f.Version, knownRelaysFileVersion)
	}
	out := make(map[string]knownRelay, len(f.Relays))
	for addr, e := range f.Relays {
		if addr == "" {
			return nil, errors.New("an entry has an empty address")
		}
		fp, err := tlsx.NormalizeFingerprint(e.Fingerprint)
		if err != nil {
			return nil, fmt.Errorf("entry %q: %w", addr, err)
		}
		if fp == "" {
			return nil, fmt.Errorf("entry %q has no fingerprint", addr)
		}
		e.Fingerprint = fp
		out[addr] = e
	}
	return out, nil
}

// saveLocked writes the whole store atomically. A failure is logged once
// and the store keeps working in memory: an install on read-only media
// still plays, it just re-trusts on the next launch.
func (k *KnownRelays) saveLocked() {
	if k.path == "" {
		return
	}
	data, err := json.MarshalIndent(knownRelaysFile{Version: knownRelaysFileVersion, Relays: k.entries}, "", "  ")
	if err != nil {
		k.noteWriteFailureLocked(err)
		return
	}
	if err := os.MkdirAll(filepath.Dir(k.path), 0o700); err != nil {
		k.noteWriteFailureLocked(err)
		return
	}
	if err := tlsx.WriteFileAtomic(k.path, append(data, '\n'), 0o644); err != nil {
		k.noteWriteFailureLocked(err)
		return
	}
}

func (k *KnownRelays) noteWriteFailureLocked(err error) {
	if k.writeFailed {
		return
	}
	k.writeFailed = true
	k.logf("core: WARNING: could not write the known-servers file %s: %v -- servers are remembered "+
		"for this run only, so every launch trusts the server it connects to as if for the first "+
		"time", k.path, err)
}
