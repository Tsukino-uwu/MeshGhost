package relay

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

const nametagTimeout = 2 * time.Second

// A nametag travels in a Join to those already in the room and in the Welcome to the newcomer; a build with only the
// Join passes every two-player test where one player watches the other arrive.
func TestANametagReachesBothANewcomerAndTheRoom(t *testing.T) {
	addr := startServer(t)

	alice := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID:      "e2egame",
		Room:        "room1",
		DisplayName: "Alice",
		NameColor:   "#F54927",
	})
	alice.expectWelcome(nametagTimeout)

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

	join := waitForJoin(t, alice)
	if join.Nametag == nil {
		t.Fatal("bob's join carried no nametag, so alice would render him unlabelled forever")
	}
	if join.Nametag.Name != "Bob" {
		t.Fatalf("bob joined as %q, want %q", join.Nametag.Name, "Bob")
	}
}

// The shipped default is no name: a nil nametag rather than an empty one, so an adapter draws a label only when one
// is present.
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

func TestTheRelaySanitizesANametagBeforeAnyoneElseSeesIt(t *testing.T) {
	addr := startServer(t)

	watcher := dialTestClient(t, addr, "e2egame", "room1", "watcher")
	watcher.expectWelcome(nametagTimeout)

	// A newline, a bidi override and a zero-width space, and a colour that is not one.
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

// waitForJoin skips other message types: a room's traffic includes states and pongs.
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
