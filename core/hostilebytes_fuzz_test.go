package core

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The two sockets the CORE reads, fuzzed as bytes (2026-09-12).
//
// Twenty-six fuzz targets, and not one of them pushed arbitrary bytes into
// either of the two things the core actually reads from. `FuzzEverything`
// drives the bridge, but through a step machine that only ever composes LEGAL
// frames, and its relay is a recording stand-in that never delivers anything at
// all. Every relay target fuzzes the relay's inbound side -- the server reading
// a client -- which is the opposite direction.
//
// So the client's own two mouths were unfuzzed:
//
//   - **The relay connection.** `docs/security.md` treats a hostile relay as a
//     real threat model and this pass alone fixed five findings in that path
//     (P3a-3, P3a-5, P3a-6, B2, B3), every one of them about what the core does
//     with a line the relay chose. The instrument for that path did not exist.
//   - **The bridge socket.** Loopback with no authentication, deliberately and
//     documented -- so any process on the machine, and on a shared Windows box
//     any other user. Four adapters in three languages compose these lines by
//     hand.
//
// Found by the coverage cell of the third adversarial review (X2-4).

// fuzzLines splits a fuzz input into at most n NDJSON lines, which is how both
// of these surfaces really receive: a stream, not one message. Splitting rather
// than taking the whole input as one line is what lets the engine build
// SEQUENCES -- a welcome, then a join, then a state for the id that join named
// -- and every interesting thing either path does is stateful.
func fuzzLines(data []byte, n int) [][]byte {
	parts := bytes.Split(data, []byte("\n"))
	if len(parts) > n {
		parts = parts[:n]
	}
	return parts
}

// FuzzHostileRelayLines feeds arbitrary bytes to the core's relay dispatch, the
// way a relay that has decided to be hostile would.
//
// A fresh Core per execution, with no goroutines started: handleRelayMessage is
// the whole inbound path (welcome, join, leave, state, pong, and every opt-in
// plane), it takes a nil conn to mean "no connection context", and core_test.go
// already drives it directly. Nothing here needs a socket, so this runs in CI's
// campaign and under the race job.
func FuzzHostileRelayLines(f *testing.F) {
	env := func(t protocol.MessageType, payload string) string {
		return fmt.Sprintf(`{"type":%q,"payload":%s}`, t, payload)
	}
	f.Add(env(protocol.TypeWelcome, `{"player_id":"p1","roster":["p2"],"send_hz":15}`))
	f.Add(env(protocol.TypeWelcome, `{"player_id":"","roster":[]}`) + "\n" +
		env(protocol.TypeWelcome, `{"player_id":"p9"}`))
	// The ids a hostile relay would choose: this core's own namespaces, an
	// unbounded one, and one that is not valid UTF-8 shaped.
	f.Add(env(protocol.TypeWelcome, `{"player_id":"chaser:1"}`))
	f.Add(env(protocol.TypeJoin, `{"player_id":"replay:lap1"}`))
	f.Add(env(protocol.TypeJoin, `{"player_id":"`+strings.Repeat("p", 400)+`"}`))
	f.Add(env(protocol.TypeLeave, `{"player_id":"chaser:1"}`))
	f.Add(env(protocol.TypeWelcome, `{"player_id":"p1","roster":["p2","p3"]}`) + "\n" +
		env(protocol.TypeState, `{"player_id":"p2","seq":1,"timestamp":1000,"area_id":"a","position":[1,2],"anim":"x"}`) + "\n" +
		env(protocol.TypeLeave, `{"player_id":"p2"}`))
	// A state whose timestamp is the thing MaxTimestampMs exists for, and one
	// whose position is the thing IsValidPosition exists for.
	f.Add(env(protocol.TypeState, `{"player_id":"p2","timestamp":9223372036854775807,"position":[0,0]}`))
	f.Add(env(protocol.TypeState, `{"player_id":"p2","timestamp":1,"position":[1e308,-1e308]}`))
	// The clock, which the core turns into an offset and renders every ghost by.
	f.Add(env(protocol.TypePong, `{"client_time_ms":1,"server_time_ms":9223372036854775807}`))
	f.Add(env(protocol.TypePong, `{"client_time_ms":1,"server_time_ms":-9223372036854775808}`))
	// The opt-in planes, which are only reachable at all once a welcome has
	// agreed them -- so they go behind one.
	f.Add(env(protocol.TypeWelcome, `{"player_id":"p1","features":["event.v1","lease.v1","escrow.v1","world.v1"]}`) + "\n" +
		env(protocol.TypeEvent, `{"from":"p2","payload":{"a":1}}`) + "\n" +
		env(protocol.TypeLeaseState, `{"key":"k","holder":"p2","seq":1}`) + "\n" +
		env(protocol.TypeEscrowState, `{"id":"e","phase":"open","parties":["p2"]}`) + "\n" +
		env(protocol.TypeWorldState, `{"key":"w","seq":1,"authority":"p2"}`))
	f.Add(env(protocol.TypeReject, `{"reason":"bad room code","code":"room_code","retryable":false}`))
	f.Add(`{"type":"welcome"}`)
	f.Add(`{"type":123,"payload":[]}`)
	f.Add(`not json`)
	f.Add(``)

	f.Fuzz(func(t *testing.T, stream string) {
		c := New()
		c.mu.Lock()
		c.relayGame = "emerald"
		c.mu.Unlock()
		// Buffered and never read: the real caller hands these to the connect
		// path, and a nil channel would change the code under test.
		welcome := make(chan protocol.Welcome, 64)
		reject := make(chan protocol.Reject, 64)

		for _, line := range fuzzLines([]byte(stream), 16) {
			c.handleRelayMessage(nil, line, welcome, reject)
		}

		// Invariants a player would state, checked whatever arrived.
		c.mu.Lock()
		defer c.mu.Unlock()

		// A relay cannot talk this core into an unbounded roster: the seats are
		// the bound on every map keyed by a peer id.
		if n := len(c.roster); n > protocol.MaxRosterSize {
			t.Fatalf("roster grew to %d seats, over the %d cap", n, protocol.MaxRosterSize)
		}
		// And it cannot mint an id in THIS core's own namespaces, which is
		// P3a-6: a relay-supplied "chaser:1" lands its states in the buffer this
		// core's own chaser feeds, and the stale age-out skips local ids, so the
		// ghost never despawns and the seat never frees.
		for id := range c.roster {
			if !acceptableRelayPeerID(id) {
				t.Fatalf("a relay-announced id took a roster seat despite failing the shape gate: %q", id)
			}
		}
		for id := range c.remotes {
			if !acceptableRelayPeerID(id) {
				t.Fatalf("a relay-announced id got a remote buffer despite failing the shape gate: %q", id)
			}
		}
		// The id the relay gives US gets the same gate as the ones it gives our
		// peers, which it did not until 2026-09-12 (P3a-3).
		if c.playerID != "" && !acceptableRelayPeerID(c.playerID) {
			t.Fatalf("this core adopted %q as its own player_id", c.playerID)
		}
		// The clock offset is bounded, or every render time runs past every
		// sample any peer has sent and the room edge-holds (B2).
		if c.clock.offsetMs > maxClockOffsetMs || c.clock.offsetMs < -maxClockOffsetMs {
			t.Fatalf("clock offset %d ms is outside ±%d", c.clock.offsetMs, maxClockOffsetMs)
		}
	})
}

// FuzzHostileBridgeLines feeds arbitrary bytes to the bridge socket, which is
// the OTHER protocol and the one with no authentication at all.
//
// Through the real ServeBridge on a pipe listener, for the reason
// FuzzEverything gives: a listener and a connection per iteration exhausts
// Windows' ephemeral ports in seconds and the target then fails for a reason
// that has nothing to do with the bytes it was sending. The framing, the
// admission rule and every callback are the shipped code.
//
// The property is liveness, not a verdict. A bridge line is an adapter's, and
// an adapter is a Lua script a user edits, so a malformed one is the ordinary
// case: the core must refuse it and keep serving. What it must never do is
// panic, wedge, or let a connection that never introduced itself act for the
// player -- which is the rule added earlier the same day, and the one thing
// here with a verdict attached.
func FuzzHostileBridgeLines(f *testing.F) {
	f.Add(`{"type":"hello","payload":{"game_id":"emerald"}}`)
	f.Add(`{"type":"hello","payload":{"game_id":"emerald"}}` + "\n" +
		`{"type":"local_state","payload":{"state":{"area_id":"a","position":[1,2],"anim":"x"}}}`)
	// No hello at all, which the core must refuse to act on.
	f.Add(`{"type":"local_state","payload":{"state":{"area_id":"a","position":[1,2],"anim":"x"}}}`)
	f.Add(`{"type":"input_sample","payload":{"edges":[{"f":18446744073709551615,"t":1}]}}`)
	f.Add(`{"type":"hello","payload":{"game_id":"emerald"}}` + "\n" +
		`{"type":"input_sample","payload":{"edges":[{"f":1,"t":1},{"f":0,"t":0}]}}`)
	f.Add(`{"type":"hello","payload":{"game_id":"` + strings.Repeat("g", 400) + `"}}`)
	f.Add(`{"type":"replay_control","payload":{"action":"start"}}`)
	// The first line that is not NDJSON at all, which closes the connection --
	// an HTTP request cannot get past it (P4a-3).
	f.Add("POST / HTTP/1.1\r\nHost: 127.0.0.1:7778\r\n\r\n")
	f.Add(`{`)
	f.Add(``)

	// One core and one listener for the whole campaign: standing them up per
	// execution is the cost FuzzEverything's pipeListener comment describes,
	// and the property here is about a connection rather than about a core's
	// accumulated state.
	c := New()
	ln := newPipeListener()
	f.Cleanup(func() { ln.Close() })
	go c.ServeBridge(ln)
	f.Cleanup(func() { c.StopReplays(); c.StopChasers(); c.StopRecording() })

	f.Fuzz(func(t *testing.T, stream string) {
		conn, err := ln.dial()
		if err != nil {
			t.Skipf("dial the bridge: %v", err)
		}
		defer conn.Close()
		_ = conn.SetWriteDeadline(time.Now().Add(2 * time.Second))

		for _, line := range fuzzLines([]byte(stream), 16) {
			if _, err := conn.Write(append(append([]byte{}, line...), '\n')); err != nil {
				// The core hung up, which for a great many of these inputs is
				// the CORRECT answer -- see the first-line rule.
				break
			}
		}
		conn.Close()

		// Liveness: a real adapter can still attach and be acted for, after
		// whatever that was. This is the assertion -- a core that panicked is
		// loud, and a core that quietly stopped serving its bridge looks
		// exactly like a game with no ghosts in it.
		good, err := ln.dial()
		if err != nil {
			t.Fatalf("the bridge stopped accepting connections after %q: %v", stream, err)
		}
		defer good.Close()
		_ = good.SetWriteDeadline(time.Now().Add(2 * time.Second))
		hello, err := json.Marshal(map[string]any{
			"type":    "hello",
			"payload": map[string]any{"game_id": "emerald"},
		})
		if err != nil {
			t.Fatalf("marshal hello: %v", err)
		}
		if _, err := good.Write(append(hello, '\n')); err != nil {
			t.Fatalf("the bridge refused a well-formed hello after %q: %v", stream, err)
		}
	})
}
