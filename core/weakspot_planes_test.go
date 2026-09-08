package core

// WHICH PLANE EACH MESSAGE LEAVES ON (2026-09-08).
//
// Every relay stand-in in this package aliased SendUnreliable to Send
// (recordingTransport, capturingTransport, and every ad-hoc double), so the
// reliable/unreliable split was invisible to the whole of core: flipping
// core/sending.go's state send to Send, or moving an event, a lease, an escrow
// step or a reliable world write onto the LOSSY plane, left the entire package
// green. relay/world_test.go's double already recorded the plane; this is
// core's equivalent.
//
// It matters on udp and quic-datagram and nowhere else, which is exactly why
// no local test noticed. A control message on the lossy plane is a join, a
// lease grant or an escrow commit that is simply GONE with nothing to
// supersede it -- contract.md defines those planes as reliable and ordered,
// and every adapter is written against that promise. In the other direction, a
// position sample on the reliable plane is retransmitted, so a lost one
// arrives stale and out of order behind the newer samples it delayed, which is
// worse than the gap it filled (the transport ADR in agent_docs/architecture.md).

import (
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// planeTransport records the plane each message was sent on, not just the
// bytes. The one thing every other double in this package throws away.
type planeTransport struct {
	mu   sync.Mutex
	sent []plainSend
}

type plainSend struct {
	typ        protocol.MessageType
	unreliable bool
}

func (pt *planeTransport) record(payload []byte, unreliable bool) error {
	var env protocol.Envelope
	if err := json.Unmarshal(payload, &env); err != nil {
		return nil
	}
	pt.mu.Lock()
	pt.sent = append(pt.sent, plainSend{typ: env.Type, unreliable: unreliable})
	pt.mu.Unlock()
	return nil
}

func (pt *planeTransport) Send(payload []byte) error           { return pt.record(payload, false) }
func (pt *planeTransport) SendUnreliable(payload []byte) error { return pt.record(payload, true) }
func (pt *planeTransport) OnReceive(func([]byte))              {}
func (pt *planeTransport) OnDisconnect(func(error))            {}
func (pt *planeTransport) OnError(func(error))                 {}
func (pt *planeTransport) Close() error                        { return nil }

// planeOf reports how the one message of this type was sent, and fails if
// there was not exactly one -- a type sent twice on different planes would
// otherwise pass whichever assertion was made about it.
func (pt *planeTransport) planeOf(t *testing.T, typ protocol.MessageType) bool {
	t.Helper()
	pt.mu.Lock()
	defer pt.mu.Unlock()
	var found []plainSend
	for _, s := range pt.sent {
		if s.typ == typ {
			found = append(found, s)
		}
	}
	if len(found) != 1 {
		t.Fatalf("%s was sent %d time(s), want exactly 1 -- the plane assertion below would be "+
			"about whichever send happened to be looked at", typ, len(found))
	}
	return found[0].unreliable
}

// planesCore is a Core wired to a plane-recording relay with every online
// feature negotiated, so each send path is reached rather than refused with
// ErrFeatureNotEnabled.
func planesCore(t *testing.T) (*Core, *planeTransport) {
	t.Helper()
	c := New()
	c.MinSendInterval = time.Nanosecond
	pt := &planeTransport{}
	c.mu.Lock()
	c.relay = pt
	c.playerID = "self"
	c.activeFeatures = []string{
		protocol.FeatureEventV1,
		protocol.FeatureLeaseV1,
		protocol.FeatureEscrowV1,
		protocol.FeatureWorldV1,
	}
	c.mu.Unlock()
	return c, pt
}

// TestTheStatePlaneIsTheOnlyLossyOneByDefault pins the split the contract
// makes and no test in this package could see before 2026-09-08.
func TestTheStatePlaneIsTheOnlyLossyOneByDefault(t *testing.T) {
	c, pt := planesCore(t)

	// The state plane: lossy and latest-wins. A retransmitted position arrives
	// stale and out of order, which is worse than the gap it fills.
	st := protocol.State{AreaID: "a", Position: []float64{1, 2}, Anim: "idle"}
	c.forwardLocalState(&st)
	if !pt.planeOf(t, protocol.TypeState) {
		t.Fatal("a position sample went out on the RELIABLE plane -- on udp that means a lost " +
			"sample is retransmitted and lands stale, behind the newer samples it delayed, " +
			"instead of being superseded by the next one")
	}

	// Everything else carries a decision, and a lost one is never superseded.
	if err := c.SendEvent(protocol.Event{Payload: json.RawMessage(`{"kind":"chest_opened"}`)}); err != nil {
		t.Fatalf("send event: %v", err)
	}
	if pt.planeOf(t, protocol.TypeEvent) {
		t.Fatal("an event went out on the LOSSY plane -- contract.md calls the event plane " +
			"reliable and ordered, and a dropped one is undetectable to the receiver " +
			"because events are addressed and show no seq gap")
	}

	if err := c.ClaimLease("door:1", time.Second); err != nil {
		t.Fatalf("claim lease: %v", err)
	}
	if pt.planeOf(t, protocol.TypeLease) {
		t.Fatal("a lease request went out on the LOSSY plane -- a claim that is simply gone " +
			"leaves the adapter waiting for an answer that will never come")
	}

	if err := c.SendEscrow(protocol.Escrow{Op: protocol.EscrowOpen, ID: "x1", With: "peer"}); err != nil {
		t.Fatalf("send escrow: %v", err)
	}
	if pt.planeOf(t, protocol.TypeEscrow) {
		t.Fatal("an escrow step went out on the LOSSY plane -- a lost commit is one side " +
			"having given something away that the other never received")
	}
}

// TestAWorldWriteTakesThePlaneItsCallerAsked is the one place the choice is
// the ADAPTER's, per write, rather than a property of the plane
// (protocol.World.Reliable). Both directions are asserted, because a
// regression that pinned either one would be invisible to a test that only
// checked the other -- and the reliable direction is load-bearing: a lossy
// write on a key the relay does not hold yet is IGNORED, so a create that
// silently went lossy never appears for anyone.
func TestAWorldWriteTakesThePlaneItsCallerAsked(t *testing.T) {
	c, pt := planesCore(t)

	if err := c.SetWorld("host", "cart:1", json.RawMessage(`{"x":1}`), false); err != nil {
		t.Fatalf("lossy world set: %v", err)
	}
	if !pt.planeOf(t, protocol.TypeWorld) {
		t.Fatal("a world write the adapter marked lossy went out reliably -- continuous motion " +
			"the next write supersedes would be retransmitted at the rate it is produced")
	}

	c2, pt2 := planesCore(t)
	if err := c2.SetWorld("host", "cart:1", json.RawMessage(`{"x":1}`), true); err != nil {
		t.Fatalf("reliable world set: %v", err)
	}
	if pt2.planeOf(t, protocol.TypeWorld) {
		t.Fatal("a world write the adapter marked reliable went out on the LOSSY plane -- a " +
			"write that CREATES a key is ignored when it arrives lossy, so the entity never exists")
	}

	c3, pt3 := planesCore(t)
	if err := c3.DropWorld("host", "cart:1"); err != nil {
		t.Fatalf("world drop: %v", err)
	}
	if pt3.planeOf(t, protocol.TypeWorld) {
		t.Fatal("a world drop went out on the LOSSY plane -- a drop is superseded by nothing, " +
			"and a lost one leaves the entity standing for everyone who missed it")
	}
}

// TestADeliberateLeaveIsSentReliably: the goodbye is what turns "this player
// left" into a clean departure rather than every peer watching a frozen ghost
// until the grace window expires. It is sent immediately before the socket
// closes, so there is no later message to carry the news.
func TestADeliberateLeaveIsSentReliably(t *testing.T) {
	pt := &planeTransport{}
	sendGoodbye(pt)
	if pt.planeOf(t, protocol.TypeLeave) {
		t.Fatal("the goodbye went out on the LOSSY plane -- it is the last thing written before " +
			"the socket closes, so a dropped one means every peer waits out the grace window " +
			"watching a frozen ghost instead of seeing a clean departure")
	}
}
