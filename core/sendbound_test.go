package core

// The send side of protocol.MaxLineBytes.
//
// protocol.ValidateState bounds every FIELD of a state and nothing bounds the
// LINE the state is sent on, and all three of ValidateState's call sites are on
// RECEIVE. Until 2026-09-08 the core marshalled a state and handed it to the
// transport without ever measuring it, so a state that is legal field by field
// and too long as a line was written to the relay -- whose read loop answers an
// over-long line with bufio.ErrTooLong, ending the loop and dropping the whole
// connection with no reject. The core reads that as a transient EOF, reconnects,
// is issued a new player_id, and every peer sees the player despawn and respawn,
// once per reconnect, for as long as the game stays in that state.
//
// These tests build the state that does it and pin what sendState does with it.

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// lineTransport keeps the raw wire lines it was handed, because the whole
// question here is how long they are -- a transport that decoded them back into
// a protocol.State (as core/suppress_test.go's does) would throw away the one
// fact under test.
// core is what has to have drained before lines() is the whole answer -- see
// capturingTransport.core.
type lineTransport struct {
	core *Core

	mu    sync.Mutex
	lines [][]byte
}

func (lt *lineTransport) Send(payload []byte) error {
	lt.mu.Lock()
	defer lt.mu.Unlock()
	lt.lines = append(lt.lines, append([]byte(nil), payload...))
	return nil
}

func (lt *lineTransport) SendUnreliable(payload []byte) error { return lt.Send(payload) }
func (lt *lineTransport) OnReceive(func([]byte))              {}
func (lt *lineTransport) OnDisconnect(func(error))            {}
func (lt *lineTransport) OnError(func(error))                 {}
func (lt *lineTransport) Close() error                        { return nil }

func (lt *lineTransport) sent() [][]byte {
	lt.core.waitRelayDrained()
	lt.mu.Lock()
	defer lt.mu.Unlock()
	out := make([][]byte, len(lt.lines))
	copy(out, lt.lines)
	return out
}

// maximalState builds the largest state protocol.ValidateState accepts: every
// opaque string at its own cap, the full position vector, and finite position
// components written at full width so the numbers are as long on the wire as
// they are allowed to be. tag varies the CONTENTS so a prev built from one of
// these against another differs in every field, which is the case that produced
// the measured 4167 bytes.
func maximalState(tag byte) protocol.State {
	fill := func(n int) string { return strings.Repeat(string(tag), n) }
	pos := make([]float64, protocol.MaxPositionLen)
	for i := range pos {
		// Inside MaxPositionComponent (1e7) and deliberately long in decimal:
		// a position is only as big on the wire as its digits.
		pos[i] = -1234567.1234567 - float64(i) - float64(tag)/1000
	}
	// JSONWireLen counts the marshalled bytes, so the two quotes are part of
	// the budget for orientation, and the key, quotes, colon and braces are
	// part of it for extras.
	orientation := json.RawMessage(`"` + fill(protocol.MaxOrientationBytes-2) + `"`)
	extras := map[string]any{"x": fill(protocol.MaxExtrasBytes - len(`{"x":""}`))}
	return protocol.State{
		PlayerID:    "player-0001",
		Seq:         4294967295,
		Timestamp:   1788888888888,
		AreaID:      fill(protocol.MaxAreaIDLen),
		Anim:        fill(protocol.MaxAnimLen),
		Position:    pos,
		Orientation: orientation,
		Extras:      extras,
	}
}

// TestAMaximalLegalStateWithAPrevExceedsTheLineLimit is the measurement the
// fix rests on, kept as a test so it cannot rot: this is the state
// protocol.ValidateState says yes to and the wire cannot carry.
func TestAMaximalLegalStateWithAPrevExceedsTheLineLimit(t *testing.T) {
	st := maximalState('a')
	other := maximalState('b')
	if !protocol.ValidateState(st) {
		t.Fatal("the fixture is not a legal state -- it must be the LEGAL one that is too long")
	}
	st.Prev = protocol.BuildPrev(&other, &st)
	payload, err := json.Marshal(st)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	env := protocol.AppendEnvelope(nil, protocol.TypeState, payload)
	if len(env) <= protocol.MaxLineBytes {
		t.Fatalf("envelope is %d bytes, expected it to exceed the %d-byte line limit -- if a "+
			"protocol/ bound moved, this test and the send-side check it justifies need re-measuring",
			len(env), protocol.MaxLineBytes)
	}
	t.Logf("maximal legal state + prev serializes to %d bytes against a %d-byte line limit",
		len(env), protocol.MaxLineBytes)
}

// TestAnOversizedStateIsNotSentAsIs is the regression: whatever sendState does
// with a state that will not fit, the one thing it may never do is put it on
// the wire, because that costs the connection and the player_id rather than the
// frame.
func TestAnOversizedStateIsNotSentAsIs(t *testing.T) {
	c := New()
	lt := &lineTransport{core: c}
	// sendState queues onto the CURRENT connection's writer since 2026-09-11,
	// so the transport under test has to be that connection.
	c.relay = lt

	st := maximalState('a')
	other := maximalState('b')
	st.Prev = protocol.BuildPrev(&other, &st)
	c.sendState(lt, st)

	lines := lt.sent()
	if len(lines) != 1 {
		t.Fatalf("sent %d lines, want exactly 1 -- dropping the prev is enough to fit", len(lines))
	}
	if len(lines[0]) > protocol.MaxLineBytes {
		t.Fatalf("sent a %d-byte line against a %d-byte limit: the relay answers that with "+
			"bufio.ErrTooLong, drops the connection with no reject, and the player reconnects "+
			"under a new player_id", len(lines[0]), protocol.MaxLineBytes)
	}
	// And it is the state itself that survived, minus only its redundancy.
	var env protocol.Envelope
	if err := json.Unmarshal(lines[0], &env); err != nil {
		t.Fatalf("what was sent is not a valid envelope: %v", err)
	}
	var got protocol.State
	if err := json.Unmarshal(env.Payload, &got); err != nil {
		t.Fatalf("what was sent is not a valid state: %v", err)
	}
	if got.Prev != nil {
		t.Fatal("the prev is still attached -- it is the pure-redundancy field and the one to drop")
	}
	if got.AreaID != st.AreaID || got.Anim != st.Anim || len(got.Position) != len(st.Position) {
		t.Fatal("the state's own fields were altered; only the prev may be dropped")
	}
	if !protocol.ValidateState(got) {
		t.Fatal("what went out no longer passes ValidateState")
	}
}

// TestAStateTooBigEvenWithoutItsPrevIsNotSentAtAll pins the last resort. There
// is nothing left to shed at that point, and sending it anyway would take the
// session down instead of losing one frame.
//
// The fixture is over the FIELD caps as well as the line cap, and that is the
// realistic case rather than a contrived one: ValidateState's three call sites
// are all on receive, so nothing between an adapter's local_state and this
// function checks any of these bounds. An adapter packing an oversized extras
// map is the ordinary way to get here -- a bug in a mod, not an attack -- and
// what it used to buy was a relay connection dropped with no reject and a new
// player_id on every reconnect.
func TestAStateTooBigEvenWithoutItsPrevIsNotSentAtAll(t *testing.T) {
	c := New()
	lt := &lineTransport{core: c}
	// sendState queues onto the CURRENT connection's writer since 2026-09-11,
	// so the transport under test has to be that connection.
	c.relay = lt

	st := maximalState('a')
	st.Extras = map[string]any{"blob": strings.Repeat("x", 8*1024)}
	payload, err := json.Marshal(st)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if n := len(protocol.AppendEnvelope(nil, protocol.TypeState, payload)); n <= protocol.MaxLineBytes {
		t.Fatalf("the fixture is only %d bytes; it must exceed the %d-byte limit with no prev to give up",
			n, protocol.MaxLineBytes)
	}
	c.sendState(lt, st)

	if lines := lt.sent(); len(lines) != 0 {
		t.Fatalf("sent %d line(s) of %d bytes; a state that cannot fit must not be written at all",
			len(lines), len(lines[0]))
	}
}
