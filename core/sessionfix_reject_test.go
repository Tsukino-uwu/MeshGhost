package core

import (
	"bufio"
	"encoding/json"
	"errors"
	"log"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestARejectWinsARaceAgainstTheSocketClosing: the relay rejects and closes, so the handshake select can find the
// reject channel and the gone channel both ready, and a select picks either at random. The reject must win, or
// IsPermanentRejectErr never sees it. The relay half-closes so its reject and FIN arrive together while the client's
// hello write still completes; repeated, since one attempt exercises one ordering.
func TestARejectWinsARaceAgainstTheSocketClosing(t *testing.T) {
	ln := listenTLS(t)

	payload, err := json.Marshal(protocol.Reject{
		Reason:    "invalid room code",
		Code:      protocol.CodeInvalidRoomCode,
		Retryable: false,
	})
	if err != nil {
		t.Fatalf("marshal reject: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeReject, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}
	line := append(env, '\n')

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				// Before the hello is read, so the refusal is in flight while the client heads for the select.
				if _, err := conn.Write(line); err != nil {
					return
				}
				// A *tls.Conn's CloseWrite sends close_notify, the end of the stream to the client's reader.
				if cw, ok := conn.(interface{ CloseWrite() error }); ok {
					_ = cw.CloseWrite()
				}
				// Drain, so the deferred Close does not end the client's hello write.
				_, _ = bufio.NewReader(conn).ReadString('\n')
			}(conn)
		}
	}()

	// Holds the client back until the refusal and the FIN have both landed, or the reject almost always reaches an
	// already-parked select and the ordering under test never happens.
	hook := func() { time.Sleep(20 * time.Millisecond) }
	beforeHandshakeSelectHook.Store(&hook)
	t.Cleanup(func() { beforeHandshakeSelectHook.Store(nil) })

	for i := 0; i < 40; i++ {
		c := New()
		c.RelayAddr = ln.Addr().String()
		c.Room = "room1"
		c.RoomCode = "wrong"
		c.DialTimeout = testTimeout
		err := c.ConnectRelay("fuzzgame")

		var rej *RejectError
		if !errors.As(err, &rej) {
			t.Fatalf("attempt %d: ConnectRelay returned %v, want a *RejectError -- the refusal was "+
				"lost to the socket closing, so IsPermanentRejectErr cannot see it and this wrong "+
				"room code will be redialled every 15 s forever without ever naming the reason", i, err)
		}
		if rej.Reason != "invalid room code" || rej.Code != protocol.CodeInvalidRoomCode || rej.Retryable {
			t.Fatalf("attempt %d: reject reached the caller stripped: %+v -- Code and Retryable are "+
				"what every adapter branches on", i, *rej)
		}
	}
}

// TestAMidSessionRejectReasonReachesTheLog: a Reject after the handshake must be logged with its reason, for a
// person, and its code, the stable name a log reader matches on, not lost in a channel nobody reads.
func TestAMidSessionRejectReasonReachesTheLog(t *testing.T) {
	var logged lockedBuffer
	prevOut := log.Writer()
	prevFlags := log.Flags()
	log.SetOutput(&logged)
	log.SetFlags(0)
	t.Cleanup(func() {
		log.SetOutput(prevOut)
		log.SetFlags(prevFlags)
	})

	c := New()
	// playerID is how a post-handshake Reject is told apart from one the connect is still waiting on.
	c.mu.Lock()
	c.playerID = "p1"
	c.mu.Unlock()

	payload, err := json.Marshal(protocol.Reject{
		Reason:    "sending too fast, slow down",
		Code:      protocol.CodeRateLimited,
		Retryable: true,
	})
	if err != nil {
		t.Fatalf("marshal reject: %v", err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeReject, Payload: payload})
	if err != nil {
		t.Fatalf("marshal envelope: %v", err)
	}

	// The handshake's channels as ConnectRelay leaves them: empty and buffered.
	c.handleRelayMessage(nil, env, make(chan protocol.Welcome, 1), make(chan protocol.Reject, 1))

	got := logged.linesMentioning("relay closed this connection")
	if !strings.Contains(got, "sending too fast, slow down") {
		t.Fatalf("the mid-session reject reason never reached the log (got %q) -- the player is "+
			"disconnected and told nothing but EOF", got)
	}
	if !strings.Contains(got, protocol.CodeRateLimited) {
		t.Fatalf("the mid-session reject was logged without its code (got %q) -- the code is the "+
			"machine-readable half, and prose is what four adapters branched on before it existed",
			got)
	}
}

// TestTheEmittedClockDoesNotStepBackWhenTheRelayDrops: a relay drop resets the clock offset, or a new relay's clock
// is answered with the old one's, but keeps the monotonic clamp, since a rewound clock leaves remote buffers
// unsorted and seams the whole chaser pack.
func TestTheEmittedClockDoesNotStepBackWhenTheRelayDrops(t *testing.T) {
	c := New()
	c.activeFeatures = []string{protocol.FeatureClockV1}
	c.clock = clockSync{offsetMs: 5000, bestRTTMs: 20}

	before := c.nowMs()

	c.mu.Lock()
	c.forgetRelaySessionLocked()
	offsetCleared := c.clock == clockSync{}
	c.mu.Unlock()

	if !offsetCleared {
		t.Fatal("the relay's clock offset survived the drop -- the next relay's clock would be " +
			"answered with this one's")
	}

	// Repeatedly: the clamp must hold until real time catches up, not only on the first call.
	deadline := time.Now().Add(50 * time.Millisecond)
	for time.Now().Before(deadline) {
		if got := c.nowMs(); got < before {
			t.Fatalf("nowMs fell from %d to %d across the relay drop (a +5 s room) -- every "+
				"outgoing timestamp is now in the past, every peer buffer goes unsorted, and the "+
				"chaser pack despawns and respawns on the player", before, got)
		}
	}
}
