package udpconn

// The world plane's bounds are DERIVED from this package's own constants, not
// chosen. They live in protocol, which has no internal dependencies by
// design and therefore cannot see reorderWindow or the framing sizes at all —
// so the relationship is asserted here, in the one package that can, the same
// discipline RateLimitHeadroomMultiple already follows.
//
// **These are the tests that would have caught the pre-existing sizing bug.**
// MaxEventBytes' own comment claims it was sized to fit under MaxDatagramBytes
// and it is not: a maximal Event marshals to 1441 bytes and cannot be
// delivered to a udp peer at all, failing checkWritable with nothing but a log
// line. Shrinking those constants is a contract change with its own trade-offs,
// so it is recorded in agent_docs/risks.md as its own decision rather than made
// here — but the assertion below is the shape that should be retrofitted to
// events and escrow when it is taken.

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// maximalWorldStateLine is the largest single-entry world message the protocol
// permits, rendered exactly as the relay would put it on the wire.
func maximalWorldStateLine(t *testing.T) int {
	t.Helper()
	// A JSON string of exactly MaxWorldBlobBytes, quotes included, is the
	// biggest blob that passes validation.
	blob := json.RawMessage(`"` + strings.Repeat("x", protocol.MaxWorldBlobBytes-2) + `"`)
	if len(blob) != protocol.MaxWorldBlobBytes {
		t.Fatalf("built a %d-byte blob, want %d", len(blob), protocol.MaxWorldBlobBytes)
	}
	st := protocol.WorldState{
		Authority: strings.Repeat("a", protocol.MaxLeaseKeyLen),
		Holder:    strings.Repeat("p", 16),
		Seq:       ^uint64(0),
		Reason:    protocol.WorldSnapshot,
		Entries: []protocol.WorldEntry{{
			Key:  strings.Repeat("k", protocol.MaxWorldKeyLen),
			Blob: blob,
		}},
	}
	payload, err := json.Marshal(st)
	if err != nil {
		t.Fatalf("marshal world_state: %v", err)
	}
	line, err := json.Marshal(protocol.Envelope{Type: protocol.TypeWorldState, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	return len(line)
}

// TestMaximalWorldStateFitsAUDPDatagram is the assertion the world plane's
// bounds were derived from.
//
// checkWritable refuses any datagram over MaxDatagramBytes minus its framing,
// INCLUDING a reliable one, and the refusal surfaces only as a "relay: send to
// pX failed:" line in the relay's log — so a message that does not fit is lost
// for that recipient, silently, and is never superseded. A custody message that
// vanished that way would leave one client permanently looking at a different
// world.
func TestMaximalWorldStateFitsAUDPDatagram(t *testing.T) {
	// The reliable path's framing: a two-byte header, the session token, and
	// the sequence number. See Conn.Write's own call to checkWritable.
	const framing = 2 + tokenLen + seqLen

	line := maximalWorldStateLine(t)
	if line+framing > MaxDatagramBytes {
		t.Fatalf("a maximal world_state is %d bytes and needs %d with framing, over the %d-byte "+
			"datagram limit -- it would be silently undeliverable to every udp peer. Shrink "+
			"protocol.MaxWorldBlobBytes.", line, line+framing, MaxDatagramBytes)
	}
	if err := (&Conn{}).checkWritable(make([]byte, line), framing); err != nil {
		t.Fatalf("checkWritable refused a maximal world_state: %v", err)
	}
}

// TestBatchedWorldStateFitsAUDPDatagram covers the other size path: a message
// packed up to protocol.MaxWorldMessageBytes by the relay's batching, rather
// than one maximal entry.
func TestBatchedWorldStateFitsAUDPDatagram(t *testing.T) {
	const framing = 2 + tokenLen + seqLen
	if protocol.MaxWorldMessageBytes+framing > MaxDatagramBytes {
		t.Fatalf("protocol.MaxWorldMessageBytes (%d) plus %d bytes of framing exceeds the %d-byte "+
			"datagram limit", protocol.MaxWorldMessageBytes, framing, MaxDatagramBytes)
	}
}

// TestWorldSnapshotNeverExceedsTheReorderWindow is why MaxWorldKeysPerRoom is
// 64 and not a round number somebody liked.
//
// A snapshot is delivered reliably and can be as wide as one message per entity
// in the pathological case. A reliable burst wider than the receiver's reorder
// window is not held, is therefore not acked, and the sender retries it at
// retryInterval for maxRetries before giving up and CLOSING THE CONNECTION — so
// raising the room cap without raising the window turns a large world into a
// disconnect at exactly the moment a new host adopts it.
func TestWorldSnapshotNeverExceedsTheReorderWindow(t *testing.T) {
	if protocol.MaxWorldKeysPerRoom > reorderWindow {
		t.Fatalf("protocol.MaxWorldKeysPerRoom is %d but this package's reorderWindow is %d -- a "+
			"worst-case adoption snapshot would overflow the receiver's window, go unacked, and "+
			"be retried until the connection is closed. Raise reorderWindow first, or lower the cap.",
			protocol.MaxWorldKeysPerRoom, reorderWindow)
	}
}

// maximalEventLine is the largest Event the protocol permits, rendered exactly
// as the relay would put it on the wire.
func maximalEventLine(t *testing.T) int {
	t.Helper()
	payload, err := json.Marshal(protocol.Event{
		From:    strings.Repeat("p", protocol.MaxHelloFieldLenForID),
		To:      strings.Repeat("t", protocol.MaxHelloFieldLenForID),
		CorrID:  strings.Repeat("c", protocol.MaxCorrIDLen),
		Seq:     ^uint64(0),
		Payload: json.RawMessage(`"` + strings.Repeat("x", protocol.MaxEventBytes-2) + `"`),
	})
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	line, err := json.Marshal(protocol.Envelope{Type: protocol.TypeEvent, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	return len(line)
}

// TestMaximalEventDoesNotFitAUDPDatagram pins the CURRENT, known-wrong state
// rather than asserting the guarantee we would like.
//
// MaxEventBytes' doc comment claimed that 1024 was chosen so a
// whole event envelope fits under MaxDatagramBytes, "so an event means the same
// thing on every transport". It does not: a maximal event overshoots, and is
// then refused by checkWritable for every udp peer with nothing but a relay log
// line to show for it. The comment has been corrected; this test is what stops
// the claim coming back, and what will fail the day somebody shrinks the
// constant to make it true — at which point flip the assertion.
//
// Shrinking MaxEventBytes is a contract revision with its own trade-offs and is
// recorded in agent_docs/risks.md as its own decision, so this test asserts
// reality, and names the gap in its failure message rather than hiding it.
// The sizes themselves, asserted rather than described. Three files carried a
// figure for "how big is a maximal event" and all three were wrong (~1310 in
// two comments, 1321 in agent_docs/risks.md, against a real 1441) because
// nothing checked them -- the tests above assert only the INEQUALITY, which
// stays true however far off the number is. A prose number nobody can fail is
// a number that drifts; these two constants fail loudly instead.
//
// If a protocol change moves them, update the constants and every place that
// quotes them (the failure message names them).
const (
	maximalEventLineBytes  = 1441
	maximalEscrowLineBytes = 3302
)

func TestMaximalEventDoesNotFitAUDPDatagram(t *testing.T) {
	const framing = 2 + tokenLen + seqLen

	line := maximalEventLine(t)
	if line != maximalEventLineBytes {
		t.Errorf("a maximal event line is now %d bytes, not %d -- update "+
			"maximalEventLineBytes here, protocol.MaxEventBytes' doc comment, and "+
			"agent_docs/risks.md, all of which quote it", line, maximalEventLineBytes)
	}
	if line+framing <= MaxDatagramBytes {
		t.Fatalf("a maximal event now fits a datagram (%d bytes, %d with framing, limit %d) -- "+
			"if MaxEventBytes was deliberately shrunk to make this true, invert this test into "+
			"the guarantee and update protocol.MaxEventBytes' doc comment to promise it.",
			line, line+framing, MaxDatagramBytes)
	}
}

// TestMaximalCommittedEscrowDoesNotFitAUDPDatagram is the same gap, wider: a
// committed EscrowState carries TWO blobs of up to MaxEscrowBlobBytes each, so
// it overshoots by more than an event does and in every case rather than only
// the maximal one. Nothing documented this anywhere before the 2026-08-18 audit.
func TestMaximalCommittedEscrowDoesNotFitAUDPDatagram(t *testing.T) {
	const framing = 2 + tokenLen + seqLen

	blob := json.RawMessage(`"` + strings.Repeat("x", protocol.MaxEscrowBlobBytes-2) + `"`)
	a := strings.Repeat("a", protocol.MaxHelloFieldLenForID)
	b := strings.Repeat("b", protocol.MaxHelloFieldLenForID)
	payload, err := json.Marshal(protocol.EscrowState{
		ID:        strings.Repeat("i", protocol.MaxEscrowIDLen),
		Seq:       ^uint64(0),
		Phase:     protocol.EscrowPhaseCommitted,
		Parties:   []string{a, b},
		Deposited: []string{a, b},
		Committed: []string{a, b},
		Blobs:     map[string]json.RawMessage{a: blob, b: blob},
	})
	if err != nil {
		t.Fatalf("marshal escrow_state: %v", err)
	}
	line, err := json.Marshal(protocol.Envelope{Type: protocol.TypeEscrowState, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	if len(line) != maximalEscrowLineBytes {
		t.Errorf("a maximal committed escrow_state line is now %d bytes, not %d -- update "+
			"maximalEscrowLineBytes here and agent_docs/risks.md, which quotes it",
			len(line), maximalEscrowLineBytes)
	}
	if len(line)+framing <= MaxDatagramBytes {
		t.Fatalf("a maximal committed escrow_state now fits a datagram (%d bytes, %d with "+
			"framing, limit %d) -- invert this test into the guarantee if that was deliberate.",
			len(line), len(line)+framing, MaxDatagramBytes)
	}
}
