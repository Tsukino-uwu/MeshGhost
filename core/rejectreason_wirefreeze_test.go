package core

import (
	"encoding/json"
	"net"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// WHY THIS FILE EXISTS (2026-09-08). Nothing in the suite asserted that the relay emits any
// reject reason BY VALUE. The two halves each tested their own side of the seam and neither
// tested the seam: relay's own test asserts only that reject.Reason != "", and core's
// classification test feeds the protocol CONSTANT into isPermanentRejectReason, which is a
// mapping test over constants and cannot notice the relay sending a different string.
//
// The consequence is not cosmetic. isPermanentRejectReason classifies anything it does not
// recognise as PERMANENT (deliberately -- an unknown reason from a future relay must not be
// retried forever), and "server full" is one of the two reasons that must be RETRYABLE. So if
// the relay's literal for ReasonServerFull ever drifts -- a reworded string, or a constant at
// one call site and a hand-typed literal at another -- a client refused because a room was
// momentarily full caches that as permanent, stops reconnecting, and tells the player the relay
// refused them for good. Every test in the repo stays green while it happens, because no test
// ever compared what the relay sent with what the core recognises.
//
// So this drives a REAL relay into each refusal and compares the reason it actually put on the
// wire against the constant, then asserts the permanence the core would derive from that exact
// string. Both halves matter: the value pins the wire, and the classification pins the
// behavioural consequence of that value.

// rejectCase is one refusal the relay can be driven into, its expected wire reason, and the
// permanence the core must derive from it.
type rejectCase struct {
	name string
	// setup configures a Server for this refusal (nil means the shipped defaults).
	setup func(s *relay.Server)
	// prior is a hello that must be accepted first, when the refusal depends on state a member
	// already in the room established: a taken slot, or the room's sticky game_version.
	prior *protocol.Hello
	// hello is the one that must be refused.
	hello protocol.Hello
	// wantReason is compared to the wire byte for byte -- the whole point of the test.
	wantReason string
	// wantPermanent is what core's own classifier must say about the string that came back, not
	// about the constant. ServerFull is the one that must be retryable.
	wantPermanent bool
	why           string
}

func TestRelayRejectReasonsMatchTheConstantsTheCoreClassifies(t *testing.T) {
	cases := []rejectCase{
		{
			name:          "a protocol version the relay does not speak",
			hello:         protocol.Hello{ProtocolVersion: protocol.Version + 1, GameID: "emerald", Room: "r"},
			wantReason:    protocol.ReasonProtocolVersionMismatch,
			wantPermanent: true,
			why:           "retrying cannot change the version this build speaks; the player has to update",
		},
		{
			name:          "a wrong room code",
			setup:         func(s *relay.Server) { s.RoomCode = "the-right-one" },
			hello:         protocol.Hello{GameID: "emerald", Room: "r", RoomCode: "not-it"},
			wantReason:    protocol.ReasonInvalidRoomCode,
			wantPermanent: true,
			why:           "the code came from config; retrying re-sends the same wrong one forever",
		},
		{
			name:          "a game_version the room's first member did not have",
			prior:         &protocol.Hello{GameID: "emerald", Room: "r", GameVersion: "phase9"},
			hello:         protocol.Hello{GameID: "emerald", Room: "r", GameVersion: "phase10"},
			wantReason:    protocol.ReasonGameVersionMismatch,
			wantPermanent: true,
			why:           "the room is stuck on its first member's version for as long as it exists",
		},
		{
			// MaxClients is a relay-wide count, so one accepted member fills a relay of one.
			name:          "a relay already at MaxClients",
			setup:         func(s *relay.Server) { s.MaxClients = 1 },
			prior:         &protocol.Hello{GameID: "emerald", Room: "r"},
			hello:         protocol.Hello{GameID: "emerald", Room: "r"},
			wantReason:    protocol.ReasonServerFull,
			wantPermanent: false,
			why: "THE ONE THAT COSTS A SESSION IF IT DRIFTS: a full relay empties when somebody " +
				"leaves, so a client that caches this as permanent never comes back",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			s := relay.NewServer()
			if tc.setup != nil {
				tc.setup(s)
			}
			addr := startRejectRelay(t, s)

			if tc.prior != nil {
				held := dialRelayHello(t, addr, *tc.prior)
				defer held.conn.Close()
				held.expectWelcome(t)
			}

			refused := dialRelayHello(t, addr, tc.hello)
			defer refused.conn.Close()
			got := refused.expectReject(t)

			if got != tc.wantReason {
				t.Fatalf("the relay refused with %q, but the core recognises %q.\n"+
					"A reason string is a wire value shared by two packages that never see each "+
					"other's code: %s", got, tc.wantReason, tc.why)
			}
			// Deliberately classifying the string that ARRIVED, not the constant. Feeding the
			// constant back in is the tautology this test exists to replace.
			if permanent := isPermanentRejectReason(got); permanent != tc.wantPermanent {
				t.Fatalf("isPermanentRejectReason(%q) = %v, want %v -- %s", got, permanent, tc.wantPermanent, tc.why)
			}
			// And the exported predicate a caller with its own retry loop actually uses
			// (cmd/meshghost's eager -game path), over the wire string wrapped exactly as
			// relaysession.go wraps it.
			if permanent := IsPermanentRejectErr(&RejectError{Reason: got}); permanent != tc.wantPermanent {
				t.Fatalf("IsPermanentRejectErr(RejectError{%q}) = %v, want %v", got, permanent, tc.wantPermanent)
			}
		})
	}
}

// TestReasonGameMismatchIsClassifiedEvenThoughNoRelaySendsIt records the one reason in this
// group that the table above cannot drive a real relay into, so its absence there is a stated
// fact rather than an oversight the next reader has to re-derive.
//
// Since rooms became keyed by (game_id, room) on 2026-08-17, a client only ever reaches its own
// game's room, so joinOrCreateRoom cannot return ReasonGameMismatch -- relay.go says so in as
// many words and keeps the constant "only for the wire", because an OLDER relay still sends it
// and a client must still understand it. That is exactly why the classification still has to be
// pinned: it is a string that arrives from a peer this build cannot produce, which is the case
// least likely to be noticed if it changed.
func TestReasonGameMismatchIsClassifiedEvenThoughNoRelaySendsIt(t *testing.T) {
	if protocol.ReasonGameMismatch != "game mismatch for this room" {
		t.Errorf("ReasonGameMismatch = %q -- an older relay on the network still sends the old string, "+
			"and this build must keep classifying it", protocol.ReasonGameMismatch)
	}
	if !isPermanentRejectReason(protocol.ReasonGameMismatch) {
		t.Error("a game mismatch must be permanent: no amount of retrying makes this build a different game")
	}
}

// rejectClient is the smallest relay client that can be refused: a dial, a hello, and a channel
// of whatever came back. Deliberately not core_test.go's fakeAdapter or a whole Core -- a Core
// retries, backs off and turns the reason into an error on the way past, and this test needs the
// bytes the relay actually wrote.
type rejectClient struct {
	conn *transport.NDJSONConn
	envs chan protocol.Envelope
}

func startRejectRelay(t *testing.T, s *relay.Server) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go s.Serve(ln)
	return ln.Addr().String()
}

func dialRelayHello(t *testing.T, addr string, hello protocol.Hello) *rejectClient {
	t.Helper()
	conn, err := transport.Dial(addr)
	if err != nil {
		t.Fatalf("dial relay: %v", err)
	}
	rc := &rejectClient{conn: conn, envs: make(chan protocol.Envelope, 8)}
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			return
		}
		select {
		case rc.envs <- env:
		default:
		}
	})
	if hello.ProtocolVersion == 0 {
		hello.ProtocolVersion = protocol.Version
	}
	helloBytes, err := json.Marshal(hello)
	if err != nil {
		t.Fatalf("marshal hello: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: helloBytes})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	if err := conn.Send(env); err != nil {
		t.Fatalf("send hello: %v", err)
	}
	return rc
}

func (rc *rejectClient) next(t *testing.T) protocol.Envelope {
	t.Helper()
	select {
	case env := <-rc.envs:
		return env
	case <-time.After(testTimeout):
		t.Fatal("timed out waiting for the relay's answer to a hello")
		return protocol.Envelope{}
	}
}

func (rc *rejectClient) expectWelcome(t *testing.T) {
	t.Helper()
	// The slot and the room's sticky game_version are established by the WELCOME, not by the
	// dial, so a case whose refusal depends on either must wait for it. Racing it would make
	// the refusal the flaky kind that passes on a fast box.
	if env := rc.next(t); env.Type != protocol.TypeWelcome {
		t.Fatalf("the member that must be accepted first got %q, not a welcome", env.Type)
	}
}

func (rc *rejectClient) expectReject(t *testing.T) string {
	t.Helper()
	env := rc.next(t)
	if env.Type != protocol.TypeReject {
		t.Fatalf("got %q, want a reject -- the relay accepted a hello this test needs it to refuse", env.Type)
	}
	var rej protocol.Reject
	if err := json.Unmarshal(env.Payload, &rej); err != nil {
		t.Fatalf("unmarshal reject: %v", err)
	}
	return rej.Reason
}
