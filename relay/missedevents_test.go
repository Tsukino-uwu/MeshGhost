package relay

// F6 of the 2026-09-08 review: the event plane is specified reliable and
// ordered (agent_docs/contract.md), and a member whose connection dropped
// inside the resume grace was simply skipped by forwardLine while
// resumeSnapshot replayed state, leases, escrows and world -- everything except
// events. Two peers mid-trade over event.v1, one blips, and the returning
// client is told nothing happened. It cannot even notice: events are addressed,
// so a peer never sees a gap in seq.

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// waitUntilSuspended blocks until the relay has actually parked playerID's
// identity. Polled rather than slept: the test needs the suspension to have
// HAPPENED before the event is sent, and a sleep long enough to be safe on a
// loaded CI machine is a sleep in every run.
func waitUntilSuspended(t *testing.T, s *Server, playerID string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		for _, room := range s.Snapshot().Rooms {
			for _, m := range room.Members {
				if m.PlayerID == playerID && m.Suspended {
					return
				}
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("%s was never suspended", playerID)
}

// TestAnEventSentWhileAMemberIsAwayIsReplayedWhenItResumes. The guarantee the
// contract states, made true across a resume rather than only across a
// connection: what the returning client is given back is the event itself,
// carrying the sequencer stamp it was assigned when it was first sent.
func TestAnEventSentWhileAMemberIsAwayIsReplayedWhenItResumes(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), MaxClients: DefaultMaxClients}
	addr := startServerWith(t, s)

	alice := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	wa := alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", allFeatures)
	defer bob.conn.Close()
	bob.expectWelcome(timeout)
	alice.nextOfType(protocol.TypeJoin, timeout)

	// Alice's connection dies mid-trade.
	alice.conn.Close()
	waitUntilSuspended(t, s, wa.PlayerID)

	// Bob answers a trade only alice is waiting on.
	bob.send(protocol.TypeEvent, protocol.Event{
		To:      wa.PlayerID,
		CorrID:  "trade-7",
		Payload: json.RawMessage(`{"offer":"accepted"}`),
	})
	// Bob's own echo carries the stamp the relay assigned, which is what
	// alice's replay must match.
	echo := bob.expectEvent(timeout)

	back := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
		Features:        allFeatures,
		ResumeToken:     wa.ResumeToken,
	})
	defer back.conn.Close()
	if w := back.expectWelcome(timeout); !w.Resumed {
		t.Fatal("welcome did not report a resumption")
	}

	ev := back.expectEvent(timeout)
	if ev.CorrID != "trade-7" || string(ev.Payload) != `{"offer":"accepted"}` {
		t.Fatalf("the replayed event is %+v, want bob's trade-7 answer", ev)
	}
	if ev.Seq != echo.Seq {
		t.Fatalf("the replayed event was stamped %d, bob saw %d -- a replay re-stamped is a "+
			"peer's action moved after things that really happened later", ev.Seq, echo.Seq)
	}
	if ev.From != echo.From {
		t.Fatalf("the replayed event came from %q, want %q", ev.From, echo.From)
	}

	// Replayed once and then forgotten: a second resume must not deliver it
	// again, or a client that blips twice acts on the same trade twice.
	back.expectNothingOfType(protocol.TypeEvent, 300*time.Millisecond)
	r := s.Snapshot().Rooms
	if len(r) != 1 {
		t.Fatalf("expected one room, got %d", len(r))
	}
}

// TestABroadcastEventReachesAMemberThatWasAwayForIt. The addressed case above
// is the one that breaks a trade; a broadcast is just as reliable by contract,
// and skipping a suspended member drops it just as silently.
func TestABroadcastEventReachesAMemberThatWasAwayForIt(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), MaxClients: DefaultMaxClients}
	addr := startServerWith(t, s)

	alice := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	wa := alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", allFeatures)
	defer bob.conn.Close()
	bob.expectWelcome(timeout)
	alice.nextOfType(protocol.TypeJoin, timeout)

	alice.conn.Close()
	waitUntilSuspended(t, s, wa.PlayerID)
	bob.send(protocol.TypeEvent, protocol.Event{CorrID: "roomwide", Payload: json.RawMessage(`{"n":1}`)})
	bob.expectEvent(timeout)

	back := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
		Features:        allFeatures,
		ResumeToken:     wa.ResumeToken,
	})
	defer back.conn.Close()
	back.expectWelcome(timeout)
	if ev := back.expectEvent(timeout); ev.CorrID != "roomwide" {
		t.Fatalf("the replayed broadcast is %+v, want the one sent while alice was away", ev)
	}
}

// TestTheMissedEventBacklogIsBoundedPerMember. The backlog competes with the
// escrow, world and lease lines for maxSnapshotLines, and a suspended member is
// a free queue anyone in the room can fill, so it is a ceiling and not a
// promise: past maxMissedEventsPerMember the OLDEST are dropped and the
// operator is told once. Driven at the Room level -- filling it over a socket
// would spend the whole test under the event flood cap.
func TestTheMissedEventBacklogIsBoundedPerMember(t *testing.T) {
	r, _ := worldRoom(t, []string{protocol.FeatureEventV1}, "away", "sender")
	r.mu.Lock()
	r.members["away"].suspended = true
	r.mu.Unlock()

	for i := 0; i < maxMissedEventsPerMember*2; i++ {
		r.handleEvent("sender", protocol.Event{To: "away", CorrID: string(rune('a' + i%26)), Seq: 0,
			Payload: json.RawMessage(`{}`)})
	}

	r.mu.Lock()
	q := append([]protocol.Event(nil), r.missedEvents["away"]...)
	r.mu.Unlock()
	if len(q) != maxMissedEventsPerMember {
		t.Fatalf("the backlog for one suspended member reached %d entries, want it held at %d",
			len(q), maxMissedEventsPerMember)
	}
	// The newest survived, the oldest were dropped: the later half of a trade
	// conversation is the half the returning client still needs to answer.
	if q[len(q)-1].Seq <= q[0].Seq {
		t.Fatalf("backlog runs from seq %d to %d, want it in sequencer order", q[0].Seq, q[len(q)-1].Seq)
	}
	if q[0].Seq <= uint64(maxMissedEventsPerMember) {
		t.Fatalf("the backlog still starts at seq %d, so it dropped the NEWEST rather than the oldest", q[0].Seq)
	}
}
