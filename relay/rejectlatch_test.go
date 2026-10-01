package relay

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/paketest"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// A refused hello is terminal: CloseGracefully keeps reading through handshakeCloseDrain, so a second hello with the
// right code could otherwise join over the half-closed socket, take a slot and flash a ghost on every screen.
func TestASecondHelloAfterARejectIsIgnored(t *testing.T) {
	s := NewServer()
	s.RoomCode = "letmein"
	addr := startServerWith(t, s)

	// A real member, so a phantom join has somebody to be announced to.
	witness := dialTestClientWithCode(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "witness",
	}, "letmein")
	defer witness.conn.Close()
	awaitWelcome(t, witness)

	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()

	envs := make(chan protocol.Envelope, 16)
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			return
		}
		envs <- env
	})

	send := func(hello protocol.Hello) {
		t.Helper()
		hello.ProtocolVersion = protocol.Version
		hb, err := json.Marshal(hello)
		if err != nil {
			t.Fatalf("marshal hello: %v", err)
		}
		env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hb})
		if err != nil {
			t.Fatalf("marshal envelope: %v", err)
		}
		// The second Send may fail once the write side closes; what matters is a line that does arrive.
		_ = conn.Send(env)
	}

	// A KE1 the relay cannot parse is refused at once.
	send(protocol.Hello{GameID: "emerald", Room: "room1", DisplayName: "intruder", PakeKE1: "bm90IGEga2Ux"})
	// A real KE1 straight into the drain window, which the relay must not even answer with a KE2.
	send(protocol.Hello{GameID: "emerald", Room: "room1", DisplayName: "intruder",
		PakeKE1: paketest.New(t, "letmein", "").KE1()})

	var rejects int
	deadline := time.After(2 * time.Second)
collect:
	for {
		select {
		case env := <-envs:
			switch env.Type {
			case protocol.TypeReject:
				rejects++
			case protocol.TypeWelcome, protocol.TypePake:
				t.Fatalf("the relay answered (%q) a second hello sent on an already-rejected "+
					"connection: a refusal must be terminal for that connection, or a refused "+
					"peer can join over a half-closed socket", env.Type)
			}
		case <-deadline:
			break collect
		}
	}
	if rejects != 1 {
		t.Fatalf("got %d rejects, want exactly 1 (a second reject means the refused hello was "+
			"re-processed during the close drain)", rejects)
	}

	select {
	case env := <-witness.envs:
		if env.Type == protocol.TypeJoin {
			var join protocol.Join
			_ = json.Unmarshal(env.Payload, &join)
			t.Fatalf("a real player was told %q joined, but that connection had already been "+
				"refused -- a phantom ghost spawns and despawns on every screen in the room",
				join.PlayerID)
		}
	case <-time.After(200 * time.Millisecond):
	}

	s.mu.Lock()
	room := s.rooms[roomKey("emerald", "room1")]
	s.mu.Unlock()
	if room == nil {
		t.Fatal("the room disappeared")
	}
	if got := room.size(); got != 1 {
		t.Fatalf("room holds %d members, want 1 (the witness) -- a refused hello reserved a "+
			"max_clients slot", got)
	}
}
