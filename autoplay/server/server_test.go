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

func newHarness(t *testing.T) *harness {
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

	serverT, clientT := mcp.NewInMemoryTransports()
	if _, err := New(hub, "test", Options{Log: runs, StatesDir: states}).Connect(ctx, serverT, nil); err != nil {
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
	nc, err := net.Dial("tcp", h.hub.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { nc.Close() })

	hello := driver.Hello{Protocol: driver.Protocol, Host: "fakehost", Game: "fakegame", Capabilities: capabilities}
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
	if in := <-got; in.Direction != "left" || in.Tiles != 3 {
		t.Fatalf("the driver received %+v", in)
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
