package relay

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// A refused hello must be TERMINAL for that connection.
//
// Only the rate-limit path latched. The handshake refusals did not, and
// transport.CloseGracefully deliberately keeps READING and dispatching for
// handshakeCloseDrain so the Reject is not lost to a reset -- so every line a
// refused client had already pipelined re-entered the whole hello block:
// ValidateHelloFields, the room-code compare, joinOrCreateRoom, tryReserveSlot,
// nextPlayerID, newOutbox, and the Join broadcast.
//
// The worst case is this one: a peer refused for a wrong room code sends a
// SECOND hello, with the right code, on the same already-refused connection --
// and completes a genuine join over a socket whose write side is closed. It
// takes a max_clients slot, gets a player_id, and spawns a ghost on every real
// player's screen that despawns again ~2s later when the drain ends.
//
// This was masked until 2026-09-07: netx's limiter hid CloseWrite, so
// CloseGracefully degraded to a hard Close and there was no drain to re-enter.
// Fixing the wrapper without latching would have exposed this to every client
// rather than only TLS ones, which is why the two landed together.
func TestASecondHelloAfterARejectIsIgnored(t *testing.T) {
	s := NewServer()
	s.RoomCode = "letmein"
	addr := startServerWith(t, s)

	// A real member, so a phantom join would have somebody to be announced to.
	witness := dialTestClientWithHello(t, addr, protocol.Hello{
		GameID: "emerald", Room: "room1", DisplayName: "witness", RoomCode: "letmein",
	})
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
		// An error here is expected for the second one once the write side is
		// closed, and is not the thing under test -- the point is what the relay
		// does with a line that DOES arrive, which is why the two are sent back
		// to back with no wait between them.
		_ = conn.Send(env)
	}

	// Refused: wrong room code.
	send(protocol.Hello{GameID: "emerald", Room: "room1", DisplayName: "intruder", RoomCode: "wrong"})
	// ...and immediately the correct one, into the drain window.
	send(protocol.Hello{GameID: "emerald", Room: "room1", DisplayName: "intruder", RoomCode: "letmein"})

	// Exactly one Reject, and never a Welcome.
	var rejects int
	deadline := time.After(2 * time.Second)
collect:
	for {
		select {
		case env := <-envs:
			switch env.Type {
			case protocol.TypeReject:
				rejects++
			case protocol.TypeWelcome:
				t.Fatal("the relay welcomed a second hello sent on an already-rejected " +
					"connection: a refusal must be terminal for that connection, or a refused " +
					"peer can join over a half-closed socket")
			}
		case <-deadline:
			break collect
		}
	}
	if rejects != 1 {
		t.Fatalf("got %d rejects, want exactly 1 (a second reject means the refused hello was "+
			"re-processed during the close drain)", rejects)
	}

	// And the witness must never have been told anybody joined.
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

	// The room still holds only the witness: no slot was reserved for the refusal.
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
