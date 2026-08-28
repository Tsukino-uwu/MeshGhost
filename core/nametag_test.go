package core

import (
	"testing"
	"time"
)

// A NAME REACHES A CLIENT BY TWO ROUTES, AND ONLY ONE OF THEM IS EASY TO NOTICE.
//
// Join covers a peer who arrives while you are watching. Welcome covers the peers who were
// ALREADY standing in the room when you arrived. A build with only the first half looks correct in
// every test where one player joins while the other watches -- which is the natural way to test it
// by hand, and is how this was tested live: it worked, twice, and then failed the moment the peer
// happened to connect first.
//
// This is the free version of that live test, which is the point: the bug is in Go, and Go is
// verified with tools rather than by asking somebody to relaunch a game.
func TestAPeerAlreadyInTheRoomIsLearnedFromTheWelcomeRoster(t *testing.T) {
	addr := startRelay(t)

	// Alice is in the room FIRST, with a name.
	_, _ = startCore(t, addr, "nametaggame", "room1", "Alice")

	// Bob arrives second, so Alice can only reach him through his Welcome.
	bob, _ := startCore(t, addr, "nametaggame", "room1", "Bob")

	deadline := time.Now().Add(testTimeout)
	var names map[string]string
	for time.Now().Before(deadline) {
		snapshot := bob.remoteNamesSnapshot()
		if len(snapshot) > 0 {
			names = make(map[string]string, len(snapshot))
			for id, tag := range snapshot {
				names[id] = tag.Name
			}
			break
		}
		time.Sleep(5 * time.Millisecond)
	}

	if len(names) == 0 {
		t.Fatal("bob learned NO nametags -- alice was already in the room when he joined, so her " +
			"name can only arrive in his Welcome roster. With this broken, anybody already " +
			"present when you launch stays unlabelled for the whole session while people who " +
			"join later get labels, which reads as nametags being broken at random")
	}
	for id, name := range names {
		if name != "Alice" {
			t.Fatalf("bob learned %q for %s, want %q", name, id, "Alice")
		}
	}
}

// The other direction, which is the one that already worked -- kept so a fix to the roster path
// cannot quietly break the arrival path.
func TestAPeerWhoArrivesLaterIsLearnedFromItsJoin(t *testing.T) {
	addr := startRelay(t)

	alice, _ := startCore(t, addr, "nametaggame", "room1", "Alice")
	_, _ = startCore(t, addr, "nametaggame", "room1", "Bob")

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		for _, tag := range alice.remoteNamesSnapshot() {
			if tag.Name == "Bob" {
				return
			}
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("alice never learned bob's name from his Join")
}

// A player with no name must produce no entry at all, rather than an entry with an empty name --
// the adapter's "should I draw a label?" is answered by absence, and this is the shipped default.
func TestAPeerWithNoNameIsNeverStored(t *testing.T) {
	addr := startRelay(t)

	_, _ = startCore(t, addr, "nametaggame", "room1", "")
	watcher, _ := startCore(t, addr, "nametaggame", "room1", "")

	// Give the roster and any Join time to arrive before concluding nothing did.
	time.Sleep(200 * time.Millisecond)

	if names := watcher.remoteNamesSnapshot(); len(names) != 0 {
		t.Fatalf("a room where nobody set a name produced %d stored nametag(s): %v", len(names), names)
	}
}

// THE TEST THAT WOULD HAVE CAUGHT THE REAL BUG, which the three above did not.
//
// They assert what the CORE learned. This asserts what the ADAPTER was told -- and the whole
// defect lived in the gap between those two, so every one of them passed while a nametag was
// invisible in a real game.
//
// The shape is the one a player actually has: somebody is already in the room, THEN the game
// launches and its adapter attaches. That ordering is what made it fail, because the handshake
// completed before the roster's names were stored, so the push at attach found an empty map.
// A peer who joins later takes a different path entirely and always worked, which is exactly why
// two live tests in a row looked fine.
func TestAnAttachingAdapterIsToldAboutNamesAlreadyInTheRoom(t *testing.T) {
	addr := startRelay(t)

	// Already here, named, before this client exists at all.
	alice, _ := startCore(t, addr, "nametaggame", "room1", "Alice")
	waitForPlayerID(t, alice)
	alicePlayerID := alice.PlayerID()

	// Now the game launches: a lazy core, and an adapter that attaches and drives the connect.
	_, bridgeAddr := startCoreLazy(t, addr, "room1", "Bob")
	fa := reattachFakeAdapter(t, bridgeAddr, "nametaggame")

	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		fa.mu.Lock()
		got, ok := fa.names[alicePlayerID]
		fa.mu.Unlock()
		if ok {
			if got.DisplayName != "Alice" {
				t.Fatalf("adapter was told %q for %s, want %q", got.DisplayName, alicePlayerID, "Alice")
			}
			return
		}
		time.Sleep(5 * time.Millisecond)
	}

	t.Fatalf("the adapter was never told %s's name. It is in the room and the core knows the "+
		"name -- but the handover at attach happened first, so a peer who was already present "+
		"renders with no label for the entire session while anyone joining later gets one",
		alicePlayerID)
}
