package core

import (
	"testing"
	"time"
)

// TestAPeerAlreadyInTheRoomIsLearnedFromTheWelcomeRoster: Join covers only peers who arrive later, so a build missing
// the roster half passes every hand test where one player joins while the other watches.
func TestAPeerAlreadyInTheRoomIsLearnedFromTheWelcomeRoster(t *testing.T) {
	addr := startRelay(t)

	_, _ = startCore(t, addr, "nametaggame", "room1", "Alice")

	// Bob arrives second, so he can only learn Alice's name from his Welcome.
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

// TestAPeerWithNoNameIsNeverStored: no entry rather than an empty name, because the adapter draws a label only when
// one is present, and no name is the shipped default.
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

// TestAnAttachingAdapterIsToldAboutNamesAlreadyInTheRoom asserts what the adapter is told, not what the core learned,
// in the order a player has: a peer already in the room, then the game launches and its adapter attaches.
func TestAnAttachingAdapterIsToldAboutNamesAlreadyInTheRoom(t *testing.T) {
	addr := startRelay(t)

	alice, _ := startCore(t, addr, "nametaggame", "room1", "Alice")
	waitForPlayerID(t, alice)
	alicePlayerID := alice.PlayerID()

	// The game launches: a lazy core, and an adapter that attaches and drives the connect.
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
