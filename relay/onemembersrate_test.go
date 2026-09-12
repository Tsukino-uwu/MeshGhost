package relay

// Section E of the 2026-09-12 adversarial review: four places where ONE
// member's message rate decided something for the rest of the room, or for a
// member who was not even connected.
//
// They are unit-level rather than driven through a real client, deliberately:
// each is about a decision made under r.mu, and the flood cap means a
// socket-level reproduction of the 120-a-second cases would spend a second of
// wall clock per assertion.

import (
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// E2 (P1a-2). A renew that changes nothing a receiver can render is the asker's
// business. It takes no table slot, so the lease cap never sees it.
func TestARenewThatChangesNothingIsNotBroadcastToTheRoom(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	for _, id := range []string{"holder", "bystander-1", "bystander-2"} {
		r.tryAdd(&Client{PlayerID: id, Conn: &recordingTransport{}})
	}

	r.mu.Lock()
	r.leases = make(map[string]*lease)
	room := r.memberIDsLocked()
	// The claim: a real change, so the whole room hears it.
	first := r.grantLeaseLocked("door", "holder", time.Minute, room)
	// A renew in the same second: same holder, same expiry to the second.
	renew := r.grantLeaseLocked("door", "holder", time.Minute, room)
	r.mu.Unlock()

	if got := recipientCount(first); got != 3 {
		t.Fatalf("the initial claim went to %d member(s), want the whole room (3)", got)
	}
	// Before the fix: 3, at whatever rate the holder cared to renew.
	if got := recipientCount(renew); got != 1 {
		t.Errorf("a renew that changed nothing went to %d member(s), want the asker alone -- "+
			"a renew takes no table slot, so nothing else bounds this fan-out", got)
	}
}

func recipientCount(outs []outgoing) int {
	n := 0
	for _, o := range outs {
		n += len(o.to)
	}
	return n
}

// E4 (P1c-4). The arrival seed is an O(N) walk plus a marshal per peer, fired
// by a sender's own area changing -- and it is the only finding in this section
// that lands in a default cosmetic room.
func TestAlternatingAreasCannotReSeedOnEveryMessage(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	arrival := &recordingTransport{}
	r.tryAdd(&Client{PlayerID: "flapper", Conn: arrival, ownAreaOnly: true})
	for i := 0; i < 8; i++ {
		id := fmt.Sprintf("standing-%d", i)
		r.tryAdd(&Client{PlayerID: id, Conn: &recordingTransport{}})
		r.recordState(id, protocol.State{PlayerID: id, AreaID: "town"})
	}

	// Twenty area changes as fast as a client can send them.
	for i := 0; i < 20; i++ {
		area := "town"
		if i%2 == 1 {
			area = "cave"
		}
		r.seedArrivalInto("flapper", area)
	}

	arrival.mu.Lock()
	sent := len(arrival.got)
	arrival.mu.Unlock()
	// Before the fix: 8 seeds per call into "town", ten times over.
	if sent > 8 {
		t.Errorf("a client alternating two area ids was re-seeded %d time(s) in one burst -- "+
			"each seed is an O(N) walk under r.mu and a marshal per peer", sent)
	}
	if sent == 0 {
		t.Error("no seed at all: the throttle swallowed the first one, which is the one that matters")
	}
}

// E5 (P1c-1). The per-member cap counts LIVE exchanges, so a third party can
// churn open/abort and push out a committed record whose party is away.
func TestAThirdPartyCannotEvictATradeOutcomeSomebodyIsStillOwed(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	r.tryAdd(&Client{PlayerID: "alice", Conn: &recordingTransport{}})
	r.tryAdd(&Client{PlayerID: "bob", Conn: &recordingTransport{}})

	r.mu.Lock()
	r.escrows = make(map[string]*escrow)
	// Bob dropped in the moment between the relay committing and the message
	// arriving -- the exact case EscrowRetention exists for.
	r.members["bob"].suspended = true
	// The committed record is the OLDEST, which is what made age alone pick it.
	r.escrows["their-trade"] = &escrow{
		parties: [2]string{"alice", "bob"}, phase: protocol.EscrowPhaseCommitted,
		terminal: true, terminalAt: time.Now().Add(-time.Minute),
	}
	// A third party fills the rest of the table with fresh terminal records.
	for i := 0; len(r.escrows) < maxEscrowRecordsPerRoom; i++ {
		r.escrows[fmt.Sprintf("churn-%d", i)] = &escrow{
			parties: [2]string{"mallory", "alice"}, phase: protocol.EscrowPhaseAborted,
			terminal: true, terminalAt: time.Now(),
		}
	}
	r.openedEscrowLocked("mallory")
	_, survived := r.escrows["their-trade"]
	r.mu.Unlock()

	// Before the fix: gone, and bob resumes unable to tell a completed trade
	// from one that never finished -- "both or neither" broken from one side.
	if !survived {
		t.Fatal("a committed trade whose party is still away was evicted by an uninvolved member's " +
			"open/abort churn -- the record's whole purpose is to answer that party on resume")
	}
}

// And the converse, so the eviction still bounds the table when every terminal
// record is owed to somebody: a full table must not refuse new exchanges.
func TestTheEscrowTableIsStillBoundedWhenEveryRecordIsOwed(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	r.tryAdd(&Client{PlayerID: "away", Conn: &recordingTransport{}})

	r.mu.Lock()
	r.escrows = make(map[string]*escrow)
	r.members["away"].suspended = true
	for i := 0; i < maxEscrowRecordsPerRoom; i++ {
		r.escrows[fmt.Sprintf("owed-%d", i)] = &escrow{
			parties: [2]string{"away", "other"}, phase: protocol.EscrowPhaseCommitted,
			terminal: true, terminalAt: time.Now().Add(-time.Duration(i) * time.Second),
		}
	}
	r.openedEscrowLocked("someone")
	held := len(r.escrows)
	r.mu.Unlock()

	if held >= maxEscrowRecordsPerRoom+1 {
		t.Fatalf("the table grew to %d: when every terminal record is owed, the oldest still has to go, "+
			"or a full table refuses every new exchange forever", held)
	}
}

// E6 (P1c-2). A broadcast reaches every backlog, so 64 of them push out the
// addressed events a returning member's conversation is made of.
func TestABroadcastFloodCannotEvictAMembersAddressedBacklog(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	r.tryAdd(&Client{PlayerID: "away", Conn: &recordingTransport{}})

	r.mu.Lock()
	r.members["away"].suspended = true
	// One event actually aimed at this member, first in the queue.
	r.queueMissedEventLocked("away", protocol.Event{From: "partner", To: "away", Seq: 1})
	// Then a flood of broadcasts, more than the backlog holds.
	for i := 0; i < maxMissedEventsPerMember*2; i++ {
		r.queueMissedEventLocked("away", protocol.Event{From: "mallory", To: "", Seq: uint64(i + 2)})
	}
	q := r.missedEvents["away"]
	r.mu.Unlock()

	if len(q) > maxMissedEventsPerMember {
		t.Fatalf("the backlog grew to %d, past its %d cap", len(q), maxMissedEventsPerMember)
	}
	addressed := false
	for _, ev := range q {
		if ev.To == "away" {
			addressed = true
		}
	}
	// Before the fix: gone, and they resume believing their partner never spoke.
	if !addressed {
		t.Fatal("a broadcast flood pushed the one ADDRESSED event out of a suspended member's " +
			"backlog -- anybody in the room could decide what they come back knowing")
	}
}

// E7 (P1c-3). maxMissedEventsPerMember's own comment states the rule -- a
// section that could fill the 192-line snapshot "would push the escrow, world
// and lease lines off the end and break, to save the event plane, three planes
// that were not broken" -- and the escrow section had no cap at all. A client
// does not choose how many exchanges it is a party to: anyone can open one
// naming it as the counterparty.
func TestTheEscrowSectionCannotFillAWholeResumeSnapshot(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	r.tryAdd(&Client{PlayerID: "victim", Conn: &recordingTransport{}})

	r.mu.Lock()
	r.escrows = make(map[string]*escrow)
	for i := 0; i < maxEscrowRecordsPerRoom; i++ {
		r.escrows[fmt.Sprintf("t-%d", i)] = &escrow{
			parties: [2]string{"mallory", "victim"}, phase: protocol.EscrowPhaseAborted,
			terminal: true, terminalAt: time.Now().Add(-time.Duration(i) * time.Second),
		}
	}
	// One LIVE exchange, which is the line the victim actually has to act on.
	r.escrows["live-one"] = &escrow{
		parties: [2]string{"partner", "victim"}, phase: protocol.EscrowPhaseDeposited,
	}
	lines := r.escrowSnapshotLocked("victim")
	r.mu.Unlock()

	// Before the fix: 257, against a whole-snapshot budget of 192 -- so the
	// world, lease and state sections were dropped off the tail entirely.
	if len(lines) > maxEscrowSnapshotLines {
		t.Errorf("the escrow section emitted %d lines, past its %d cap and %d of the whole %d-line "+
			"snapshot budget", len(lines), maxEscrowSnapshotLines, len(lines), maxSnapshotLines)
	}
	// And the live one survives the cut, because it is the one still waiting on
	// this client rather than an outcome it can ask for.
	found := false
	for _, o := range lines {
		if strings.Contains(string(o.env.Payload), "live-one") {
			found = true
		}
	}
	if !found {
		t.Error("a LIVE exchange was cut in favour of terminal ones -- a live one is waiting on this " +
			"client to deposit or commit; a terminal one is history it can also ask for")
	}
}
