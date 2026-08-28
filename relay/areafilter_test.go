package relay

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// Relay-side cross-area filtering. agent_docs/plans.md frames this as a change
// of SCALING SHAPE rather than a saving: a room's host uplink goes from
// n x (n-1) state messages to n x (peers in your area), which is the difference
// between "8 is the practical limit" and "the limit is how many people are
// standing in the same room".
//
// What makes it safe to ship is that it is a STRICT SUBSET of the check
// core.remoteStatesAt already applies at render time, and that check stays in
// place untouched. The relay only declines to send what the recipient's own
// core would have discarded -- with one exception, the departure case, which
// has its own test below and is the reason this is not a one-line change.

// areaRoom builds a room where every member's area is known and each states
// whether it opted in to filtering.
func areaRoom(t *testing.T, members map[string]struct {
	area        string
	ownAreaOnly bool
},
) (*Room, map[string]*recordingTransport) {
	t.Helper()
	r := newRoom("emerald", "", "room1", nil)
	conns := make(map[string]*recordingTransport, len(members))
	for id, m := range members {
		rt := &recordingTransport{}
		conns[id] = rt
		r.tryAdd(&Client{PlayerID: id, Conn: rt, ownAreaOnly: m.ownAreaOnly})
		r.recordState(id, protocol.State{PlayerID: id, AreaID: m.area})
	}
	return r, conns
}

type member = struct {
	area        string
	ownAreaOnly bool
}

func recipientsOf(r *Room, sender, area string) map[string]bool {
	got := r.stateRecipients(sender, area, area, 100, time.Now())
	set := make(map[string]bool, len(got))
	for _, id := range got {
		set[id] = true
	}
	return set
}

func TestOwnAreaOnlyClientDoesNotReceiveCrossAreaState(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"sender": {area: "town", ownAreaOnly: true},
		"near":   {area: "town", ownAreaOnly: true},
		"far":    {area: "cave", ownAreaOnly: true},
	})
	got := recipientsOf(r, "sender", "town")
	if !got["near"] {
		t.Fatal("a peer in the same area must still receive the state")
	}
	if got["far"] {
		t.Fatal("a peer in another area that opted in must not receive it")
	}
}

// THE TEST THAT PROTECTS EMERALD. An adapter that translates a neighbouring
// map's coordinates renders peers in ADJACENT areas and declares
// render_all_areas over the bridge, which its core turns into own_area_only
// being absent. Absent must mean "send me everything" -- and so must an older
// client that has never heard of the field, which is the same code path.
func TestClientThatDidNotOptInReceivesEverything(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"sender":   {area: "town", ownAreaOnly: true},
		"crossmap": {area: "cave", ownAreaOnly: false},
	})
	if !recipientsOf(r, "sender", "town")["crossmap"] {
		t.Fatal("a client that never opted in must receive cross-area state; " +
			"this is Emerald's shipped cross-map ghosts, and an older client")
	}
}

// Both fail-open conditions, each mirroring one in core.remoteStatesAt. An
// unknown area on either side means the relay cannot know the two differ, so it
// must forward.
func TestUnknownAreaFailsOpen(t *testing.T) {
	t.Run("recipient area unknown", func(t *testing.T) {
		r := newRoom("emerald", "", "room1", nil)
		r.tryAdd(&Client{PlayerID: "sender", Conn: &recordingTransport{}, ownAreaOnly: true})
		// Never sent a state, so the relay knows no area for it.
		r.tryAdd(&Client{PlayerID: "quiet", Conn: &recordingTransport{}, ownAreaOnly: true})
		r.recordState("sender", protocol.State{PlayerID: "sender", AreaID: "town"})
		if !recipientsOf(r, "sender", "town")["quiet"] {
			t.Fatal("a recipient whose area is unknown must be forwarded to")
		}
	})
	t.Run("sender area unknown", func(t *testing.T) {
		r, _ := areaRoom(t, map[string]member{
			"sender": {area: "", ownAreaOnly: true},
			"other":  {area: "cave", ownAreaOnly: true},
		})
		if !recipientsOf(r, "sender", "")["other"] {
			t.Fatal("a state with no area must be forwarded to everyone")
		}
	})
}

// A room may freely mix a filtered client and a cross-map one, because the
// decision is per RECIPIENT rather than per room. If it were per room, one
// Emerald client would switch filtering off for a whole 32-seat lobby.
func TestMixedRoomFiltersPerRecipient(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"sender":   {area: "town", ownAreaOnly: true},
		"filtered": {area: "cave", ownAreaOnly: true},
		"crossmap": {area: "cave", ownAreaOnly: false},
	})
	got := recipientsOf(r, "sender", "town")
	if got["filtered"] {
		t.Fatal("the opted-in peer should have been filtered")
	}
	if !got["crossmap"] {
		t.Fatal("the peer that did not opt in should still receive it")
	}
}

// THE DEPARTURE CASE, and the reason filtering by area alone is wrong rather
// than merely wasteful.
//
// A peer walking OUT of a recipient's area is announced by exactly one message:
// the first state carrying its new area_id. That is what the recipient's core
// despawns the ghost on. Filter it and the recipient hears silence, its buffer
// edge-holds the last sample, and the ghost stands frozen at the doorway until
// core.DefaultRemoteStaleAfter (3 seconds) ages it out -- where today's despawn
// takes about one interpolation delay.
//
// Caught by core's own TestCrossAreaFiltersRemote, which went red the moment
// the filter went in and before this test existed.
func TestDepartingPeerDespawnsOnItsOwnStateNotByAgeOut(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"walker":    {area: "town", ownAreaOnly: true},
		"stayer":    {area: "town", ownAreaOnly: true},
		"unrelated": {area: "cave", ownAreaOnly: true},
	})

	// The walker crosses from town to cave. Its previous area was town, so the
	// state that announces the crossing must still reach the peer it left.
	got := r.stateRecipients("walker", "cave", "town", 100, time.Now())
	set := map[string]bool{}
	for _, id := range got {
		set[id] = true
	}
	if !set["stayer"] {
		t.Fatal("the crossing state must reach the area being LEFT, or that peer's " +
			"ghost freezes for the full stale-after window instead of despawning")
	}
	if !set["unrelated"] {
		t.Fatal("the crossing state must reach the area being ENTERED")
	}
}

// The departure delivery is for the crossing message only. Once the walker is
// established in its new area, ordinary filtering resumes -- otherwise the
// exception would quietly disable the feature for anyone who ever moved.
func TestDepartureDeliveryIsOnlyForTheCrossingState(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"walker": {area: "cave", ownAreaOnly: true},
		"stayer": {area: "town", ownAreaOnly: true},
	})
	// prevArea == area: the walker is standing still in the cave now.
	if recipientsOf(r, "walker", "cave")["stayer"] {
		t.Fatal("after the crossing, states must be filtered from the old area again")
	}
}

// The counters have to keep telling two different stories apart once the filter
// is live: what COULD be suppressed, and what WAS. Conflating them would make
// the introspect line report a shrinking opportunity as the filter improved.
func TestCountersSeparateSuppressibleFromActuallyFiltered(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"sender":   {area: "town", ownAreaOnly: true},
		"filtered": {area: "cave", ownAreaOnly: true},
		"crossmap": {area: "cave", ownAreaOnly: false},
	})
	r.stateRecipients("sender", "town", "town", 100, time.Now())

	r.mu.Lock()
	defer r.mu.Unlock()
	if r.stateRecipientsCross != 2 {
		t.Fatalf("cross-area recipients = %d, want 2 (both peers are elsewhere)", r.stateRecipientsCross)
	}
	if r.stateRecipientsFiltered != 1 {
		t.Fatalf("filtered = %d, want 1 (only the opted-in peer)", r.stateRecipientsFiltered)
	}
	if r.stateBytesForwarded != 100 {
		t.Fatalf("forwarded bytes = %d, want 100 (one recipient survived)", r.stateBytesForwarded)
	}
	if r.stateBytesFiltered != 100 {
		t.Fatalf("filtered bytes = %d, want 100", r.stateBytesFiltered)
	}
}

// A resumed session keeps its player_id but arrives as a brand new *Client, so
// without seeding its cached area would start empty and the filter would fail
// open until its next state landed. Harmless, invisible, and exactly the kind of
// thing that never gets noticed.
func TestResumedClientKeepsItsArea(t *testing.T) {
	r := newRoom("emerald", "", "room1", nil)
	original := &Client{PlayerID: "p1", Conn: &recordingTransport{}, ownAreaOnly: true}
	r.tryAdd(original)
	r.recordState("p1", protocol.State{PlayerID: "p1", AreaID: "cave"})

	resumed := &Client{PlayerID: "p1", Conn: &recordingTransport{}, ownAreaOnly: true}
	r.mu.Lock()
	r.seedLastAreaLocked(resumed)
	r.mu.Unlock()

	if resumed.lastArea != "cave" {
		t.Fatalf("resumed client's area = %q, want %q from the room's own record",
			resumed.lastArea, "cave")
	}
}

// The arrival seed, and why it is required rather than a nicety. A filtered
// client receives nothing from another area, so on arriving it knows nothing
// about who is standing there -- and change suppression (ADR 0039) means a
// motionless peer says nothing for up to IdleKeepalive. Without the seed,
// walking into a room where somebody is standing still shows an empty room and
// pops them in a quarter of a second later, at every seam.
func TestArrivalIsSeededWithPeersAlreadyInTheArea(t *testing.T) {
	r, conns := areaRoom(t, map[string]member{
		"walker":   {area: "town", ownAreaOnly: true},
		"standing": {area: "cave", ownAreaOnly: true},
		"far":      {area: "forest", ownAreaOnly: true},
	})

	r.seedArrivalInto("walker", "cave")

	got := conns["walker"].received(t)
	if len(got) != 1 {
		t.Fatalf("walker received %d seeds, want exactly 1 (the peer in the cave)", len(got))
	}
	var st protocol.State
	if err := json.Unmarshal(got[0].Payload, &st); err != nil {
		t.Fatalf("seed does not decode: %v", err)
	}
	if st.PlayerID != "standing" {
		t.Fatalf("seeded with %q, want the peer standing in the destination area", st.PlayerID)
	}
	// The peer in a third area must not be seeded -- the arrival is joining one
	// area, not being handed the whole room.
	if got := conns["far"].received(t); len(got) != 0 {
		t.Fatalf("a peer in an unrelated area was seeded too: %d message(s)", len(got))
	}
}

// Reliably, not on the lossy state plane. An ordinary state sample may be lost
// because another follows in ~50ms; a seed has no successor.
func TestArrivalSeedIsSentReliably(t *testing.T) {
	r, conns := areaRoom(t, map[string]member{
		"walker":   {area: "town", ownAreaOnly: true},
		"standing": {area: "cave", ownAreaOnly: true},
	})
	r.seedArrivalInto("walker", "cave")

	rt := conns["walker"]
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if len(rt.lossy) != 1 || rt.lossy[0] {
		t.Fatalf("seed lossy flags = %v, want exactly one reliable send", rt.lossy)
	}
}

// A client that never opted in was already receiving every area's traffic, so
// seeding it would deliver a duplicate of something it already has.
func TestClientThatDidNotOptInIsNotSeeded(t *testing.T) {
	r, conns := areaRoom(t, map[string]member{
		"crossmap": {area: "town", ownAreaOnly: false},
		"standing": {area: "cave", ownAreaOnly: true},
	})
	r.seedArrivalInto("crossmap", "cave")
	if got := conns["crossmap"].received(t); len(got) != 0 {
		t.Fatalf("a client receiving everything was seeded anyway: %d message(s)", len(got))
	}
}

// THE BUG THAT REACHED A LIVE SESSION, at the unit level.
//
// A core connects to the relay from its -game flag at startup; its adapter
// attaches when the game launches, which can be minutes later. So the Hello is
// necessarily sent before the core can know whether its adapter renders
// neighbouring areas, and it defaults to own_area_only -- which for Emerald,
// whose cross-map ghosts are a shipped feature, is exactly wrong.
//
// The symptom on 2026-08-28 was a ghost crossing a route seam freezing on the
// tile it entered and vanishing three seconds later: one state delivered by the
// transition rule, then silence, then the stale-after timer. protocol.TypePrefs
// is the correction, and this is it working.
func TestPrefsCanTurnFilteringOffAfterTheHello(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"sender":   {area: "town", ownAreaOnly: true},
		"crossmap": {area: "route", ownAreaOnly: true}, // as its Hello had to guess
	})

	if recipientsOf(r, "sender", "town")["crossmap"] {
		t.Fatal("precondition: a client that declared own_area_only should be filtered")
	}

	// The adapter attaches and declares render_all_areas; the core relays that.
	r.mu.Lock()
	r.members["crossmap"].ownAreaOnly = false
	r.mu.Unlock()

	if !recipientsOf(r, "sender", "town")["crossmap"] {
		t.Fatal("after the adapter declared it renders all areas, the relay must stop filtering — " +
			"this is the Emerald cross-map regression found live on 2026-08-28")
	}
}
