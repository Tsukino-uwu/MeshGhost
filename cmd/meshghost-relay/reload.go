package main

// The relay's config.json is live for three settings: room_code, only_game and
// max_clients. Until 2026-09-15 the relay read its file once, so changing the
// room code -- the one thing a host does when a code leaks -- meant a restart
// that dropped every player (fourth adversarial review, B4). The client had
// re-read its own config since 2026-09-09 (cmd/meshghost/reload.go); this is the same
// poll (internal/cfg.FileWatch) with the relay's own idea of what a change
// means.
//
// Applied without disconnecting anyone: a new room code gates the next hello, a
// lowered max_clients refuses the next join. Everything else in the file needs a
// relaunch and is reported as such, and -- as on the client -- a relaunch-only
// value that changed does NOT carry forward, so a later edit of some other key
// does not quietly apply it.

import (
	"fmt"
	"log"
	"strings"

	"github.com/Tsukino-uwu/MeshGhost/internal/cfg"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// relayLive is every server setting as a value: the three live ones and the
// relaunch-only ones, so a diff can name what changed either way.
type relayLive struct {
	roomCode   string
	onlyGame   string
	maxClients int

	addr, transport, quicAddr, udpAddr, legacyTLS, ghostCollision string
	sendHz, resumeGrace                                           int
	qlog                                                          bool
}

// targets points a configTargets at a relayLive, so applyFileConfig fills a
// value copy exactly as it fills the flag variables at startup.
func (l *relayLive) targets() configTargets {
	return configTargets{
		addr: &l.addr, roomCode: &l.roomCode, onlyGame: &l.onlyGame, maxClients: &l.maxClients,
		sendHz: &l.sendHz, ghostCollision: &l.ghostCollision, resumeGrace: &l.resumeGrace,
		transport: &l.transport, quicAddr: &l.quicAddr, udpAddr: &l.udpAddr, legacyTLS: &l.legacyTLS,
		qlog: &l.qlog,
	}
}

// snapshotRelayLive copies the current values out of a configTargets.
func snapshotRelayLive(t configTargets) relayLive {
	return relayLive{
		roomCode: *t.roomCode, onlyGame: *t.onlyGame, maxClients: *t.maxClients,
		addr: *t.addr, transport: *t.transport, quicAddr: *t.quicAddr, udpAddr: *t.udpAddr,
		legacyTLS: *t.legacyTLS, ghostCollision: *t.ghostCollision, sendHz: *t.sendHz,
		resumeGrace: *t.resumeGrace, qlog: *t.qlog,
	}
}

// watcherSeed is what the watcher treats as live at startup: the running values,
// except the two listen addresses as the FILE wrote them. main resolves those in
// place (an empty listen_quic becomes the shared port), and a re-read can only
// ever yield the raw value, so seeding the resolved one made every save report
// listen_quic as changed (2026-09-16).
func watcherSeed(t configTargets, fileQuicAddr, fileUDPAddr string) relayLive {
	live := snapshotRelayLive(t)
	live.quicAddr, live.udpAddr = fileQuicAddr, fileUDPAddr
	return live
}

// relayConfigWatcher re-reads the file on a settled save and applies the diff.
type relayConfigWatcher struct {
	path     string
	explicit map[string]bool
	base     relayLive // the flag values before the file: what a re-read starts from
	prev     relayLive // what is live now
	server   *relay.Server
	fw       *cfg.FileWatch
}

func newRelayConfigWatcher(path string, explicit map[string]bool, base, live relayLive, s *relay.Server) *relayConfigWatcher {
	return &relayConfigWatcher{path: path, explicit: explicit, base: base, prev: live, server: s,
		fw: cfg.NewFileWatch(path)}
}

func (w *relayConfigWatcher) run(stop <-chan struct{}) {
	w.fw.Run(stop, func() { w.reload() })
}

// poll looks at the file once and applies a settled change. For tests.
func (w *relayConfigWatcher) poll() {
	if w.fw.Poll() {
		w.reload()
	}
}

// reload re-reads the file into a fresh copy of the flag values, applies
// what changed, and logs one line per changed key.
func (w *relayConfigWatcher) reload() []string {
	// A save that went wrong keeps what is live: re-reading from the defaults
	// would turn a room code OFF over one stray comma (cfg.ReloadRefusal).
	if why := cfg.ReloadRefusal(w.path, "meshghost-relay", "server"); why != "" {
		log.Printf("meshghost-relay: config.json was saved but %s -- NOTHING changed: every server setting "+
			"stays as it is running; fix the file and save again", why)
		return nil
	}
	next := w.base
	applyFileConfig(w.path, w.explicit, next.targets())
	next.roomCode = strings.TrimSpace(next.roomCode) // as main trims it
	next.onlyGame = strings.TrimSpace(next.onlyGame)
	lines := applyRelayLive(&w.prev, &next, w.server)
	if len(lines) == 0 {
		log.Printf("meshghost-relay: config.json was saved with no server setting changed")
	}
	for _, l := range lines {
		log.Printf("meshghost-relay: config.json changed: %s", l)
	}
	// The relaunch-only keys do not carry forward (the client's reload.go says
	// why at length): what is live stays live until a relaunch reads the file
	// from the top, so a second edit of any other key cannot quietly apply a
	// change that was reported as needing a relaunch.
	live := w.prev
	w.prev = next
	w.prev.addr, w.prev.transport, w.prev.quicAddr, w.prev.udpAddr = live.addr, live.transport, live.quicAddr, live.udpAddr
	w.prev.legacyTLS, w.prev.ghostCollision, w.prev.sendHz, w.prev.resumeGrace, w.prev.qlog =
		live.legacyTLS, live.ghostCollision, live.sendHz, live.resumeGrace, live.qlog
	return lines
}

// applyRelayLive hands every changed live setting to the server and returns
// one line per changed key, relaunch-only ones included.
func applyRelayLive(prev, next *relayLive, s *relay.Server) []string {
	var lines []string
	if prev.roomCode != next.roomCode {
		s.SetRoomCode(next.roomCode)
		switch {
		case next.roomCode == "":
			lines = append(lines, "room_code removed (applied: anyone with the address can join now; nobody was disconnected)")
		case prev.roomCode == "":
			lines = append(lines, "room_code set (applied to every hello from now on; the value is not logged; nobody was disconnected)")
		default:
			lines = append(lines, "room_code changed (applied to every hello from now on; the value is not logged; nobody was disconnected)")
		}
	}
	if prev.onlyGame != next.onlyGame {
		s.SetOnlyGame(next.onlyGame)
		lines = append(lines, fmt.Sprintf("only_game %q -> %q (applied to the next hello; nobody was disconnected)", prev.onlyGame, next.onlyGame))
	}
	if prev.maxClients != next.maxClients {
		eff := relay.EffectiveMaxClients(next.maxClients)
		s.SetMaxClients(eff)
		lines = append(lines, fmt.Sprintf("max_clients %d -> %d (applied to the next join; nobody was disconnected)",
			relay.EffectiveMaxClients(prev.maxClients), eff))
	}
	relaunch := func(key string, a, b any) {
		if a != b {
			lines = append(lines, fmt.Sprintf("%s %v -> %v (needs a relaunch; the running value stays)", key, a, b))
		}
	}
	relaunch("listen_on", prev.addr, next.addr)
	relaunch("transport", prev.transport, next.transport)
	relaunch("listen_quic", prev.quicAddr, next.quicAddr)
	relaunch("listen_udp", prev.udpAddr, next.udpAddr)
	if prev.legacyTLS != next.legacyTLS {
		lines = append(lines, "tls: this key is obsolete (every connection is TLS since 2026-09-15); delete it")
	}
	relaunch("ghost_collision", prev.ghostCollision, next.ghostCollision)
	relaunch("send_hz", prev.sendHz, next.sendHz)
	relaunch("resume_grace_seconds", prev.resumeGrace, next.resumeGrace)
	relaunch("qlog", prev.qlog, next.qlog)
	return lines
}

// describeRelayReloadable is the startup line that says what a save changes.
func describeRelayReloadable(path string) string {
	return "meshghost-relay: " + strings.TrimSpace(path) + " is re-read when saved: room_code, only_game and " +
		"max_clients apply without a relaunch and without disconnecting anyone; every other server setting needs a relaunch"
}
