package core

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The two sockets the core reads, fuzzed as bytes. FuzzEverything composes only legal bridge frames, and every relay
// target fuzzes the relay reading a client, the opposite direction. A hostile relay is a real threat model, and the
// bridge socket is loopback with no authentication, so any process on the machine can write to it.

// fuzzLines splits a fuzz input into at most n NDJSON lines, since both surfaces receive a stream. Splitting lets the
// engine build sequences, such as a welcome, a join, then a state for the id that join named.
func fuzzLines(data []byte, n int) [][]byte {
	parts := bytes.Split(data, []byte("\n"))
	if len(parts) > n {
		parts = parts[:n]
	}
	return parts
}

// FuzzHostileRelayLines feeds arbitrary bytes to the core's relay dispatch, as a hostile relay would. A fresh Core per
// execution and no goroutines: handleRelayMessage is the whole inbound path and takes a nil conn, so no socket is
// needed and this runs in CI's campaign and under the race job.
func FuzzHostileRelayLines(f *testing.F) {
	env := func(t protocol.MessageType, payload string) string {
		return fmt.Sprintf(`{"type":%q,"payload":%s}`, t, payload)
	}
	f.Add(env(protocol.TypeWelcome, `{"player_id":"p1","roster":["p2"],"send_hz":15}`))
	f.Add(env(protocol.TypeWelcome, `{"player_id":"","roster":[]}`) + "\n" +
		env(protocol.TypeWelcome, `{"player_id":"p9"}`))
	// The ids a hostile relay would choose: this core's own namespaces, and an unbounded one.
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
	// The opt-in planes are reachable only once a welcome has agreed them, so they go behind one.
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

		// A relay cannot talk this core into an unbounded roster: the seats bound every map keyed by a peer id.
		if n := len(c.roster); n > protocol.MaxRosterSize {
			t.Fatalf("roster grew to %d seats, over the %d cap", n, protocol.MaxRosterSize)
		}
		// Nor mint an id in this core's own namespaces: a relay-supplied "chaser:1" would land in the buffer this
		// core's chaser feeds, and the stale age-out skips local ids, so the ghost would never despawn and the seat
		// never free.
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
		// The id the relay gives this core gets the same gate as its peers', checked on every Welcome that reaches the
		// connect path, which adopts it.
		for len(welcome) > 0 {
			if w := <-welcome; !acceptableRelayPeerID(w.PlayerID) {
				t.Fatalf("a welcome naming this core %q reached the connect path, which adopts it as its own player_id", w.PlayerID)
			}
		}
		// The clock offset is bounded, or every render time runs past every sample any peer has sent and the room
		// edge-holds.
		if c.clock.offsetMs > maxClockOffsetMs || c.clock.offsetMs < -maxClockOffsetMs {
			t.Fatalf("clock offset %d ms is outside ±%d", c.clock.offsetMs, maxClockOffsetMs)
		}
	})
}

// FuzzHostileBridgeLines feeds arbitrary bytes to the bridge socket, the protocol with no authentication, through the
// real ServeBridge on a pipeListener. The property is liveness: an adapter is a script a player edits, so a malformed
// line is ordinary, and the core must refuse it and keep serving, never panic or wedge.
// TestTheBridgeIgnoresAConnectionThatNeverSaidHello pins the hello rule.
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
	// The first line that is not NDJSON closes the connection, so an HTTP request cannot get past it.
	f.Add("POST / HTTP/1.1\r\nHost: 127.0.0.1:7778\r\n\r\n")
	f.Add(`{`)
	f.Add(``)

	// One core and one listener for the whole campaign: the property is about a connection, not a core's accumulated
	// state.
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
				// The core hung up, which for many of these inputs is the correct answer.
				break
			}
		}
		conn.Close()

		// Liveness: a real adapter can still attach after whatever that was. A core that quietly stopped serving its
		// bridge looks exactly like a game with no ghosts in it.
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
		// And it answers: a pipe write succeeds once the transport's read goroutine takes the bytes, before dispatch,
		// so only an answer proves the dispatch is not wedged.
		_ = good.SetReadDeadline(time.Now().Add(2 * time.Second))
		if _, err := bufio.NewReader(good).ReadString('\n'); err != nil {
			t.Fatalf("the bridge accepted a hello after %q and never answered it: %v", stream, err)
		}
	})
}
