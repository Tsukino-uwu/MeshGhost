package relay

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// The relay's area filter is a strict subset of core.remoteStatesAt's render-time check, which stays: it declines
// only what the recipient's core would discard, except the departure case below.

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

// Absent own_area_only means send everything: an adapter that renders adjacent areas declares render_all_areas, and
// an older client never sends the field.
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

// An unknown area on either side fails open, mirroring core.remoteStatesAt.
func TestUnknownAreaFailsOpen(t *testing.T) {
	t.Run("recipient area unknown", func(t *testing.T) {
		r := newRoom("emerald", "", "room1", nil)
		r.tryAdd(&Client{PlayerID: "sender", Conn: &recordingTransport{}, ownAreaOnly: true})
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

// Per recipient, not per room: one cross-map client must not switch filtering off for everyone else.
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

// The first state carrying a peer's new area is what despawns its ghost in the area it left; filtered, the ghost
// freezes at the doorway until core.DefaultRemoteStaleAfter ages it out.
func TestDepartingPeerDespawnsOnItsOwnStateNotByAgeOut(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"walker":    {area: "town", ownAreaOnly: true},
		"stayer":    {area: "town", ownAreaOnly: true},
		"unrelated": {area: "cave", ownAreaOnly: true},
	})

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

func TestDepartureDeliveryIsOnlyForTheCrossingState(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"walker": {area: "cave", ownAreaOnly: true},
		"stayer": {area: "town", ownAreaOnly: true},
	})
	// recipientsOf passes the area as prevArea too: the walker has settled in the cave.
	if recipientsOf(r, "walker", "cave")["stayer"] {
		t.Fatal("after the crossing, states must be filtered from the old area again")
	}
}

// Conflated, the introspect line would report a shrinking opportunity as the filter improved.
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

// A resumed session arrives as a new *Client; unseeded, its area is empty and the filter fails open until its next
// state.
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

// A filtered client heard nothing from the area it enters, and a motionless peer there is silent until IdleKeepalive.
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
	if got := conns["far"].received(t); len(got) != 0 {
		t.Fatalf("a peer in an unrelated area was seeded too: %d message(s)", len(got))
	}
}

// A lost state sample is covered by the next one; a seed has no successor.
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

// The Hello goes out before the adapter attaches, so its own_area_only is a guess; the prefs an attaching adapter
// sends must be able to turn filtering off.
func TestPrefsCanTurnFilteringOffAfterTheHello(t *testing.T) {
	r, _ := areaRoom(t, map[string]member{
		"sender":   {area: "town", ownAreaOnly: true},
		"crossmap": {area: "route", ownAreaOnly: true}, // as its Hello had to guess
	})

	if recipientsOf(r, "sender", "town")["crossmap"] {
		t.Fatal("precondition: a client that declared own_area_only should be filtered")
	}

	// The prefs from an adapter that declared render_all_areas.
	r.mu.Lock()
	r.members["crossmap"].ownAreaOnly = false
	r.mu.Unlock()

	if !recipientsOf(r, "sender", "town")["crossmap"] {
		t.Fatal("after the adapter declared it renders all areas, the relay must stop filtering — " +
			"this is the Emerald cross-map regression found live on 2026-08-28")
	}
}
