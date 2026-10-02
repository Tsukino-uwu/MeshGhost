package core

// Which plane each message leaves on. Every other relay stand-in here aliases SendUnreliable to Send, so only this
// double sees the split. It matters on udp and quic-datagram: a control message on the lossy plane is simply gone with
// nothing to supersede it, and a position sample on the reliable plane is retransmitted and arrives stale, behind the
// newer samples it delayed.

import (
	"encoding/json"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// planeTransport records the plane each message was sent on, not just the bytes. core must drain before pt.sent is the
// whole answer.
type planeTransport struct {
	core *Core

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

// planeOf reports how the one message of this type was sent, and fails unless there was exactly one: a type sent twice
// on different planes would pass whichever assertion was made about it.
func (pt *planeTransport) planeOf(t *testing.T, typ protocol.MessageType) bool {
	t.Helper()
	pt.core.waitRelayDrained()
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

// planesCore is a Core wired to a plane-recording relay with every online feature negotiated, so each send path is
// reached rather than refused with ErrFeatureNotEnabled.
func planesCore(t *testing.T) (*Core, *planeTransport) {
	t.Helper()
	c := New()
	c.MinSendInterval = time.Nanosecond
	pt := &planeTransport{core: c}
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

// TestTheStatePlaneIsTheOnlyLossyOneByDefault pins the split the contract makes: state is lossy, every decision is
// reliable.
func TestTheStatePlaneIsTheOnlyLossyOneByDefault(t *testing.T) {
	c, pt := planesCore(t)

	// The state plane: lossy and latest-wins.
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

// TestAWorldWriteTakesThePlaneItsCallerAsked: here the plane is the adapter's choice per write
// (protocol.World.Reliable), so both directions are asserted. A lossy write on a key the relay does not hold yet is
// ignored, so a create that went lossy never appears for anyone.
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

// TestADeliberateLeaveIsSentReliably: the goodbye is sent just before the socket closes, so nothing later carries the
// news, and a lost one leaves every peer watching a frozen ghost until the grace window expires.
func TestADeliberateLeaveIsSentReliably(t *testing.T) {
	pt := &planeTransport{}
	sendGoodbye(pt)
	if pt.planeOf(t, protocol.TypeLeave) {
		t.Fatal("the goodbye went out on the LOSSY plane -- it is the last thing written before " +
			"the socket closes, so a dropped one means every peer waits out the grace window " +
			"watching a frozen ghost instead of seeing a clean departure")
	}
}
