package relay

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// waitUntilSuspended polls: a sleep long enough for a loaded CI machine would be paid by every run.
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

// TestAnEventSentWhileAMemberIsAwayIsReplayedWhenItResumes: the returning client gets the event itself, with the
// sequencer stamp it was first given.
func TestAnEventSentWhileAMemberIsAwayIsReplayedWhenItResumes(t *testing.T) {
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

	bob.send(protocol.TypeEvent, protocol.Event{
		To:      wa.PlayerID,
		CorrID:  "trade-7",
		Payload: json.RawMessage(`{"offer":"accepted"}`),
	})
	// Bob's echo carries the stamp alice's replay must match.
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

	// Replayed once: a duplicate would have the client act on the same trade twice.
	back.expectNothingOfType(protocol.TypeEvent, 300*time.Millisecond)
	r := s.Snapshot().Rooms
	if len(r) != 1 {
		t.Fatalf("expected one room, got %d", len(r))
	}
}

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

// TestTheMissedEventBacklogIsBoundedPerMember: a suspended member is a queue anyone in the room can fill, so past
// maxMissedEventsPerMember the oldest are dropped. Driven at the Room level, clear of the event flood cap.
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
	// The later half of a conversation is the half the returning client still has to answer.
	if q[len(q)-1].Seq <= q[0].Seq {
		t.Fatalf("backlog runs from seq %d to %d, want it in sequencer order", q[0].Seq, q[len(q)-1].Seq)
	}
	if q[0].Seq <= uint64(maxMissedEventsPerMember) {
		t.Fatalf("the backlog still starts at seq %d, so it dropped the NEWEST rather than the oldest", q[0].Seq)
	}
}
