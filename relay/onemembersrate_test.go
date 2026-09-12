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
	"encoding/json"
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

// X1-1 from the parity cell. forwardState bounds the line it sends and checks
// BEFORE recordState, so everything in r.lastState fits as a `state`. Wrapping
// the same payload in a Join adds 24 + len(player_id) bytes, and nothing
// measured THAT -- so a sender landing just under the cap was stored and
// re-served to every later snapshot.v1 joiner as a line over it.
//
// An over-cap line is not a reject: it is bufio.ErrTooLong in the joiner's read
// loop, so it reconnects, is handed the same snapshot, and loops. The client
// who cannot get into the room is the one who did nothing.
func TestASeedIsMeasuredAsTheJoinItIsSentAs(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	r.tryAdd(&Client{PlayerID: "loud", Conn: &recordingTransport{}})
	joiner := &Client{PlayerID: "joiner", Conn: &recordingTransport{}, features: []string{protocol.FeatureSnapshotV1}}
	r.tryAdd(joiner)

	// A state as close to the cap as forwardState will let through, which needs
	// the ESCAPING route: area_id and anim are bounded by len() at 256 each, and
	// encoding/json writes '&' as six bytes, so those two fields alone are worth
	// ~3072 wire bytes. That is the 2026-09-12 forward-seam mechanism, and it is
	// what makes a state that is legal-but-huge reachable at all. extras then
	// fills the gap, one byte at a time, so the result lands INSIDE the 28-byte
	// window a Join wrapper adds rather than somewhere convenient.
	stateLine := func(v protocol.State) int {
		t.Helper()
		b, err := json.Marshal(v)
		if err != nil {
			t.Fatal(err)
		}
		return len(protocol.AppendEnvelope(nil, protocol.TypeState, b))
	}
	base := protocol.State{
		PlayerID: "loud", Timestamp: 1000,
		AreaID:   strings.Repeat("&", protocol.MaxAreaIDLen),
		Anim:     strings.Repeat("&", protocol.MaxAnimLen),
		Position: []float64{1, 2},
	}
	var st protocol.State
	if protocol.ValidateState(base) && stateLine(base) <= protocol.MaxPayloadBytes {
		st = base
	}
	for pad := 1; pad < protocol.MaxExtrasBytes; pad++ {
		cand := base
		cand.Extras = map[string]any{"p": strings.Repeat("v", pad)}
		if !protocol.ValidateState(cand) || stateLine(cand) > protocol.MaxPayloadBytes {
			break
		}
		st = cand
	}
	if st.PlayerID == "" {
		t.Fatal("could not build a near-cap state")
	}

	body, err := json.Marshal(st)
	if err != nil {
		t.Fatal(err)
	}
	asState := len(protocol.AppendEnvelope(nil, protocol.TypeState, body))
	joinBody, err := json.Marshal(protocol.Join{PlayerID: "loud", State: &st})
	if err != nil {
		t.Fatal(err)
	}
	asJoin := len(protocol.AppendEnvelope(nil, protocol.TypeJoin, joinBody))
	t.Logf("the same payload is %d bytes as a state and %d as a join (cap %d)", asState, asJoin, protocol.MaxPayloadBytes)
	if asState > protocol.MaxPayloadBytes {
		t.Fatalf("test premise broken: the state itself is over the cap, so forwardState would never store it")
	}
	if asJoin <= protocol.MaxPayloadBytes {
		t.Skipf("this payload does not straddle the cap (%d as a join) -- nothing to prove here", asJoin)
	}

	r.recordState("loud", st)
	r.mu.Lock()
	outs := r.stateSnapshotLocked("joiner")
	r.mu.Unlock()

	// Before the fix: one outgoing, over the cap, which kills the joiner's read
	// loop the moment it arrives.
	for _, o := range outs {
		if n := len(protocol.AppendEnvelope(nil, o.env.Type, o.env.Payload)); n > protocol.MaxPayloadBytes {
			t.Fatalf("a seed went out at %d bytes, %d over what a receiver can read -- "+
				"the joiner's scanner dies on it and it reconnects into the same snapshot",
				n, n-protocol.MaxPayloadBytes)
		}
	}
}

// X1-3 from the parity cell. The pre-Welcome hold had a bare count where the
// outbox one file over has a two-class policy: past 64 it dropped whatever
// arrived next, reliable included. A dropped state is harmless (latest-wins);
// a dropped join means the receiving client never learns that peer exists and
// discards its states for the rest of the session as an unannounced id.
func TestTheWelcomeHoldDropsSamplesRatherThanLifecycleLines(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	held := &Client{PlayerID: "joining", Conn: &recordingTransport{}, holdUntilWelcome: true}
	r.tryAdd(held)
	r.tryAdd(&Client{PlayerID: "mover", Conn: &recordingTransport{}})

	// Fill the hold past its bound with state samples, exactly as a busy room
	// does while one client's Welcome is still being written.
	st, err := json.Marshal(protocol.State{PlayerID: "mover", Timestamp: 1, AreaID: "town", Position: []float64{1, 2}})
	if err != nil {
		t.Fatal(err)
	}
	stateLine := protocol.AppendEnvelope(nil, protocol.TypeState, st)
	for i := 0; i < maxPendingBeforeWelcome*2; i++ {
		r.forwardLine(stateLine, []string{"joining"}, true)
	}

	// Now the line that matters: somebody joins.
	jb, err := json.Marshal(protocol.Join{PlayerID: "newcomer"})
	if err != nil {
		t.Fatal(err)
	}
	r.forwardLine(protocol.AppendEnvelope(nil, protocol.TypeJoin, jb), []string{"joining"}, false)

	r.mu.Lock()
	queued := append([][]byte(nil), held.pending...)
	r.mu.Unlock()

	if len(queued) > maxPendingBeforeWelcome {
		t.Fatalf("the hold grew to %d, past its %d bound", len(queued), maxPendingBeforeWelcome)
	}
	found := false
	for _, line := range queued {
		if strings.Contains(string(line), "newcomer") {
			found = true
		}
	}
	// Before the fix: the join is message 129 behind 64 states and is dropped,
	// so this client never hears of "newcomer" at all.
	if !found {
		t.Fatal("a join was dropped from the pre-welcome hold in favour of state samples -- " +
			"the receiving client then discards that peer's states forever as an unannounced id")
	}
}

// X1-4. Every sibling field in this dump uses %q; the one a STRANGER chooses
// used %s, and a room's feature set sticks for the room's whole life.
func TestARoomsFeaturesCannotForgeLinesInTheIntrospectDump(t *testing.T) {
	forged := "x\n  room \"admin\" game=\"emerald\" members=99 seq=0"
	s := Snapshot{
		Rooms: []RoomSnapshot{{
			Name: "real", GameID: "emerald",
			Features: []string{forged},
		}},
	}
	out := s.String()
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), "room \"admin\"") {
			t.Fatalf("a room's feature string forged a whole room line in the operator's dump:\n%s", out)
		}
	}
}
