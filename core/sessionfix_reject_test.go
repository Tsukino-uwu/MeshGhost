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

// TestARejectWinsARaceAgainstTheSocketClosing is the regression test for the
// refusal that told the player nothing (found in the 2026-09-07 review pass,
// fixed 2026-09-08).
//
// The relay writes the Reject and closes immediately after (rejectAndClose),
// so by the time ConnectRelay reaches its handshake select, the buffered reject
// channel holds a value AND the gone channel is already closed. A select with
// two ready cases picks uniformly at random, so roughly half of all refusals
// returned a plain "dropped before the welcome arrived" instead of a
// *RejectError -- IsPermanentRejectErr never saw it, and a wrong room code was
// redialled every 15 s for the life of the process while the log never once
// named the reason the player had to fix.
//
// The relay here half-closes (CloseWrite) rather than closing outright: that
// puts the reject bytes and the FIN on the wire together, which is what makes
// both channels ready before the select is reached, while leaving the client's
// own hello write able to complete. A hard close would race the hello send and
// turn some attempts into a transport error, testing nothing.
//
// Repeated, because a select is free to take either branch: one attempt only
// ever exercises one ordering. With the fix removed this fails within a
// handful of attempts.
func TestARejectWinsARaceAgainstTheSocketClosing(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

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
				// Written before the hello is read, on purpose: the refusal
				// and the end of the stream have to be in flight while the
				// client is still on its way to the select.
				if _, err := conn.Write(line); err != nil {
					return
				}
				if tcp, ok := conn.(*net.TCPConn); ok {
					_ = tcp.CloseWrite()
				}
				// Drain whatever the client says so the deferred Close is not
				// what ends the client's hello write.
				_, _ = bufio.NewReader(conn).ReadString('\n')
			}(conn)
		}
	}()

	// Holds the connecting goroutine back until the refusal and the FIN have
	// both landed, so the select really does see two ready cases. Without it
	// the reject is almost always handed straight to an already-parked select
	// and the ordering under test is never reproduced -- measured 2026-09-08:
	// 40 attempts with the fix removed all passed.
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

// TestAMidSessionRejectReasonReachesTheLog is the regression test for E8 of the
// 2026-09-07 review (fixed 2026-09-08): a Reject that arrives AFTER the
// handshake was written into the buffered reject channel that nobody reads any
// more, so the send succeeded, the logging branch behind it was dead code, and
// a player thrown out mid-session (ReasonRateLimited, say) saw only
// "core: relay disconnected: EOF" with no reason and nothing to act on.
//
// Asserts the Code as well as the Reason: the reason is the sentence for a
// human, the code is the stable name anything reading the log can match on.
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
	// A joined session: playerID is what the handshake leaves behind, and it is
	// how a post-handshake Reject is told apart from one the connect is still
	// waiting on.
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

	// The channels the handshake would have owned: both empty and buffered,
	// exactly as they are once ConnectRelay has returned.
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

// TestTheEmittedClockDoesNotStepBackWhenTheRelayDrops is the regression test
// for E9 of the 2026-09-07 review (fixed 2026-09-08).
//
// forgetRelaySessionLocked cleared the clock offset and the monotonic clamp
// (lastNowMs) in the same breath, so in a clock.v1 room with a +5 s offset the
// emitted clock fell five seconds at the instant the relay dropped. nowMsLocked
// spells out why that must never happen: remoteBuffer.add requires
// non-decreasing timestamps and does not re-sort, and a rewound render time can
// flip an opaque field back to a previous value, manufacturing a state edge the
// core is forbidden to interpret. On screen it cost a despawn/respawn of the
// whole chaser pack -- recordLocal stamps five seconds in the past, no chaser
// is fed anything it considers new for five wall seconds, and every one of them
// crosses replayGapSeamMs.
//
// The offset itself must still be reset, or a new relay's clock is answered
// with the old one's, so both halves are asserted.
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

	// Sampled repeatedly rather than once: the clamp has to hold for as long as
	// real time takes to catch up, not just for the first call after the drop.
	deadline := time.Now().Add(50 * time.Millisecond)
	for time.Now().Before(deadline) {
		if got := c.nowMs(); got < before {
			t.Fatalf("nowMs fell from %d to %d across the relay drop (a +5 s room) -- every "+
				"outgoing timestamp is now in the past, every peer buffer goes unsorted, and the "+
				"chaser pack despawns and respawns on the player", before, got)
		}
	}
}
