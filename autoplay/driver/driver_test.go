package driver

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

// fakeDriver is the far end of the link, speaking the wire directly.
type fakeDriver struct {
	t  *testing.T
	nc net.Conn
	sc *bufio.Scanner
}

func dial(t *testing.T, h *Hub, hello any) *fakeDriver {
	t.Helper()
	nc, err := net.Dial("tcp", h.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { nc.Close() })
	d := &fakeDriver{t: t, nc: nc, sc: bufio.NewScanner(nc)}
	d.sc.Buffer(make([]byte, 0, 4096), MaxLineBytes*2)
	if hello != nil {
		d.send(map[string]any{"type": "hello", "payload": hello})
	}
	return d
}

func (d *fakeDriver) send(v any) {
	d.t.Helper()
	line, _ := json.Marshal(v)
	if _, err := d.nc.Write(append(line, '\n')); err != nil {
		d.t.Fatalf("driver write: %v", err)
	}
}

func (d *fakeDriver) read() envelope {
	d.t.Helper()
	d.nc.SetReadDeadline(time.Now().Add(5 * time.Second))
	if !d.sc.Scan() {
		d.t.Fatalf("driver read: %v", d.sc.Err())
	}
	var e envelope
	if err := json.Unmarshal(d.sc.Bytes(), &e); err != nil {
		d.t.Fatalf("driver read: %v in %q", err, d.sc.Text())
	}
	return e
}

func goodHello() Hello {
	return Hello{Protocol: Protocol, Host: "test", Game: "game", Capabilities: []string{"observe"}, ProtectedSlots: []int{1}}
}

func startHub(t *testing.T) *Hub {
	t.Helper()
	h, err := Listen("127.0.0.1:0", nil)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go h.Serve(ctx)
	return h
}

func waitConnected(t *testing.T, h *Hub, want bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := h.Current(); ok == want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("connected never became %v", want)
}

func TestListenRefusesANonLoopbackAddress(t *testing.T) {
	for _, addr := range []string{"0.0.0.0:0", "[::]:0", "localhost:0"} {
		if h, err := Listen(addr, nil); err == nil {
			h.Close()
			t.Errorf("Listen(%q) succeeded; the link must be loopback only", addr)
		}
	}
}

func TestHelloWelcomeAndCurrent(t *testing.T) {
	h := startHub(t)
	d := dial(t, h, goodHello())
	if e := d.read(); e.Type != "welcome" {
		t.Fatalf("got %q, want welcome", e.Type)
	}
	waitConnected(t, h, true)
	got, _ := h.Current()
	if got.Game != "game" || !got.Has("observe") || got.Has("exec") {
		t.Fatalf("Current() = %+v", got)
	}
}

func TestRejects(t *testing.T) {
	cases := map[string]any{
		"not a hello":  map[string]any{"type": "result"},
		"old protocol": Hello{Protocol: 0, Host: "h", Game: "g"},
		"no game":      Hello{Protocol: Protocol, Host: "h"},
	}
	for name, first := range cases {
		t.Run(name, func(t *testing.T) {
			h := startHub(t)
			d := dial(t, h, nil)
			if hello, ok := first.(Hello); ok {
				d.send(map[string]any{"type": "hello", "payload": hello})
			} else {
				d.send(first)
			}
			if e := d.read(); e.Type != "reject" {
				t.Fatalf("got %q, want reject", e.Type)
			}
			if _, ok := h.Current(); ok {
				t.Fatalf("a rejected driver became current")
			}
		})
	}
}

func TestASecondDriverIsRejectedAsBusy(t *testing.T) {
	h := startHub(t)
	first := dial(t, h, goodHello())
	first.read()
	waitConnected(t, h, true)

	second := dial(t, h, goodHello())
	e := second.read()
	if e.Type != "reject" || !strings.Contains(string(e.Payload), "busy") {
		t.Fatalf("second driver got %s %s, want a busy reject", e.Type, e.Payload)
	}
	if got, _ := h.Current(); got.Host != "test" {
		t.Fatalf("the first driver lost its place")
	}
}

func TestCallRoutesResultsAndErrorsByID(t *testing.T) {
	h := startHub(t)
	d := dial(t, h, goodHello())
	d.read()
	waitConnected(t, h, true)

	type out struct {
		raw json.RawMessage
		err error
	}
	a, b := make(chan out, 1), make(chan out, 1)
	go func() { r, err := h.Call(context.Background(), "observe", map[string]int{"n": 1}); a <- out{r, err} }()
	reqA := d.read()
	go func() { r, err := h.Call(context.Background(), "press", map[string]int{"n": 2}); b <- out{r, err} }()
	reqB := d.read()
	if reqA.ID == reqB.ID || reqA.Type != "observe" || reqB.Type != "press" {
		t.Fatalf("requests %+v %+v", reqA, reqB)
	}
	// Answer out of order: B errors first, then A succeeds.
	d.send(map[string]any{"id": reqB.ID, "type": "error", "payload": map[string]string{"message": "no such button"}})
	d.send(map[string]any{"id": reqA.ID, "type": "result", "payload": map[string]int{"x": 7}})

	gotB := <-b
	if gotB.err == nil || gotB.err.Error() != "no such button" {
		t.Fatalf("B = %v, want the driver's message", gotB.err)
	}
	gotA := <-a
	if gotA.err != nil || string(gotA.raw) != `{"x":7}` {
		t.Fatalf("A = %s %v", gotA.raw, gotA.err)
	}
}

func TestCallWithoutADriver(t *testing.T) {
	h := startHub(t)
	if _, err := h.Call(context.Background(), "observe", nil); !errors.Is(err, ErrNoDriver) {
		t.Fatalf("err = %v, want ErrNoDriver", err)
	}
}

func TestCallFailsWhenTheDriverLeaves(t *testing.T) {
	h := startHub(t)
	d := dial(t, h, goodHello())
	d.read()
	waitConnected(t, h, true)

	done := make(chan error, 1)
	go func() { _, err := h.Call(context.Background(), "observe", nil); done <- err }()
	d.read()
	d.nc.Close()
	select {
	case err := <-done:
		if !errors.Is(err, ErrDisconnected) {
			t.Fatalf("err = %v, want ErrDisconnected", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("Call never returned after the driver left")
	}
	waitConnected(t, h, false)

	// The slot is free again: a new driver is welcomed.
	again := dial(t, h, goodHello())
	if e := again.read(); e.Type != "welcome" {
		t.Fatalf("reconnect got %q, want welcome", e.Type)
	}
}

func TestCallHonoursContext(t *testing.T) {
	h := startHub(t)
	d := dial(t, h, goodHello())
	d.read()
	waitConnected(t, h, true)

	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	if _, err := h.Call(ctx, "observe", nil); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("err = %v, want DeadlineExceeded", err)
	}
}

func TestEventsAreNumberedAndBounded(t *testing.T) {
	h := startHub(t)
	d := dial(t, h, goodHello())
	d.read()
	waitConnected(t, h, true)

	total := EventBuffer + 10
	for i := 1; i <= total; i++ {
		d.send(map[string]any{"type": "event", "payload": map[string]any{"kind": "tick", "i": i}})
	}
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, newest := h.EventsSince(0); newest == uint64(total) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("events never all arrived")
		}
		time.Sleep(5 * time.Millisecond)
	}
	all, _ := h.EventsSince(0)
	if len(all) != EventBuffer || all[0].Seq != uint64(total-EventBuffer+1) {
		t.Fatalf("kept %d events starting at %d", len(all), all[0].Seq)
	}
	tail, _ := h.EventsSince(uint64(total - 3))
	if len(tail) != 3 || tail[2].Seq != uint64(total) {
		t.Fatalf("EventsSince tail = %d events", len(tail))
	}
}

func TestAnOverlongLineDropsTheDriver(t *testing.T) {
	h := startHub(t)
	d := dial(t, h, goodHello())
	d.read()
	waitConnected(t, h, true)
	d.send(map[string]any{"type": "event", "payload": strings.Repeat("x", MaxLineBytes)})
	waitConnected(t, h, false)
}

// Every accepted driver gets the next generation, so a reconnect is told apart from the same connection,
// and a hello's persisting cheats are kept.
func TestEachAcceptedDriverGetsTheNextGeneration(t *testing.T) {
	h := startHub(t)
	first := goodHello()
	first.Persisting = []string{"noclip"}
	d := dial(t, h, first)
	if e := d.read(); e.Type != "welcome" {
		t.Fatalf("got %q, want welcome", e.Type)
	}
	waitConnected(t, h, true)
	hello, gen1, ok := h.CurrentConnection()
	if !ok || gen1 == 0 || len(hello.Persisting) != 1 || hello.Persisting[0] != "noclip" {
		t.Fatalf("first connection = %+v gen %d ok %v", hello, gen1, ok)
	}
	d.nc.Close()
	waitConnected(t, h, false)
	if _, gen, ok := h.CurrentConnection(); ok || gen != 0 {
		t.Fatalf("no driver, yet gen %d ok %v", gen, ok)
	}

	d2 := dial(t, h, goodHello())
	if e := d2.read(); e.Type != "welcome" {
		t.Fatalf("got %q, want welcome", e.Type)
	}
	waitConnected(t, h, true)
	hello, gen2, _ := h.CurrentConnection()
	if gen2 <= gen1 || hello.Persisting != nil {
		t.Fatalf("second connection = %+v gen %d after %d", hello, gen2, gen1)
	}
}

// A Lua driver sends an empty list as {}: it reads as no kinds, and a hello carrying it is not refused.
func TestKindsReadAnEmptyObjectAsNoKinds(t *testing.T) {
	for in, want := range map[string]int{`["noclip","speed"]`: 2, `[]`: 0, `{}`: 0} {
		var k Kinds
		if err := json.Unmarshal([]byte(in), &k); err != nil || len(k) != want {
			t.Errorf("Kinds from %s = %v, %v; want %d kinds", in, k, err, want)
		}
	}
	var k Kinds
	if err := json.Unmarshal([]byte(`{"noclip":true}`), &k); err == nil {
		t.Errorf("an object with keys read as %v, want an error", k)
	}

	h := startHub(t)
	d := dial(t, h, nil)
	d.send(map[string]any{"type": "hello", "payload": json.RawMessage(`{"protocol":1,"host":"bizhawk","game":"g","capabilities":["observe"],"persisting":{}}`)})
	if e := d.read(); e.Type != "welcome" {
		t.Fatalf("a hello with persisting {} got %q, want welcome", e.Type)
	}
}
