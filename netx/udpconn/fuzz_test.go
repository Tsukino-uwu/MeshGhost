package udpconn

import (
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
// Seeded with the shapes most likely to break the parsing: truncated
// control headers, a control byte with no type, cookies of every wrong
// length, and a datagram claiming to be reliable with no room for its
// sequence number.
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

	raw, err := net.Dial("udp", l.Addr().String())
	if err != nil {
		f.Fatalf("dial: %v", err)
	}
	f.Cleanup(func() { raw.Close() })

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
		buf := make([]byte, 128)
		n, err := raw.Read(buf)
		if err != nil {
			t.Fatalf("listener stopped answering a valid hello after receiving %q: %v", data, err)
		}
		if n < 2+cookieLen || buf[0] != ctrlPrefix || buf[1] != ctrlCookie {
			t.Fatalf("listener answered a valid hello with % x after receiving %q", buf[:n], data)
		}
	})
}
