package relay

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

const nametagTimeout = 2 * time.Second

// A nametag reaches the people who need it by two DIFFERENT routes, and both
// have to work or the feature is half-built:
//
//	Join    -- for somebody arriving while you are already in the room.
//	Welcome -- for the people already standing there when YOU arrive.
//
// Only the first is obvious, and a build with only the first looks fine in
// every two-player test where one player joins after the other is watching.
func TestANametagReachesBothANewcomerAndTheRoom(t *testing.T) {
	addr := startServer(t)

	// alice is already in the room, with a name and a colour.
	alice := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID:      "e2egame",
		Room:        "room1",
		DisplayName: "Alice",
		NameColor:   "#F54927",
	})
	alice.expectWelcome(nametagTimeout)

	// bob arrives after her, so his Welcome must carry HER tag.
	bob := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID:      "e2egame",
		Room:        "room1",
		DisplayName: "Bob",
	})
	bobWelcome := bob.expectWelcome(nametagTimeout)

	if len(bobWelcome.Nametags) != 1 {
		t.Fatalf("bob's welcome carried %d nametags, want 1 (alice's) -- a player who joins a "+
			"room that already has people in it learns their names ONLY here",
			len(bobWelcome.Nametags))
	}
	var aliceTag protocol.Nametag
	for _, tag := range bobWelcome.Nametags {
		aliceTag = tag
	}
	if aliceTag.Name != "Alice" {
		t.Fatalf("welcome roster named alice %q, want %q", aliceTag.Name, "Alice")
	}
	if aliceTag.Color != "#F54927" {
		t.Fatalf("welcome roster gave alice colour %q, want %q", aliceTag.Color, "#F54927")
	}

	// And alice, who was already watching, must get bob's tag in his Join.
	join := waitForJoin(t, alice)
	if join.Nametag == nil {
		t.Fatal("bob's join carried no nametag, so alice would render him unlabelled forever")
	}
	if join.Nametag.Name != "Bob" {
		t.Fatalf("bob joined as %q, want %q", join.Nametag.Name, "Bob")
	}
}

// THE DEFAULT IS NO NAME, so the default must put nothing on the wire at all.
//
// This is the shipped configuration -- the name field is empty unless somebody
// deliberately sets one -- which makes it the case most worth pinning: a nil
// nametag rather than a present-but-empty one, so an adapter's "do I draw a
// label?" question is answered by the field's absence and cannot be got wrong.
func TestAPlayerWithNoNameCarriesNoNametagAnywhere(t *testing.T) {
	addr := startServer(t)

	watcher := dialTestClient(t, addr, "e2egame", "room1", "")
	welcome := watcher.expectWelcome(nametagTimeout)
	if len(welcome.Nametags) != 0 {
		t.Fatalf("an empty room produced %d nametags, want none", len(welcome.Nametags))
	}

	dialTestClient(t, addr, "e2egame", "room1", "")

	join := waitForJoin(t, watcher)
	if join.Nametag != nil {
		t.Fatalf("a player with no name joined carrying nametag %+v -- the default must be "+
			"NOTHING, so an adapter draws no label rather than an empty one", *join.Nametag)
	}
}

// The relay is the trust boundary: whatever a client puts in its Hello, what
// reaches everybody else is sanitized. A client cannot opt out of this by
// being the one who typed it.
func TestTheRelaySanitizesANametagBeforeAnyoneElseSeesIt(t *testing.T) {
	addr := startServer(t)

	watcher := dialTestClient(t, addr, "e2egame", "room1", "watcher")
	watcher.expectWelcome(nametagTimeout)

	// A name carrying the three attacks at once, and a colour that is not one.
	dialTestClientWithHello(t, addr, protocol.Hello{
		GameID:      "e2egame",
		Room:        "room1",
		DisplayName: "ali\nce‮bob​",
		NameColor:   "javascript:alert(1)",
	})

	join := waitForJoin(t, watcher)
	if join.Nametag == nil {
		t.Fatal("the whole name was dropped; enough of it was legitimate to survive")
	}
	if got, want := join.Nametag.Name, "alicebob"; got != want {
		t.Fatalf("forwarded name %q, want %q -- the newline (log injection), the bidi override "+
			"(on-screen impersonation) and the zero-width space must all be gone", got, want)
	}
	if join.Nametag.Color != "" {
		t.Fatalf("forwarded colour %q, want empty -- anything that is not a hex colour is "+
			"dropped rather than passed to a game's text renderer", join.Nametag.Color)
	}
}

// waitForJoin returns the next Join this client receives, failing the test if
// one does not arrive. Other message types are skipped rather than treated as
// failures: a room's traffic legitimately includes states and pongs.
func waitForJoin(t *testing.T, tc *testClient) protocol.Join {
	t.Helper()
	deadline := time.After(nametagTimeout)
	for {
		select {
		case env := <-tc.envs:
			if env.Type != protocol.TypeJoin {
				continue
			}
			var j protocol.Join
			if err := json.Unmarshal(env.Payload, &j); err != nil {
				t.Fatalf("malformed join: %v", err)
			}
			return j
		case <-deadline:
			t.Fatal("no join arrived")
		}
	}
}
