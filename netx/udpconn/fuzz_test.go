package udpconn

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

// FuzzListenerSurvivesArbitraryDatagrams throws unstructured bytes at the
// demultiplexer, which is the new pre-auth attack surface this transport
// introduces: every byte here is processed BEFORE any address validation,
// room code, or protocol version check has happened, by a listener that any
// stranger who knows the address can reach.
//
// The properties under test are that no input can panic the listener, and —
// just as important — that no input can leave it wedged. The liveness check
// after each case is what catches the second: a crash is loud, but a
// listener that silently stops accepting anyone would look exactly like
// "nobody is joining."
//
// # THE CONNECTION IS ADMITTED BEFORE THE CAMPAIGN STARTS, AND THAT IS THE POINT
//
// Until 2026-09-12 this target only ever exchanged hello/cookie. `Listener.handle`
// routes ctrlData, ctrlLossy and ctrlAck through `l.lookup(key)` and drops them
// when no Conn exists for that address — and no Conn ever did, because nothing
// here completed a confirm. So `Conn.handleControl` was unreachable for the whole
// campaign: the constant-time token compare, the seqLen bound on a reliable
// frame, the reorder window, the ack path, every one of it never executed once.
// Nine of the seeds below were written for exactly that code and had been
// bouncing off the `lookup` nil check since the day they were added.
//
// That is the 2026-09-02 shape a second time — a fuzz target that truncated its
// own inputs to MaxDatagramBytes and therefore could never find the oversized
// datagram that closed the listener — and finding it twice is why the fuzz
// census gate exists. **A target's seeds are a statement about what it reaches;
// check the statement.** Found by the coverage cell of the third adversarial
// review (X2-1).
//
// Completing the handshake once, in setup, costs one round trip for the whole
// campaign and puts every later datagram from this socket onto the admitted
// connection. The token is then known, so seeds can carry the real one and get
// PAST the compare rather than only testing that a wrong token is refused.
//
// Seeded with the shapes most likely to break the parsing: truncated control
// headers, a control byte with no type, cookies of every wrong length, and a
// datagram claiming to be reliable with no room for its sequence number.
func FuzzListenerSurvivesArbitraryDatagrams(f *testing.F) {
	f.Add([]byte{})
	f.Add([]byte{ctrlPrefix})
	f.Add([]byte{ctrlPrefix, ctrlHello})
	f.Add([]byte{ctrlPrefix, ctrlCookie})
	f.Add([]byte{ctrlPrefix, ctrlConfirm})
	f.Add(append([]byte{ctrlPrefix, ctrlConfirm}, make([]byte, cookieLen-1)...))
	f.Add(append([]byte{ctrlPrefix, ctrlConfirm}, make([]byte, cookieLen)...))
	f.Add(append([]byte{ctrlPrefix, ctrlConfirm}, make([]byte, cookieLen+64)...))
	f.Add([]byte{ctrlPrefix, ctrlData})
	f.Add([]byte{ctrlPrefix, ctrlData, 0, 0, 0})
	f.Add(append([]byte{ctrlPrefix, ctrlData}, make([]byte, seqLen)...))
	f.Add([]byte{ctrlPrefix, ctrlAck, 1})
	f.Add([]byte{ctrlPrefix, 0xEE})
	// Token-carrying frames, added when the per-connection token became
	// mandatory: short tokens, all-zero tokens, and a reliable frame with
	// no room for its sequence number are the shapes most likely to walk
	// off the end of a slice.
	f.Add([]byte{ctrlPrefix, ctrlReady})
	f.Add(append([]byte{ctrlPrefix, ctrlReady}, make([]byte, tokenLen)...))
	f.Add([]byte{ctrlPrefix, ctrlLossy})
	f.Add(append([]byte{ctrlPrefix, ctrlLossy}, make([]byte, tokenLen-1)...))
	f.Add(append([]byte{ctrlPrefix, ctrlLossy}, make([]byte, tokenLen)...))
	f.Add(append(append([]byte{ctrlPrefix, ctrlLossy}, make([]byte, tokenLen)...), []byte("{\"a\":1}\n")...))
	f.Add(append([]byte{ctrlPrefix, ctrlData}, make([]byte, tokenLen)...))
	f.Add(append([]byte{ctrlPrefix, ctrlData}, make([]byte, tokenLen+seqLen)...))
	f.Add(append([]byte{ctrlPrefix, ctrlAck}, make([]byte, tokenLen+seqLen)...))
	f.Add([]byte(`{"type":"hello"}` + "\n"))
	f.Add([]byte("not json at all\n"))
	f.Add(make([]byte, MaxDatagramBytes))

	l, err := Listen("127.0.0.1:0")
	if err != nil {
		f.Fatalf("listen: %v", err)
	}
	f.Cleanup(func() { l.Close() })

	// Unconnected, like every other raw sender in this package -- see rawPeer.
	// f, not t: this is the corpus-wide setup, so it takes the fuzz target's own
	// fatal.
	ua, err := net.ResolveUDPAddr("udp", l.Addr().String())
	if err != nil {
		f.Fatalf("resolve: %v", err)
	}
	pc, err := net.ListenUDP("udp", nil)
	if err != nil {
		f.Fatalf("raw listen: %v", err)
	}
	f.Cleanup(func() { pc.Close() })
	raw := &rawPeer{pc: pc, to: ua}

	token := admitFuzzPeer(f, l, raw)

	// Accept it and drain it. Not decoration: without a reader the 64-deep
	// queue fills and deliver() starts dropping, so the delivery half of
	// handleControl -- the part that decides whether a reliable payload may be
	// ACKED -- would stop being exercised partway through the campaign.
	conn, err := l.Accept()
	if err != nil {
		f.Fatalf("accept the admitted connection: %v", err)
	}
	f.Cleanup(func() { conn.Close() })
	delivered := make(chan []byte, 64)
	go func() {
		buf := make([]byte, readBufferBytes)
		for {
			n, err := conn.Read(buf)
			if err != nil {
				return
			}
			select {
			case delivered <- append([]byte(nil), buf[:n]...):
			default:
			}
		}
	}()

	// Now that the token is real, seed the frames that get PAST the compare.
	// Everything above tests refusal; these test what happens after admission,
	// which is where the sequence numbers, the reorder window and the ack path
	// live.
	lossy := func(payload string) []byte {
		b := append([]byte{ctrlPrefix, ctrlLossy}, token...)
		return append(b, payload...)
	}
	reliable := func(seq uint64, payload string) []byte {
		b := append([]byte{ctrlPrefix, ctrlData}, token...)
		var sb [seqLen]byte
		binary.BigEndian.PutUint64(sb[:], seq)
		b = append(b, sb[:]...)
		return append(b, payload...)
	}
	f.Add(lossy(""))
	f.Add(lossy("{\"type\":\"state\"}\n"))
	f.Add(reliable(1, "{\"type\":\"hello\"}\n"))
	f.Add(reliable(1, ""))
	// Out of order, which is what the reorder window exists for, and far ahead
	// of it, which is what bounds it.
	f.Add(reliable(2, "{\"type\":\"leave\"}\n"))
	f.Add(reliable(^uint64(0), "{\"type\":\"state\"}\n"))
	f.Add(reliable(0, "{\"type\":\"state\"}\n"))
	f.Add(append([]byte{ctrlPrefix, ctrlAck}, append(token, make([]byte, seqLen)...)...))
	f.Add(append([]byte{ctrlPrefix, ctrlData}, append(token, make([]byte, seqLen-1)...)...))

	f.Fuzz(func(t *testing.T, data []byte) {
		// Capped near the IPv4 maximum, NOT at MaxDatagramBytes: until
		// 2026-09-02 this truncated to MaxDatagramBytes, which is exactly why
		// the fuzzer never found that one oversized datagram closed the
		// listener on Windows (see readBufferBytes and oversized_test.go).
		if len(data) > 60000 {
			data = data[:60000]
		}
		if _, err := raw.Write(data); err != nil {
			t.Skipf("write: %v", err)
		}

		// Liveness, checked with a raw hello/cookie exchange on the
		// already-open socket rather than a full Dial.
		//
		// A full Dial per execution was the obvious version and was wrong
		// twice over: it opened a fresh UDP socket every time (which
		// stalled the fuzzer outright — execs froze after a few seconds),
		// and its Close raced the listener's admit, leaving a stale entry
		// in the conns map on every iteration. This checks the same
		// property — the listener still answers a well-formed request
		// after whatever it was just sent — at a cost that lets the
		// fuzzer actually explore.
		if _, err := raw.Write([]byte{ctrlPrefix, ctrlHello}); err != nil {
			t.Skipf("write hello: %v", err)
		}
		if err := raw.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Skipf("deadline: %v", err)
		}
		// Reading in a LOOP, not once: now that a connection is admitted, the
		// listener also sends acks to this socket, and an ack arriving between
		// the write and the read would be mistaken for a malformed answer.
		buf := make([]byte, 128)
		for {
			n, err := raw.Read(buf)
			if err != nil {
				t.Fatalf("listener stopped answering a valid hello after receiving %q: %v", data, err)
			}
			if n >= 2 && buf[0] == ctrlPrefix && buf[1] == ctrlAck {
				continue
			}
			if n < 2+cookieLen || buf[0] != ctrlPrefix || buf[1] != ctrlCookie {
				t.Fatalf("listener answered a valid hello with % x after receiving %q", buf[:n], data)
			}
			return
		}
	})
}

// admitFuzzPeer completes a real handshake for raw and returns the token the
// listener issued, so the campaign runs against an ADMITTED connection rather
// than bouncing off the lookup that gates every application frame. See the
// target's own comment for what that was costing.
func admitFuzzPeer(f *testing.F, l *Listener, raw *rawPeer) []byte {
	f.Helper()

	if err := raw.SetReadDeadline(time.Now().Add(5 * time.Second)); err != nil {
		f.Fatalf("deadline: %v", err)
	}
	if _, err := raw.Write([]byte{ctrlPrefix, ctrlHello}); err != nil {
		f.Fatalf("hello: %v", err)
	}
	buf := make([]byte, 128)
	n, err := raw.Read(buf)
	if err != nil {
		f.Fatalf("reading the cookie: %v", err)
	}
	if n != 2+cookieLen || !bytes.Equal(buf[:2], []byte{ctrlPrefix, ctrlCookie}) {
		f.Fatalf("expected a cookie, got % x", buf[:n])
	}
	confirm := append([]byte{ctrlPrefix, ctrlConfirm}, buf[2:n]...)
	if _, err := raw.Write(confirm); err != nil {
		f.Fatalf("confirm: %v", err)
	}
	n, err = raw.Read(buf)
	if err != nil {
		f.Fatalf("reading the ready: %v", err)
	}
	if n != 2+tokenLen || !bytes.Equal(buf[:2], []byte{ctrlPrefix, ctrlReady}) {
		f.Fatalf("expected a ready with a token, got % x", buf[:n])
	}
	return append([]byte(nil), buf[2:n]...)
}
