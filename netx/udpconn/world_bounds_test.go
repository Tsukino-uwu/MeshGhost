//go:build meshghost_devudp

package udpconn

// The world plane's bounds derive from this package's constants, which protocol cannot see (it has no internal
// dependencies), so the relationship is asserted here, in the one package that can.

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

// TestMaximalWorldStateFitsAUDPDatagram is the assertion the world plane's bounds were derived from. checkWritable
// refuses an oversized datagram, reliable included, so a custody message that did not fit would be lost for that
// recipient and never superseded, leaving one client looking at a different world.
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

// TestWorldSnapshotNeverExceedsTheReorderWindow is why MaxWorldKeysPerRoom is 64. A reliable burst wider than the
// receiver's reorder window is not held, so not acked, and is retried until the connection closes: raising the room
// cap without the window turns a new host adopting a large world into a disconnect.
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

// maximalEventLineBytes and maximalEscrowLineBytes are the measured sizes, asserted rather than described: the
// inequality checks stay true however far a quoted figure drifts. If a protocol change moves them, update every
// place that quotes them (the failure messages name them).
const (
	maximalEventLineBytes  = 1441
	maximalEscrowLineBytes = 3302
)

// TestMaximalEventDoesNotFitAUDPDatagram pins the current, known gap rather than the guarantee: a maximal event
// overshoots a datagram and is refused for every udp peer. Shrinking MaxEventBytes is a contract revision; if it is
// ever made, invert this test into the guarantee.
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

// TestMaximalCommittedEscrowDoesNotFitAUDPDatagram is the same gap, wider: a committed EscrowState carries two blobs
// of up to MaxEscrowBlobBytes, so it overshoots in every case, not only the maximal one.
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
