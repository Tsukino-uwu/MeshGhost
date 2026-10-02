package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/paketest"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// rejectCase is one refusal the relay can be driven into, its expected wire reason, and the permanence the core must
// derive from it.
type rejectCase struct {
	name string
	// setup configures a Server for this refusal (nil means the shipped defaults).
	setup func(s *relay.Server)
	// prior is a hello accepted first, for a refusal that depends on a member already in the room: a taken slot, or
	// the room's sticky game_version.
	prior *protocol.Hello
	// hello is the one that must be refused; code, if set, is proven with it.
	hello protocol.Hello
	code  string
	// wantReason is compared to the wire byte for byte.
	wantReason string
	// wantPermanent is what the core's classifier must say about the string that came back, not the constant.
	wantPermanent bool
	why           string
}

// TestRelayRejectReasonsMatchTheConstantsTheCoreClassifies drives a real relay into each refusal and compares the
// reason on the wire with the constant, then classifies that exact string. An unknown reason classifies as
// permanent, so a drifted ReasonServerFull would make a momentarily full room refuse a player for good.
func TestRelayRejectReasonsMatchTheConstantsTheCoreClassifies(t *testing.T) {
	cases := []rejectCase{
		{
			name:          "a protocol version the relay does not speak",
			hello:         protocol.Hello{ProtocolVersion: protocol.MinProtocolVersion - 1, GameID: "emerald", Room: "r"},
			wantReason:    protocol.ReasonProtocolVersionMismatch,
			wantPermanent: true,
			why:           "retrying cannot change the version this build speaks; the player has to update",
		},
		{
			name:          "a wrong room code",
			setup:         func(s *relay.Server) { s.RoomCode = "the-right-one" },
			hello:         protocol.Hello{GameID: "emerald", Room: "r"},
			code:          "not-it",
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
				held := dialRelayHello(t, addr, *tc.prior, "")
				defer held.conn.Close()
				held.expectWelcome(t)
			}

			refused := dialRelayHello(t, addr, tc.hello, tc.code)
			defer refused.conn.Close()
			reject := refused.expectReject(t)
			got := reject.Reason

			if got != tc.wantReason {
				t.Fatalf("the relay refused with %q, but the core recognises %q.\n"+
					"A reason string is a wire value shared by two packages that never see each "+
					"other's code: %s", got, tc.wantReason, tc.why)
			}
			// The string that arrived, not the constant: classifying the constant would be a tautology.
			if permanent := isPermanentRejectReason(got); permanent != tc.wantPermanent {
				t.Fatalf("isPermanentRejectReason(%q) = %v, want %v -- %s", got, permanent, tc.wantPermanent, tc.why)
			}
			// The exported predicate cmd/meshghost's eager -game path uses, wrapped as relaysession.go wraps it.
			if permanent := IsPermanentRejectErr(&RejectError{Reason: got}); permanent != tc.wantPermanent {
				t.Fatalf("IsPermanentRejectErr(RejectError{%q}) = %v, want %v", got, permanent, tc.wantPermanent)
			}

			// Adapters branch on the code, so a code that disagrees with its prose would pass the checks above.
			wantCode := protocol.CodeForReason(tc.wantReason)
			if reject.Code != wantCode {
				t.Fatalf("the relay refused with code %q, want %q for reason %q -- the code is what "+
					"four adapters branch on, and it must name the same refusal the prose does",
					reject.Code, wantCode, got)
			}
			if reject.Retryable == tc.wantPermanent {
				t.Fatalf("the relay sent retryable=%v for %q, which agrees with permanent=%v -- the "+
					"flag is what a client falls back to for a code it does not know, so it must be "+
					"the opposite of permanence", reject.Retryable, got, tc.wantPermanent)
			}
			// The same verdict through the code as through the prose, or an adapter and the core disagree.
			if permanent := isPermanentReject(got, reject.Code, reject.Retryable); permanent != tc.wantPermanent {
				t.Fatalf("isPermanentReject(%q, %q, %v) = %v, want %v", got, reject.Code, reject.Retryable, permanent, tc.wantPermanent)
			}
		})
	}
}

// TestReasonGameMismatchIsClassifiedEvenThoughNoRelaySendsIt: rooms are keyed by (game_id, room), so this relay never
// sends ReasonGameMismatch and the table above cannot drive it, but an older relay still does.
func TestReasonGameMismatchIsClassifiedEvenThoughNoRelaySendsIt(t *testing.T) {
	if protocol.ReasonGameMismatch != "game mismatch for this room" {
		t.Errorf("ReasonGameMismatch = %q -- an older relay on the network still sends the old string, "+
			"and this build must keep classifying it", protocol.ReasonGameMismatch)
	}
	if !isPermanentRejectReason(protocol.ReasonGameMismatch) {
		t.Error("a game mismatch must be permanent: no amount of retrying makes this build a different game")
	}
}

// rejectClient is the smallest relay client that can be refused: a dial, a hello, and a channel of what came back.
// Not a whole Core, which retries and turns the reason into an error; this needs the bytes the relay wrote.
type rejectClient struct {
	conn *transport.NDJSONConn
	envs chan protocol.Envelope
}

func startRejectRelay(t *testing.T, s *relay.Server) string {
	t.Helper()
	ln := listenTLS(t)
	go s.Serve(ln)
	return ln.Addr().String()
}

func dialRelayHello(t *testing.T, addr string, hello protocol.Hello, code string) *rejectClient {
	t.Helper()
	conn := transport.FromConn(dialRelayTLS(t, addr))
	prover := paketest.New(t, code, "")
	hello.PakeKE1 = prover.KE1()
	rc := &rejectClient{conn: conn, envs: make(chan protocol.Envelope, 8)}
	conn.OnReceive(func(payload []byte) {
		if prover.Handle(payload, conn.Send) {
			return
		}
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
	// The welcome, not the dial, takes the slot and sets the sticky game_version, so a refusal that depends on
	// either waits for it.
	if env := rc.next(t); env.Type != protocol.TypeWelcome {
		t.Fatalf("the member that must be accepted first got %q, not a welcome", env.Type)
	}
}

func (rc *rejectClient) expectReject(t *testing.T) protocol.Reject {
	t.Helper()
	env := rc.next(t)
	if env.Type != protocol.TypeReject {
		t.Fatalf("got %q, want a reject -- the relay accepted a hello this test needs it to refuse", env.Type)
	}
	var rej protocol.Reject
	if err := json.Unmarshal(env.Payload, &rej); err != nil {
		t.Fatalf("unmarshal reject: %v", err)
	}
	// The whole refusal: the code and the retryable flag are what a client branches on.
	return rej
}
