package relay

// One member's message rate must not decide anything for the rest of the room. Unit-level: each decision is made
// under r.mu, and through a socket the flood cap would cost a second of wall clock per assertion.

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// A renew that changes nothing a receiver can render goes to the asker alone: it takes no table slot, so the lease
// cap never bounds it.
func TestARenewThatChangesNothingIsNotBroadcastToTheRoom(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	for _, id := range []string{"holder", "bystander-1", "bystander-2"} {
		r.tryAdd(&Client{PlayerID: id, Conn: &recordingTransport{}})
	}

	r.mu.Lock()
	r.leases = make(map[string]*lease)
	room := r.memberIDsLocked()
	first := r.grantLeaseLocked("door", "holder", time.Minute, room)
	// Same holder, same expiry to the second.
	renew := r.grantLeaseLocked("door", "holder", time.Minute, room)
	r.mu.Unlock()

	if got := recipientCount(first); got != 3 {
		t.Fatalf("the initial claim went to %d member(s), want the whole room (3)", got)
	}
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

// The arrival seed is an O(N) walk under r.mu plus a marshal per peer, fired by the sender's own area change.
func TestAlternatingAreasCannotReSeedOnEveryMessage(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	arrival := &recordingTransport{}
	r.tryAdd(&Client{PlayerID: "flapper", Conn: arrival, ownAreaOnly: true})
	for i := 0; i < 8; i++ {
		id := fmt.Sprintf("standing-%d", i)
		r.tryAdd(&Client{PlayerID: id, Conn: &recordingTransport{}})
		r.recordState(id, protocol.State{PlayerID: id, AreaID: "town"})
	}

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
	if sent > 8 {
		t.Errorf("a client alternating two area ids was re-seeded %d time(s) in one burst -- "+
			"each seed is an O(N) walk under r.mu and a marshal per peer", sent)
	}
	if sent == 0 {
		t.Error("no seed at all: the throttle swallowed the first one, which is the one that matters")
	}
}

// The per-member cap counts only live exchanges, so a third party's open/abort churn reaches the terminal records.
func TestAThirdPartyCannotEvictATradeOutcomeSomebodyIsStillOwed(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	r.tryAdd(&Client{PlayerID: "alice", Conn: &recordingTransport{}})
	r.tryAdd(&Client{PlayerID: "bob", Conn: &recordingTransport{}})

	r.mu.Lock()
	r.escrows = make(map[string]*escrow)
	// Bob dropped between the commit and its message: the case EscrowRetention exists for.
	r.members["bob"].suspended = true
	// The committed record is the oldest, so eviction by age alone would pick it.
	r.escrows["their-trade"] = &escrow{
		parties: [2]string{"alice", "bob"}, phase: protocol.EscrowPhaseCommitted,
		terminal: true, terminalAt: time.Now().Add(-time.Minute),
	}
	for i := 0; len(r.escrows) < maxEscrowRecordsPerRoom; i++ {
		r.escrows[fmt.Sprintf("churn-%d", i)] = &escrow{
			parties: [2]string{"mallory", "alice"}, phase: protocol.EscrowPhaseAborted,
			terminal: true, terminalAt: time.Now(),
		}
	}
	r.openedEscrowLocked("mallory")
	_, survived := r.escrows["their-trade"]
	r.mu.Unlock()

	if !survived {
		t.Fatal("a committed trade whose party is still away was evicted by an uninvolved member's " +
			"open/abort churn -- the record's whole purpose is to answer that party on resume")
	}
}

// When every terminal record is owed to somebody, a full table must still evict rather than refuse new exchanges.
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

// A broadcast reaches every backlog, so a flood of them must not push out the addressed events a returning member's
// conversation is made of.
func TestABroadcastFloodCannotEvictAMembersAddressedBacklog(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	r.tryAdd(&Client{PlayerID: "away", Conn: &recordingTransport{}})

	r.mu.Lock()
	r.members["away"].suspended = true
	r.queueMissedEventLocked("away", protocol.Event{From: "partner", To: "away", Seq: 1})
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
	if !addressed {
		t.Fatal("a broadcast flood pushed the one ADDRESSED event out of a suspended member's " +
			"backlog -- anybody in the room could decide what they come back knowing")
	}
}

// Anyone can open an exchange naming a client as counterparty, so the escrow section is capped short of the whole
// resume snapshot, or the world, lease and state lines fall off its end.
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
	r.escrows["live-one"] = &escrow{
		parties: [2]string{"partner", "victim"}, phase: protocol.EscrowPhaseDeposited,
	}
	lines := r.escrowSnapshotLocked("victim")
	r.mu.Unlock()

	if len(lines) > maxEscrowSnapshotLines {
		t.Errorf("the escrow section emitted %d lines, past its %d cap and %d of the whole %d-line "+
			"snapshot budget", len(lines), maxEscrowSnapshotLines, len(lines), maxSnapshotLines)
	}
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

// forwardState measures a state as a state line, but a seed re-serves it inside a Join, 24 + len(player_id) bytes
// longer. Over the cap, the joiner's read loop fails with bufio.ErrTooLong and it reconnects into the same snapshot.
func TestASeedIsMeasuredAsTheJoinItIsSentAs(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	r.tryAdd(&Client{PlayerID: "loud", Conn: &recordingTransport{}})
	joiner := &Client{PlayerID: "joiner", Conn: &recordingTransport{}, features: []string{protocol.FeatureSnapshotV1}}
	r.tryAdd(joiner)

	// Reaching the cap needs escaping: area_id and anim are bounded by len(), and encoding/json writes '&' as six
	// bytes. extras then grows a byte at a time, so the line lands inside the window a Join wrapper adds.
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

	for _, o := range outs {
		if n := len(protocol.AppendEnvelope(nil, o.env.Type, o.env.Payload)); n > protocol.MaxPayloadBytes {
			t.Fatalf("a seed went out at %d bytes, %d over what a receiver can read -- "+
				"the joiner's scanner dies on it and it reconnects into the same snapshot",
				n, n-protocol.MaxPayloadBytes)
		}
	}
}

// A dropped state is harmless (latest wins); a dropped join means the client discards that peer's states for the
// session as an unannounced id.
func TestTheWelcomeHoldDropsSamplesRatherThanLifecycleLines(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	held := &Client{PlayerID: "joining", Conn: &recordingTransport{}, holdUntilWelcome: true}
	r.tryAdd(held)
	r.tryAdd(&Client{PlayerID: "mover", Conn: &recordingTransport{}})

	// A busy room fills the hold with state samples while a Welcome is still being written.
	st, err := json.Marshal(protocol.State{PlayerID: "mover", Timestamp: 1, AreaID: "town", Position: []float64{1, 2}})
	if err != nil {
		t.Fatal(err)
	}
	stateLine := protocol.AppendEnvelope(nil, protocol.TypeState, st)
	for i := 0; i < maxPendingBeforeWelcome*2; i++ {
		r.forwardLine(stateLine, []string{"joining"}, true)
	}

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
	if !found {
		t.Fatal("a join was dropped from the pre-welcome hold in favour of state samples -- " +
			"the receiving client then discards that peer's states forever as an unannounced id")
	}
}

// A room's feature strings are a stranger's choice and stick for the room's life, so the dump must quote them.
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
