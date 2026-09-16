package server

import (
	"bufio"
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/modelcontextprotocol/go-sdk/mcp"
)

// harness wires a hub on loopback to the MCP server, and an in-memory MCP client to that.
type harness struct {
	hub     *driver.Hub
	session *mcp.ClientSession
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

	serverT, clientT := mcp.NewInMemoryTransports()
	if _, err := New(hub, "test").Connect(ctx, serverT, nil); err != nil {
		t.Fatalf("server connect: %v", err)
	}
	client := mcp.NewClient(&mcp.Implementation{Name: "test-client", Version: "test"}, nil)
	session, err := client.Connect(ctx, clientT, nil)
	if err != nil {
		t.Fatalf("client connect: %v", err)
	}
	t.Cleanup(func() { session.Close() })
	return &harness{hub: hub, session: session}
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

// startDriver connects a scripted driver with the given capabilities.
func (h *harness) startDriver(t *testing.T, capabilities []string, answer answerFunc) {
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
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("the scripted driver never became current")
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

func TestEventsTool(t *testing.T) {
	h := newHarness(t)
	h.startDriver(t, nil, func(string, json.RawMessage) (string, any) { return "result", map[string]any{} })
	text, isErr := h.call(t, "events", map[string]any{"since": 0})
	if isErr || !strings.Contains(text, `"events":[]`) {
		t.Fatalf("events = %s (error %v)", text, isErr)
	}
}
