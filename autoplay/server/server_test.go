package server

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/runlog"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// harness wires a hub on loopback to the MCP server, and an in-memory MCP client to that.
type harness struct {
	hub     *driver.Hub
	session *mcp.ClientSession
	log     *runlog.Log
	states  string
}

func newHarness(t *testing.T, options ...func(*Options)) *harness {
	t.Helper()
	hub, err := driver.Listen("127.0.0.1:0", nil)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go hub.Serve(ctx)

	runs, err := runlog.Open(t.TempDir())
	if err != nil {
		t.Fatalf("run log: %v", err)
	}
	t.Cleanup(func() { runs.Close() })
	states := t.TempDir()

	opts := Options{Log: runs, StatesDir: states}
	for _, o := range options {
		o(&opts)
	}
	serverT, clientT := mcp.NewInMemoryTransports()
	if _, err := New(hub, "test", opts).Connect(ctx, serverT, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "test"}, nil)
	session, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { session.Close() })
	return &harness{hub: hub, session: session, log: runs, states: states}
}

// call invokes a tool and returns its text content and whether it was an error.
func (h *harness) call(t *testing.T, name string, args any) (string, bool) {
	t.Helper()
	res, err := h.session.CallTool(context.Background(), &mcp.CallToolParams{Name: name, Arguments: args})
	if err != nil {
		t.Fatalf("CallTool(%s): %v", name, err)
	}
	var text strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			text.WriteString(tc.Text)
		}
	}
	return text.String(), res.IsError
}

// answerFunc decides a scripted driver's reply to one request: a type ("result" or "error") and
// a payload.
type answerFunc func(verb string, payload json.RawMessage) (string, any)

// startDriver connects a scripted driver with the given capabilities, and returns its connection so
// a test can also send unsolicited lines (events).
func (h *harness) startDriver(t *testing.T, capabilities []string, answer answerFunc) net.Conn {
	t.Helper()
	return h.startDriverWithHello(t, driver.Hello{Protocol: driver.Protocol, Host: "fakehost", Game: "fakegame", Capabilities: capabilities}, answer)
}

// startDriverWithHello is startDriver with the whole hello given.
func (h *harness) startDriverWithHello(t *testing.T, hello driver.Hello, answer answerFunc) net.Conn {
	t.Helper()
	nc, err := net.Dial("tcp", h.hub.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { nc.Close() })

	writeLine(t, nc, map[string]any{"type": "hello", "payload": hello})

	sc := bufio.NewScanner(nc)
	sc.Buffer(make([]byte, 0, 4096), driver.MaxLineBytes)
	if !sc.Scan() || !strings.Contains(sc.Text(), `"welcome"`) {
		t.Fatalf("no welcome: %q %v", sc.Text(), sc.Err())
	}
	go func() {
		for sc.Scan() {
			var req struct {
				ID      uint64          `json:"id"`
				Type    string          `json:"type"`
				Payload json.RawMessage `json:"payload"`
			}
			if json.Unmarshal(sc.Bytes(), &req) != nil {
				return
			}
			kind, body := answer(req.Type, req.Payload)
			line, _ := json.Marshal(map[string]any{"id": req.ID, "type": kind, "payload": body})
			if _, err := nc.Write(append(line, '\n')); err != nil {
				return
			}
		}
	}()

	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := h.hub.Current(); ok {
			return nc
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the scripted driver never became current")
	return nil
}

func writeLine(t *testing.T, nc net.Conn, v any) {
	t.Helper()
	line, _ := json.Marshal(v)
	if _, err := nc.Write(append(line, '\n')); err != nil {
		t.Fatalf("write: %v", err)
	}
}

func TestStatusWithoutADriver(t *testing.T) {
	h := newHarness(t)
	text, isErr := h.call(t, "status", map[string]any{})
	if isErr || !strings.Contains(text, `"connected":false`) {
		t.Fatalf("status = %s (error %v)", text, isErr)
	}
}

func TestStatusReportsTheDriver(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"observe"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	text, isErr := h.call(t, "status", map[string]any{})
	if isErr || !strings.Contains(text, `"connected":true`) || !strings.Contains(text, `"fakegame"`) {
		t.Fatalf("status = %s (error %v)", text, isErr)
	}
}

func TestObserveIsForwardedUnread(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"observe"}, func(verb string, _ json.RawMessage) (string, any) {
		if verb != "observe" {
			return "error", map[string]string{"message": "unexpected " + verb}
		}
		return "result", map[string]any{"map": "opaque-name", "x": 12, "y": 8}
	})
	text, isErr := h.call(t, "observe", map[string]any{})
	if isErr || !strings.Contains(text, `"opaque-name"`) || !strings.Contains(text, `"x":12`) {
		t.Fatalf("observe = %s (error %v)", text, isErr)
	}
}

func TestADriverErrorBecomesAToolError(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"observe"}, func(string, json.RawMessage) (string, any) {
		return "error", map[string]string{"message": "not in the overworld"}
	})
	text, isErr := h.call(t, "observe", map[string]any{})
	if !isErr || !strings.Contains(text, "not in the overworld") {
		t.Fatalf("observe = %s (error %v), want the driver's message as a tool error", text, isErr)
	}
}

func TestPressIsRefusedWithoutTheCapability(t *testing.T) {
	h := newHarness(t)
	called := make(chan string, 4)
	h.startDriver(t, []string{"observe"}, func(verb string, _ json.RawMessage) (string, any) {
		called <- verb
		return "result", map[string]any{}
	})
	text, isErr := h.call(t, "press", map[string]any{"buttons": []string{"A"}, "frames": 4})
	if !isErr || !strings.Contains(text, `does not support "press"`) {
		t.Fatalf("press = %s (error %v)", text, isErr)
	}
	select {
	case verb := <-called:
		t.Fatalf("the driver was asked to %s anyway", verb)
	default:
	}
}

func TestPressValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan PressIn, 1)
	h.startDriver(t, []string{"press"}, func(verb string, payload json.RawMessage) (string, any) {
		var in PressIn
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"frames_held": in.Frames}
	})

	for _, bad := range []map[string]any{
		{"buttons": []string{}, "frames": 4},
		{"buttons": []string{"A"}, "frames": 0},
		{"buttons": []string{"A"}, "frames": MaxPressFrames + 1},
	} {
		if text, isErr := h.call(t, "press", bad); !isErr {
			t.Errorf("press %v = %s, want a refusal", bad, text)
		}
	}

	text, isErr := h.call(t, "press", map[string]any{"buttons": []string{"Up", "B"}, "frames": 16})
	if isErr || !strings.Contains(text, `"frames_held":16`) {
		t.Fatalf("press = %s (error %v)", text, isErr)
	}
	in := <-got
	if in.Frames != 16 || len(in.Buttons) != 2 || in.Buttons[0] != "Up" {
		t.Fatalf("the driver received %+v", in)
	}
}

func TestSequenceValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan SequenceIn, 1)
	h.startDriver(t, []string{"sequence"}, func(verb string, payload json.RawMessage) (string, any) {
		var in SequenceIn
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"frames_run": 90}
	})

	step := func(from, frames int, buttons ...string) map[string]any {
		return map[string]any{"buttons": buttons, "from": from, "frames": frames}
	}
	tooMany := make([]map[string]any, MaxSequenceSteps+1)
	for i := range tooMany {
		tooMany[i] = step(i, 1, "A")
	}
	for _, bad := range []map[string]any{
		{"steps": []map[string]any{}},
		{"steps": tooMany},
		{"steps": []map[string]any{step(0, 4)}},
		{"steps": []map[string]any{step(0, 0, "A")}},
		{"steps": []map[string]any{step(0, MaxPressFrames+1, "A")}},
		{"steps": []map[string]any{step(-1, 4, "A")}},
		{"steps": []map[string]any{step(MaxSequenceFrames-3, 4, "A")}},
		{"steps": []map[string]any{step(0, 4, "A")}, "stop_on": []string{""}},
	} {
		if text, isErr := h.call(t, "sequence", bad); !isErr {
			t.Errorf("sequence %v = %s, want a refusal", bad, text)
		}
	}

	text, isErr := h.call(t, "sequence", map[string]any{
		"steps":   []map[string]any{step(0, 90, "XAxis+"), step(30, 14, "Jump")},
		"stop_on": []string{"damage_taken"},
	})
	if isErr || !strings.Contains(text, `"frames_run":90`) {
		t.Fatalf("sequence = %s (error %v)", text, isErr)
	}
	in := <-got
	if len(in.Steps) != 2 || in.Steps[1].From != 30 || in.Steps[1].Buttons[0] != "Jump" || len(in.StopOn) != 1 || in.StopOn[0] != "damage_taken" {
		t.Fatalf("the driver received %+v", in)
	}
}

func TestClockValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan ClockIn, 4)
	h.startDriver(t, []string{"clock"}, func(verb string, payload json.RawMessage) (string, any) {
		var in ClockIn
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"verb": verb, "held": in.Action != "release"}
	})
	for _, bad := range []map[string]any{
		{"action": "pause"},
		{"action": "step"},
		{"action": "step", "frames": MaxPressFrames + 1},
		{"action": "hold", "frames": 3},
	} {
		if text, isErr := h.call(t, "clock", bad); !isErr {
			t.Errorf("clock %v = %s, want a refusal", bad, text)
		}
	}
	text, isErr := h.call(t, "clock", map[string]any{"action": "step", "frames": 4})
	if isErr || !strings.Contains(text, `"verb":"clock"`) || !strings.Contains(text, `"held":true`) {
		t.Fatalf("clock step = %s (error %v)", text, isErr)
	}
	if in := <-got; in.Action != "step" || in.Frames != 4 {
		t.Fatalf("the driver received %+v", in)
	}
}

func TestRecentValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan RecentIn, 4)
	h.startDriver(t, []string{"recent"}, func(verb string, payload json.RawMessage) (string, any) {
		var in RecentIn
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"verb": verb, "rows": []any{}}
	})
	for _, bad := range []map[string]any{
		{"frames": -1},
		{"frames": MaxRecentFrames + 1},
		{"every": MaxRecentEvery + 1},
		{"every": -2},
		{"until_frame": -5},
	} {
		if text, isErr := h.call(t, "recent", bad); !isErr {
			t.Errorf("recent %v = %s, want a refusal", bad, text)
		}
	}
	text, isErr := h.call(t, "recent", map[string]any{})
	if isErr || !strings.Contains(text, `"verb":"recent"`) {
		t.Fatalf("recent = %s (error %v)", text, isErr)
	}
	if in := <-got; in.Frames != 120 || in.Every != 1 || in.UntilFrame != nil {
		t.Fatalf("the defaults reached the driver as %+v", in)
	}
	text, isErr = h.call(t, "recent", map[string]any{"frames": 600, "every": 3, "until_frame": 0})
	if isErr {
		t.Fatalf("recent at the bounds = %s", text)
	}
	if in := <-got; in.Frames != 600 || in.Every != 3 || in.UntilFrame == nil || *in.UntilFrame != 0 {
		t.Fatalf("the driver received %+v", in)
	}
	if len(got) != 0 {
		t.Fatalf("a refused call reached the driver")
	}
}

func TestReflexValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan ReflexIn, 1)
	h.startDriver(t, []string{"reflex:fight"}, func(verb string, payload json.RawMessage) (string, any) {
		var in ReflexIn
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"verb": verb, "outcome": "defeated"}
	})

	for _, bad := range []map[string]any{
		{"kind": "Fight"},
		{"kind": "fight", "frames": -1},
		{"kind": "fight", "frames": MaxReflexFrames + 1},
	} {
		if text, isErr := h.call(t, "reflex", bad); !isErr {
			t.Errorf("reflex %v = %s, want a refusal", bad, text)
		}
	}
	if text, isErr := h.call(t, "reflex", map[string]any{"kind": "dodge"}); !isErr || !strings.Contains(text, "reflex:dodge") {
		t.Errorf("reflex dodge = %s (error %v), want refused as not announced", text, isErr)
	}

	text, isErr := h.call(t, "reflex", map[string]any{"kind": "fight", "args": map[string]any{"id": 1}})
	if isErr || !strings.Contains(text, `"verb":"reflex"`) || !strings.Contains(text, `"defeated"`) {
		t.Fatalf("reflex = %s (error %v)", text, isErr)
	}
	in := <-got
	if in.Kind != "fight" || in.Frames != 600 || in.Args["id"] != float64(1) {
		t.Fatalf("the driver received %+v", in)
	}
	if seg, _ := h.call(t, "segment", map[string]any{"label": "after the reflex"}); !strings.Contains(seg, `"claim":"walked"`) {
		t.Fatalf("segment after a reflex = %s, want the closed one walked", seg)
	}
}

func TestSelectValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan map[string]any, 2)
	h.startDriver(t, []string{"select"}, func(verb string, payload json.RawMessage) (string, any) {
		var in map[string]any
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"selected": "NO"}
	})

	for _, bad := range []map[string]any{
		{},
		{"item": "YES", "index": 0},
		{"index": -1},
		{"index": 256},
		{"item": strings.Repeat("x", 65)},
	} {
		if text, isErr := h.call(t, "select", bad); !isErr {
			t.Errorf("select %v = %s, want a refusal", bad, text)
		}
	}

	text, isErr := h.call(t, "select", map[string]any{"item": "NO"})
	if isErr || !strings.Contains(text, `"selected":"NO"`) {
		t.Fatalf("select item = %s (error %v)", text, isErr)
	}
	if in := <-got; in["item"] != "NO" || in["confirm"] != true || in["index"] != nil {
		t.Fatalf("the driver received %v, want item NO with confirm true and no index", in)
	}

	// Index 0 must reach the driver: it is a real position, not an absent one.
	if text, isErr := h.call(t, "select", map[string]any{"index": 0, "confirm": false}); isErr {
		t.Fatalf("select index 0 = %s", text)
	}
	if in := <-got; in["index"] != float64(0) || in["confirm"] != false || in["item"] != nil {
		t.Fatalf("the driver received %v, want index 0 with confirm false and no item", in)
	}
}

func TestWalkValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan WalkIn, 1)
	h.startDriver(t, []string{"walk"}, func(verb string, payload json.RawMessage) (string, any) {
		var in WalkIn
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"moved": in.Tiles, "outcome": "done"}
	})

	for _, bad := range []map[string]any{
		{"direction": "north", "tiles": 1},
		{"direction": "Up", "tiles": 1},
		{"direction": "up", "tiles": 0},
		{"direction": "up", "tiles": MaxWalkTiles + 1},
	} {
		if text, isErr := h.call(t, "walk", bad); !isErr {
			t.Errorf("walk %v = %s, want a refusal", bad, text)
		}
	}

	text, isErr := h.call(t, "walk", map[string]any{"direction": "left", "tiles": 3})
	if isErr || !strings.Contains(text, `"outcome":"done"`) {
		t.Fatalf("walk = %s (error %v)", text, isErr)
	}
	if in := <-got; in.Direction != "left" || in.Tiles != 3 || in.Run {
		t.Fatalf("the driver received %+v", in)
	}

	// run reaches the driver; without it the field is left out, so a driver that predates it walks.
	if text, isErr := h.call(t, "walk", map[string]any{"direction": "up", "tiles": 2, "run": true}); isErr {
		t.Fatalf("walk with run = %s", text)
	}
	if in := <-got; !in.Run || in.Direction != "up" || in.Tiles != 2 {
		t.Fatalf("the driver received %+v, want run", in)
	}
}

func TestTypeTextValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan map[string]any, 1)
	h.startDriver(t, []string{"type_text"}, func(verb string, payload json.RawMessage) (string, any) {
		var in map[string]any
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"typed": in["text"], "confirmed": in["confirm"]}
	})

	for _, bad := range []map[string]any{
		{"text": ""},
		{"text": strings.Repeat("A", MaxTypeTextBytes+1)},
	} {
		if text, isErr := h.call(t, "type_text", bad); !isErr {
			t.Errorf("type_text %v = %s, want a refusal", bad, text)
		}
	}

	// confirm is spelled out to the driver: true when left out, false when said.
	if text, isErr := h.call(t, "type_text", map[string]any{"text": "MAY"}); isErr || !strings.Contains(text, `"typed":"MAY"`) {
		t.Fatalf("type_text = %s (error %v)", text, isErr)
	}
	if in := <-got; in["text"] != "MAY" || in["confirm"] != true {
		t.Fatalf("the driver received %v, want confirm true", in)
	}
	if text, isErr := h.call(t, "type_text", map[string]any{"text": "A", "confirm": false}); isErr {
		t.Fatalf("type_text confirm false = %s", text)
	}
	if in := <-got; in["confirm"] != false {
		t.Fatalf("the driver received %v, want confirm false", in)
	}
}

func TestTypeTextIsRefusedWithoutTheCapability(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"observe"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	if text, isErr := h.call(t, "type_text", map[string]any{"text": "A"}); !isErr || !strings.Contains(text, "type_text") {
		t.Fatalf("type_text without the capability = %s (error %v)", text, isErr)
	}
}

func TestSetClockValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan map[string]any, 1)
	h.startDriver(t, []string{"set_clock"}, func(verb string, payload json.RawMessage) (string, any) {
		var in map[string]any
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"outcome": "confirmed", "set": map[string]any{"hours": in["hours"], "minutes": in["minutes"]}}
	})

	for _, bad := range []map[string]any{
		{"minutes": 0},
		{"hours": 0},
		{"hours": -1, "minutes": 0},
		{"hours": 24, "minutes": 0},
		{"hours": 0, "minutes": -1},
		{"hours": 0, "minutes": 60},
	} {
		if text, isErr := h.call(t, "set_clock", bad); !isErr {
			t.Errorf("set_clock %v = %s, want a refusal", bad, text)
		}
	}

	// Midnight is a time, and confirm is spelled out to the driver: true when left out, false when said.
	if text, isErr := h.call(t, "set_clock", map[string]any{"hours": 0, "minutes": 0}); isErr || !strings.Contains(text, `"confirmed"`) {
		t.Fatalf("set_clock 0:00 = %s (error %v)", text, isErr)
	}
	if in := <-got; in["hours"] != float64(0) || in["minutes"] != float64(0) || in["confirm"] != true {
		t.Fatalf("the driver received %v, want 0:00 and confirm true", in)
	}
	if text, isErr := h.call(t, "set_clock", map[string]any{"hours": 23, "minutes": 59, "confirm": false}); isErr {
		t.Fatalf("set_clock confirm false = %s", text)
	}
	if in := <-got; in["hours"] != float64(23) || in["minutes"] != float64(59) || in["confirm"] != false {
		t.Fatalf("the driver received %v, want 23:59 and confirm false", in)
	}
}

func TestSetClockIsRefusedWithoutTheCapability(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"observe"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	if text, isErr := h.call(t, "set_clock", map[string]any{"hours": 10, "minutes": 0}); !isErr || !strings.Contains(text, "set_clock") {
		t.Fatalf("set_clock without the capability = %s (error %v)", text, isErr)
	}
}

func TestExecIsOffWithoutATokenAndForwardsItWithOne(t *testing.T) {
	off := newHarness(t)
	off.startDriver(t, []string{"exec"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	if text, isErr := off.call(t, "exec", map[string]any{"code": "return 1"}); !isErr || !strings.Contains(text, "exec is off") {
		t.Fatalf("exec with no token = %s (error %v)", text, isErr)
	}

	h := newHarness(t, func(o *Options) { o.ExecToken = "session-token" })
	got := make(chan execRequest, 1)
	h.startDriver(t, []string{"exec"}, func(verb string, payload json.RawMessage) (string, any) {
		var in execRequest
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"results": []any{2}}
	})
	for _, bad := range []map[string]any{{"code": ""}, {"code": strings.Repeat("x", MaxExecBytes+1)}} {
		if text, isErr := h.call(t, "exec", bad); !isErr {
			t.Errorf("exec %v = %s, want a refusal", bad, text)
		}
	}
	if text, isErr := h.call(t, "segment", map[string]any{"label": "exec"}); isErr {
		t.Fatalf("segment = %s", text)
	}
	if text, isErr := h.call(t, "exec", map[string]any{"code": "return 1 + 1"}); isErr || !strings.Contains(text, `"results":[2]`) {
		t.Fatalf("exec = %s (error %v)", text, isErr)
	}
	if in := <-got; in.Code != "return 1 + 1" || in.Token != "session-token" {
		t.Fatalf("the driver received %+v", in)
	}
	// Code that may have changed the game reaches the segment it ran in.
	text, _ := h.call(t, "segment", map[string]any{"label": "after"})
	var out SegmentOut
	if json.Unmarshal([]byte(text), &out) != nil || out.Closed.Claim != "reached" || len(out.Closed.Because) != 1 || out.Closed.Because[0] != "exec" {
		t.Fatalf("after exec, segment = %s", text)
	}
}

func TestExecIsRefusedWithoutTheCapability(t *testing.T) {
	h := newHarness(t, func(o *Options) { o.ExecToken = "session-token" })
	h.startDriver(t, []string{"observe"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	if text, isErr := h.call(t, "exec", map[string]any{"code": "return 1"}); !isErr || !strings.Contains(text, `"exec"`) {
		t.Fatalf("exec without the capability = %s (error %v)", text, isErr)
	}
}

func TestWriteExecTokenWritesAFreshTokenEachTime(t *testing.T) {
	path := filepath.Join(t.TempDir(), "runs", "exec_token_7870.txt")
	a, err := WriteExecToken(path)
	if err != nil {
		t.Fatal(err)
	}
	b, err := WriteExecToken(path)
	if err != nil {
		t.Fatal(err)
	}
	onDisk, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if len(a) != 32 || a == b || string(onDisk) != b {
		t.Fatalf("tokens %q then %q, file holds %q", a, b, onDisk)
	}
}

// A cheat the driver says is still in effect (a noclip left on) reaches every segment begun while it is,
// until an answer says it is off.
func TestACheatStillInEffectReachesTheSegmentsBegunWhileItIs(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"cheat:noclip", "cheat:warp"}, func(verb string, payload json.RawMessage) (string, any) {
		var in CheatIn
		json.Unmarshal(payload, &in)
		if in.Kind == "noclip" && in.Args["on"] != false {
			return "result", map[string]any{"persisting": []string{"noclip"}}
		}
		if in.Kind == "noclip" {
			return "result", map[string]any{"persisting": []string{}}
		}
		// An answer without the field leaves what is known as it was.
		return "result", map[string]any{"done": true}
	})
	segment := func(label string) SegmentOut {
		t.Helper()
		text, isErr := h.call(t, "segment", map[string]any{"label": label})
		var out SegmentOut
		if isErr || json.Unmarshal([]byte(text), &out) != nil {
			t.Fatalf("segment = %s (error %v)", text, isErr)
		}
		return out
	}

	if text, isErr := h.call(t, "cheat", map[string]any{"kind": "noclip", "args": map[string]any{"on": true}}); isErr {
		t.Fatalf("noclip on = %s", text)
	}
	if cur := segment("through the wall").Current; cur.Claim != "reached" || len(cur.Because) != 1 || cur.Because[0] != "cheat:noclip (still on)" {
		t.Fatalf("a segment begun with noclip on = %+v", cur)
	}
	h.call(t, "cheat", map[string]any{"kind": "warp", "args": map[string]any{}})
	if cur := segment("still through walls").Current; cur.Claim != "reached" {
		t.Fatalf("an answer with no persisting field turned it off: %+v", cur)
	}
	h.call(t, "cheat", map[string]any{"kind": "noclip", "args": map[string]any{"on": false}})
	if cur := segment("on foot").Current; cur.Claim != "walked" || cur.Because != nil {
		t.Fatalf("a segment begun with noclip off = %+v", cur)
	}
}

// A driver that connects with a cheat already in effect (a core restarted by mcpcall while the driver's
// noclip stayed on) says so in its hello.
func TestAHelloWithACheatInEffectReachesNewSegments(t *testing.T) {
	h := newHarness(t)
	h.startDriverWithHello(t, driver.Hello{Protocol: driver.Protocol, Host: "fakehost", Game: "fakegame",
		Capabilities: []string{"observe"}, Persisting: []string{"noclip"}},
		func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	// The segment the core opened before the driver connected is reached by the first call made with noclip on.
	h.call(t, "observe", nil)
	text, isErr := h.call(t, "segment", map[string]any{"label": "after the restart"})
	var out SegmentOut
	if isErr || json.Unmarshal([]byte(text), &out) != nil {
		t.Fatalf("segment = %s (error %v)", text, isErr)
	}
	if c := out.Closed; c.Label != "start" || c.Claim != "reached" || len(c.Because) != 1 || c.Because[0] != "cheat:noclip (still on)" {
		t.Fatalf("the segment begun before the hello = %+v", c)
	}
	if out.Current.Claim != "reached" || len(out.Current.Because) != 1 {
		t.Fatalf("the segment begun after it = %+v", out.Current)
	}
}

func TestGotoValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan GotoIn, 1)
	h.startDriver(t, []string{"goto"}, func(verb string, payload json.RawMessage) (string, any) {
		var in GotoIn
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"outcome": "done"}
	})

	for _, bad := range []map[string]any{
		{"x": -1, "y": 3},
		{"x": 3, "y": MaxGotoCoordinate + 1},
		{"x": 3, "y": 3, "map": strings.Repeat("9", MaxMapName+1)},
	} {
		if text, isErr := h.call(t, "goto", bad); !isErr {
			t.Errorf("goto %v = %s, want a refusal", bad, text)
		}
	}

	text, isErr := h.call(t, "goto", map[string]any{"x": 12, "y": 0, "run": true, "cross_grass": true})
	if isErr || !strings.Contains(text, `"outcome":"done"`) {
		t.Fatalf("goto = %s (error %v)", text, isErr)
	}
	if in := <-got; in.X != 12 || in.Y != 0 || !in.Run || !in.CrossGrass || in.Map != "" {
		t.Fatalf("the driver received %+v", in)
	}

	text, isErr = h.call(t, "goto", map[string]any{"x": 5, "y": 6, "map": "0.9"})
	if isErr || !strings.Contains(text, `"outcome":"done"`) {
		t.Fatalf("goto with a map = %s (error %v)", text, isErr)
	}
	if in := <-got; in.X != 5 || in.Y != 6 || in.Map != "0.9" {
		t.Fatalf("the driver received %+v", in)
	}
}

func TestGotoIsRefusedWithoutTheCapability(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"walk"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	text, isErr := h.call(t, "goto", map[string]any{"x": 1, "y": 1})
	if !isErr || !strings.Contains(text, `does not support "goto"`) {
		t.Fatalf("goto = %s (error %v)", text, isErr)
	}
}

func TestBattleValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan BattleIn, 1)
	h.startDriver(t, []string{"battle", "advance_text"}, func(verb string, payload json.RawMessage) (string, any) {
		var in BattleIn
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"outcome": "ended", "verb": verb}
	})

	if text, isErr := h.call(t, "battle", map[string]any{"policy": "flee"}); !isErr {
		t.Errorf("battle with policy flee = %s, want a refusal", text)
	}
	text, isErr := h.call(t, "battle", map[string]any{"policy": "run"})
	if isErr || !strings.Contains(text, `"outcome":"ended"`) {
		t.Fatalf("battle = %s (error %v)", text, isErr)
	}
	if in := <-got; in.Policy != "run" {
		t.Fatalf("the driver received %+v", in)
	}
	text, isErr = h.call(t, "battle", map[string]any{"policy": "effective"})
	if isErr || !strings.Contains(text, `"outcome":"ended"`) {
		t.Fatalf("battle effective = %s (error %v)", text, isErr)
	}
	if in := <-got; in.Policy != "effective" {
		t.Fatalf("the driver received %+v", in)
	}
	text, isErr = h.call(t, "battle", map[string]any{"policy": "manual"})
	if isErr || !strings.Contains(text, `"outcome":"ended"`) {
		t.Fatalf("battle manual = %s (error %v)", text, isErr)
	}
	if in := <-got; in.Policy != "manual" {
		t.Fatalf("the driver received %+v", in)
	}
	if text, isErr := h.call(t, "battle", map[string]any{"forget": "growl"}); !isErr {
		t.Errorf("battle with forget growl = %s, want a refusal", text)
	}
	text, isErr = h.call(t, "battle", map[string]any{"policy": "effective", "forget": "strong_variety"})
	if isErr || !strings.Contains(text, `"outcome":"ended"`) {
		t.Fatalf("battle forget = %s (error %v)", text, isErr)
	}
	if in := <-got; in.Forget != "strong_variety" {
		t.Fatalf("the driver received %+v", in)
	}
	if text, isErr := h.call(t, "battle", map[string]any{"stop_hp_below": 1.5}); !isErr {
		t.Errorf("battle with stop_hp_below 1.5 = %s, want a refusal", text)
	}
	text, isErr = h.call(t, "battle", map[string]any{"stop_hp_below": 0.5})
	if isErr || !strings.Contains(text, `"outcome":"ended"`) {
		t.Fatalf("battle stop_hp_below = %s (error %v)", text, isErr)
	}
	if in := <-got; in.StopHPBelow != 0.5 {
		t.Fatalf("the driver received %+v", in)
	}
	text, isErr = h.call(t, "advance_text", map[string]any{})
	if isErr || !strings.Contains(text, `"verb":"advance_text"`) {
		t.Fatalf("advance_text = %s (error %v)", text, isErr)
	}
	<-got
}

func TestTalkValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	got := make(chan TalkIn, 1)
	h.startDriver(t, []string{"talk"}, func(verb string, payload json.RawMessage) (string, any) {
		var in TalkIn
		json.Unmarshal(payload, &in)
		got <- in
		return "result", map[string]any{"outcome": "closed"}
	})

	if text, isErr := h.call(t, "talk", map[string]any{"local_id": -1}); !isErr {
		t.Errorf("talk with local_id -1 = %s, want a refusal", text)
	}
	text, isErr := h.call(t, "talk", map[string]any{"local_id": 4})
	if isErr || !strings.Contains(text, `"outcome":"closed"`) {
		t.Fatalf("talk = %s (error %v)", text, isErr)
	}
	if in := <-got; in.LocalID == nil || *in.LocalID != 4 {
		t.Fatalf("the driver received %+v", in)
	}
	if _, isErr := h.call(t, "talk", map[string]any{}); isErr {
		t.Fatal("talk to the nearest was refused")
	}
	if in := <-got; in.LocalID != nil {
		t.Fatalf("the driver received %+v for the nearest", in)
	}
}

func TestWalkIsRefusedWithoutTheCapability(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"press"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	text, isErr := h.call(t, "walk", map[string]any{"direction": "up", "tiles": 1})
	if !isErr || !strings.Contains(text, `does not support "walk"`) {
		t.Fatalf("walk = %s (error %v)", text, isErr)
	}
}

func TestSelectIsRefusedWithoutTheCapability(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"observe"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	text, isErr := h.call(t, "select", map[string]any{"item": "YES"})
	if !isErr || !strings.Contains(text, `does not support "select"`) {
		t.Fatalf("select = %s (error %v)", text, isErr)
	}
}

func TestScreenshotReturnsTheDriversPicture(t *testing.T) {
	h := newHarness(t)
	pic := filepath.Join(t.TempDir(), "shot.png")
	want := []byte("\x89PNG\r\n\x1a\nnot really a png, but these exact bytes")
	if err := os.WriteFile(pic, want, 0o644); err != nil {
		t.Fatal(err)
	}
	h.startDriver(t, []string{"screenshot"}, func(verb string, _ json.RawMessage) (string, any) {
		return "result", map[string]any{"path": pic, "frame": 42}
	})

	res, err := h.session.CallTool(context.Background(), &mcp.CallToolParams{Name: "screenshot", Arguments: map[string]any{"name": "here"}})
	if err != nil || res.IsError {
		t.Fatalf("screenshot: %v %+v", err, res)
	}
	var got []byte
	for _, c := range res.Content {
		if img, ok := c.(*mcp.ImageContent); ok {
			if img.MIMEType != "image/png" {
				t.Fatalf("MIME type %q", img.MIMEType)
			}
			got = img.Data
		}
	}
	if string(got) != string(want) {
		t.Fatalf("image bytes = %q, want the file's", got)
	}
}

func TestScreenshotAnnotateNeedsItsCapability(t *testing.T) {
	h := newHarness(t)
	pic := filepath.Join(t.TempDir(), "shot.png")
	if err := os.WriteFile(pic, []byte("png"), 0o644); err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	h.startDriver(t, []string{"screenshot"}, func(verb string, payload json.RawMessage) (string, any) {
		_ = json.Unmarshal(payload, &got)
		return "result", map[string]any{"path": pic}
	})
	res, err := h.session.CallTool(context.Background(), &mcp.CallToolParams{Name: "screenshot", Arguments: map[string]any{"name": "here", "annotate": true}})
	if err != nil || !res.IsError {
		t.Fatalf("annotate without screenshot:annotate was not refused: %v %+v", err, res)
	}
	if got != nil {
		t.Fatalf("the refused call reached the driver: %v", got)
	}
	res, err = h.session.CallTool(context.Background(), &mcp.CallToolParams{Name: "screenshot", Arguments: map[string]any{"name": "here"}})
	if err != nil || res.IsError {
		t.Fatalf("plain screenshot: %v %+v", err, res)
	}
	if _, ok := got["annotate"]; ok {
		t.Fatalf("a plain screenshot forwarded annotate: %v", got)
	}
}

func TestScreenshotAnnotateForwards(t *testing.T) {
	h := newHarness(t)
	pic := filepath.Join(t.TempDir(), "shot.png")
	if err := os.WriteFile(pic, []byte("png"), 0o644); err != nil {
		t.Fatal(err)
	}
	var got map[string]any
	h.startDriver(t, []string{"screenshot", "screenshot:annotate"}, func(verb string, payload json.RawMessage) (string, any) {
		_ = json.Unmarshal(payload, &got)
		return "result", map[string]any{"path": pic}
	})
	res, err := h.session.CallTool(context.Background(), &mcp.CallToolParams{Name: "screenshot", Arguments: map[string]any{"name": "here", "annotate": true}})
	if err != nil || res.IsError {
		t.Fatalf("annotate: %v %+v", err, res)
	}
	if got["annotate"] != true || got["name"] != "here" {
		t.Fatalf("forwarded %v", got)
	}
}

func TestScreenshotRefusesANonPNGPath(t *testing.T) {
	h := newHarness(t)
	other := filepath.Join(t.TempDir(), "notes.txt")
	os.WriteFile(other, []byte("x"), 0o644)
	h.startDriver(t, []string{"screenshot"}, func(string, json.RawMessage) (string, any) {
		return "result", map[string]any{"path": other}
	})
	text, isErr := h.call(t, "screenshot", map[string]any{"name": "here"})
	if !isErr || !strings.Contains(text, "not a .png") {
		t.Fatalf("screenshot = %s (error %v), want a refusal", text, isErr)
	}
}

func TestWaitValidatesAndForwards(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"wait"}, func(verb string, payload json.RawMessage) (string, any) {
		var in WaitIn
		json.Unmarshal(payload, &in)
		return "result", map[string]any{"verb": verb, "frames": in.Frames}
	})
	for _, bad := range []int{0, MaxWaitFrames + 1} {
		if text, isErr := h.call(t, "wait", map[string]any{"frames": bad}); !isErr {
			t.Errorf("wait %d = %s, want a refusal", bad, text)
		}
	}
	text, isErr := h.call(t, "wait", map[string]any{"frames": 90})
	if isErr || !strings.Contains(text, `"verb":"wait"`) || !strings.Contains(text, `"frames":90`) {
		t.Fatalf("wait = %s (error %v)", text, isErr)
	}
}

// Regression, 2026-09-16: the first events tool typed payloads as json.RawMessage, whose inferred
// output schema is an array of bytes, so the first REAL event -- an object -- failed the SDK's
// output validation live. The empty-list test below could never have caught it.
func TestEventsToolReturnsAnObjectPayload(t *testing.T) {
	h := newHarness(t)
	nc := h.startDriver(t, nil, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	writeLine(t, nc, map[string]any{"type": "event", "payload": map[string]any{"kind": "mode_changed", "to": "overworld", "frame": 13316}})

	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, newest := h.hub.EventsSince(0); newest == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the event never arrived")
		}
		time.Sleep(5 * time.Millisecond)
	}
	text, isErr := h.call(t, "events", map[string]any{"since": 0})
	if isErr || !strings.Contains(text, `"kind":"mode_changed"`) || !strings.Contains(text, `"newest":1`) {
		t.Fatalf("events = %s (error %v)", text, isErr)
	}
}

func TestACheatMarksTheSegmentReachedAndPlayDoesNot(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"press", "cheat:warp"}, func(verb string, payload json.RawMessage) (string, any) {
		return "result", map[string]any{"verb": verb}
	})

	h.call(t, "press", map[string]any{"buttons": []string{"Left"}, "frames": 16})
	text, isErr := h.call(t, "segment", map[string]any{"label": "warp to the town"})
	if isErr || !strings.Contains(text, `"claim":"walked"`) {
		t.Fatalf("after play only, segment = %s (error %v)", text, isErr)
	}

	if text, isErr := h.call(t, "cheat", map[string]any{"kind": "warp", "args": map[string]any{"map": "0.10"}}); isErr {
		t.Fatalf("cheat = %s", text)
	}
	text, isErr = h.call(t, "segment", map[string]any{"label": "next"})
	var out SegmentOut
	if isErr || json.Unmarshal([]byte(text), &out) != nil {
		t.Fatalf("after a cheat, segment = %s (error %v)", text, isErr)
	}
	c := out.Closed
	if c.N != 2 || c.Label != "warp to the town" || c.Claim != "reached" || len(c.Because) != 1 || c.Because[0] != "cheat:warp" || c.Ended == nil {
		t.Fatalf("closed segment = %+v", c)
	}
	if out.Current.Claim != "walked" || out.Current.Ended != nil || strings.Contains(text, `"ended":"0001`) {
		t.Fatalf("the new segment = %+v in %s", out.Current, text)
	}
}

func TestACheatKindTheDriverDidNotAnnounceIsRefused(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, []string{"cheat:warp"}, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	text, isErr := h.call(t, "cheat", map[string]any{"kind": "noclip"})
	if !isErr || !strings.Contains(text, `does not support "cheat:noclip"`) {
		t.Fatalf("cheat noclip = %s (error %v)", text, isErr)
	}
	if got := h.log.Current().Claim; got != "walked" {
		t.Fatalf("a refused cheat marked the segment %q", got)
	}
}

func TestSnapshotNeedsTheFileAndRestoreNeedsItToExist(t *testing.T) {
	h := newHarness(t)
	writes := true
	h.startDriver(t, []string{"snapshot", "restore"}, func(verb string, payload json.RawMessage) (string, any) {
		var p struct {
			Path string `json:"path"`
		}
		json.Unmarshal(payload, &p)
		if verb == "snapshot" && writes {
			os.WriteFile(filepath.FromSlash(p.Path), []byte("state"), 0o644)
		}
		return "result", map[string]any{"path": p.Path}
	})

	if text, isErr := h.call(t, "restore", map[string]any{"label": "never_saved"}); !isErr || !strings.Contains(text, "no snapshot named") {
		t.Fatalf("restore of a missing label = %s (error %v)", text, isErr)
	}
	if text, isErr := h.call(t, "snapshot", map[string]any{"label": "../escape"}); !isErr {
		t.Fatalf("a label with a path in it was accepted: %s", text)
	}

	text, isErr := h.call(t, "snapshot", map[string]any{"label": "before_door"})
	if isErr || !strings.Contains(text, `"bytes":5`) {
		t.Fatalf("snapshot = %s (error %v)", text, isErr)
	}
	if _, err := os.Stat(filepath.Join(h.states, "fakegame", "before_door.State")); err != nil {
		t.Fatalf("the snapshot is not under the states folder: %v", err)
	}

	writes = false
	if text, isErr := h.call(t, "snapshot", map[string]any{"label": "not_written"}); !isErr || !strings.Contains(text, "no snapshot file exists") {
		t.Fatalf("a driver that answered without writing = %s (error %v)", text, isErr)
	}

	if text, isErr := h.call(t, "restore", map[string]any{"label": "before_door"}); isErr {
		t.Fatalf("restore = %s", text)
	}
	if got := h.log.Current(); got.Claim != "reached" || got.Because[0] != "restore" {
		t.Fatalf("after a restore the segment is %+v", got)
	}
}

func TestEventsTool(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, nil, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	text, isErr := h.call(t, "events", map[string]any{"since": 0})
	if isErr || !strings.Contains(text, `"events":[]`) {
		t.Fatalf("events = %s (error %v)", text, isErr)
	}
}
