package udpconn

// The world plane's bounds are DERIVED from this package's own constants, not
// chosen. They live in protocol, which has no internal dependencies by
// design and therefore cannot see reorderWindow or the framing sizes at all —
// so the relationship is asserted here, in the one package that can, the same
// discipline RateLimitHeadroomMultiple already follows.
//
// **These are the tests that would have caught the pre-existing sizing bug.**
// MaxEventBytes' own comment claims it was sized to fit under MaxDatagramBytes
// and it is not: a maximal Event marshals to ~1310 bytes and cannot be
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
