package core

// protocol.ValidateState bounds every field of a state, only on receive, and never the line it is sent on. A legal
// state too long as a line ends the relay's read loop with no reject and the player reconnects under a new
// player_id, so these tests pin what sendState does with one.

import (
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// lineTransport keeps the raw wire lines, since decoding them back into a protocol.State would lose their length.
// sent() waits for core's relay writer to drain first.
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

// maximalState builds the largest state protocol.ValidateState accepts: every opaque string at its cap, the full
// position vector, and positions long in decimal. tag varies the contents, so a prev built against another state
// differs in every field.
func maximalState(tag byte) protocol.State {
	fill := func(n int) string { return strings.Repeat(string(tag), n) }
	pos := make([]float64, protocol.MaxPositionLen)
	for i := range pos {
		// Inside MaxPositionComponent: a position is only as big on the wire as its digits.
		pos[i] = -1234567.1234567 - float64(i) - float64(tag)/1000
	}
	// JSONWireLen counts marshalled bytes, so the quotes, and for extras the key and braces, are in the budget.
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

// TestAMaximalLegalStateWithAPrevExceedsTheLineLimit: a state protocol.ValidateState accepts and the wire cannot
// carry, the measurement the send-side check rests on.
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

// TestAnOversizedStateIsNotSentAsIs: a state that will not fit never goes on the wire as is, which would cost the
// connection and the player_id rather than the frame; dropping its prev is enough here.
func TestAnOversizedStateIsNotSentAsIs(t *testing.T) {
	c := New()
	lt := &lineTransport{core: c}
	// sendState queues onto the current connection's writer, so the transport under test must be that connection.
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

// TestAStateTooBigEvenWithoutItsPrevIsNotSentAtAll: with nothing left to shed the state is not sent, losing one frame
// rather than the session. The fixture is over the field caps too, which is realistic: nothing between an adapter's
// local_state and sendState checks them, so a mod packing an oversized extras map gets here.
func TestAStateTooBigEvenWithoutItsPrevIsNotSentAtAll(t *testing.T) {
	c := New()
	lt := &lineTransport{core: c}
	// sendState queues onto the current connection's writer, so the transport under test must be that connection.
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
