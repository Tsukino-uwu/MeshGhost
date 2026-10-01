//go:build meshghost_devudp

package udpconn

import (
	"bytes"
	"encoding/binary"
	"net"
	"testing"
	"time"
)

// FuzzListenerSurvivesArbitraryDatagrams throws unstructured bytes at the demultiplexer, which any stranger who knows
// the address reaches before any validation. No input may panic the listener or leave it wedged: the liveness check
// after each case catches a listener that silently stops answering.
//
// The connection is admitted in setup, so later datagrams from this socket reach Conn.handleControl with the real
// token instead of bouncing off the lookup that gates every application frame. Seeds include truncated control
// headers, cookies of every wrong length, and a reliable frame with no room for its sequence number.
// fuzz-census: no-ci-step -- plain udp compiles only under meshghost_devudp and no release carries it (ADR 0065)
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
	// Token-carrying frames: short tokens, all-zero tokens and a reliable frame with no room for its sequence number
	// are the shapes most likely to walk off the end of a slice.
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

	// Unconnected, like every other raw sender in this package (see rawPeer).
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

	// Accept and drain it: without a reader the queue fills, deliver() drops, and the half of handleControl that
	// decides whether a reliable payload may be acked stops being exercised.
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

	// With the real token, seeds that get past the compare, to the sequence numbers, the reorder window and the acks.
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
		// Capped near the IPv4 maximum, not at MaxDatagramBytes, so oversized datagrams are fuzzed too.
		if len(data) > 60000 {
			data = data[:60000]
		}
		if _, err := raw.Write(data); err != nil {
			t.Skipf("write: %v", err)
		}

		// Liveness, by a raw hello/cookie exchange on the open socket: a full Dial per execution opens a socket each
		// time, which stalls the fuzzer, and its Close races the listener's admit.
		if _, err := raw.Write([]byte{ctrlPrefix, ctrlHello}); err != nil {
			t.Skipf("write hello: %v", err)
		}
		if err := raw.SetReadDeadline(time.Now().Add(2 * time.Second)); err != nil {
			t.Skipf("deadline: %v", err)
		}
		// Read in a loop: the admitted connection also receives acks on this socket, which are no answer to the hello.
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

// admitFuzzPeer completes a real handshake for raw and returns the token the listener issued, so the campaign runs
// against an admitted connection.
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
