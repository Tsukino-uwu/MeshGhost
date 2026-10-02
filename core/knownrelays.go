package core

// The client's memory of which relay is which: trust on first use, the SSH model. A relay's certificate is
// self-signed and connect_to is a bare IP, so a client remembers the fingerprint it first saw and notices a change. A
// change is warned about and allowed, because refusing would need a manual step every time a host reinstalls; a room
// code set on both ends is what proves the relay's identity.

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
)

// KnownRelaysFileName is the store's file, beside the client's config.json: a memory, not a secret.
const KnownRelaysFileName = "known_servers.json"

// knownRelaysFileVersion is written into every file and checked on read.
const knownRelaysFileVersion = 1

// maxKnownRelaysFileBytes bounds what the loader reads: a megabyte is a thousand relays with room to spare.
const maxKnownRelaysFileBytes = 1 << 20

// KnownRelays remembers, per relay address as configured, the fingerprint of the certificate it presented. Safe for
// concurrent use: the discovery and session legs may verify and record in parallel. A Core with no store gets an
// in-memory one; a nil *KnownRelays refuses to verify rather than trust blindly.
type KnownRelays struct {
	// Logf receives the store's three lines: first trust, a changed identity, an unwritable file. Nil means
	// log.Printf.
	Logf func(format string, args ...any)

	mu      sync.Mutex
	path    string // "" means memory only
	entries map[string]knownRelay
	loaded  bool
	loadErr error
	// writeFailed makes a read-only install warn once, not on every connection.
	writeFailed bool
}

// knownRelay is one entry in the file; the times are for a person reading it, and the loader trusts only the
// fingerprint.
type knownRelay struct {
	Fingerprint string `json:"fingerprint"`
	FirstSeen   string `json:"first_seen,omitempty"`
	LastChanged string `json:"last_changed,omitempty"`
}

type knownRelaysFile struct {
	Version int                   `json:"version"`
	Relays  map[string]knownRelay `json:"relays"`
}

// NewKnownRelays returns a store backed by the file at path, read on first use and rewritten atomically on every
// change. An empty path is memory only.
func NewKnownRelays(path string) *KnownRelays {
	return &KnownRelays{path: path}
}

// NewKnownRelaysInDir is NewKnownRelays beside the config.json in dir.
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

// Verifier returns the tlsx.Verifier for the relay configured as addr: the same addr for every leg, whatever port it
// dials, because one relay serves one certificate on every listener.
func (k *KnownRelays) Verifier(addr string) tlsx.Verifier {
	return func(leafDER []byte) error {
		return k.verify(addr, tlsx.Fingerprint(leafDER))
	}
}

func (k *KnownRelays) verify(addr, fp string) error {
	// The Core never passes nil; a caller that does must neither crash nor trust blindly.
	if k == nil {
		return errors.New("core: no known-relays store -- refusing to trust a relay without one")
	}
	k.mu.Lock()
	defer k.mu.Unlock()
	if err := k.loadLocked(); err != nil {
		// A corrupt file is refused, not overwritten: whoever can write it can also change a fingerprint in it.
		return fmt.Errorf("core: %w", err)
	}
	now := time.Now().UTC().Format(time.RFC3339) // wall-clock: a timestamp for a human reading the file, never compared
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
			"because a certificate alone cannot prove which it is; a room code set on both ends "+
			"can, and a server that asks for none proves nothing (%s).", addr, known.Fingerprint, fp,
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

// loadLocked reads the file once. A missing file is an empty store; an unreadable or unparsable one is an error every
// later call repeats.
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
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ENOTDIR) {
		// No file yet, including a path component that is a file: Windows reports that as not found, Linux as
		// ENOTDIR, which os.ErrNotExist does not match.
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

// parseKnownRelays decodes the file. Fingerprints are normalized, so a hand-edited entry with colons or capitals still
// matches; an entry that is not a fingerprint is an error rather than an entry that can never match.
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

// saveLocked writes the whole store atomically. A failure is logged once and the store keeps working in memory, so a
// read-only install still plays.
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
