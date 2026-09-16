package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/autoplay/driver"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/runlog"
	"github.com/Tsukino-uwu/MeshGhost/autoplay/scenario"
)

const sight = `{
  "name": "sight",
  "game": "fakegame",
  "repeat": 3,
  "setup": [{"tool": "cheat", "args": {"kind": "warp", "args": {"map": "0.17", "x": 25, "y": 12}},
             "expect": [{"path": "done", "equals": true}]}],
  "steps": [{"tool": "walk", "args": {"direction": "down", "tiles": 1},
             "expect": [{"path": "outcome", "equals": "spotted"}, {"path": "trainer.tiles_away", "equals": 2}]}]
}`

// fakeDriver connects to hub as game and answers a warp cheat and a walk the way a driver would.
func fakeDriver(t *testing.T, hub *driver.Hub, game string) {
	t.Helper()
	nc, err := net.Dial("tcp", hub.Addr().String())
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { nc.Close() })
	hello, _ := json.Marshal(map[string]any{"type": "hello", "payload": driver.Hello{
		Protocol: driver.Protocol, Host: "fakehost", Game: game, Capabilities: []string{"cheat:warp", "walk"}}})
	nc.Write(append(hello, '\n'))
	go func() {
		sc := bufio.NewScanner(nc)
		sc.Buffer(make([]byte, 0, 4096), driver.MaxLineBytes)
		for sc.Scan() {
			var req struct {
				ID   uint64 `json:"id"`
				Type string `json:"type"`
			}
			if json.Unmarshal(sc.Bytes(), &req) != nil || req.ID == 0 {
				continue
			}
			var payload any = map[string]any{"message": "unexpected " + req.Type}
			kind := "error"
			switch req.Type {
			case "cheat":
				kind, payload = "result", map[string]any{"kind": "warp", "done": true}
			case "walk":
				kind, payload = "result", map[string]any{"outcome": "spotted", "moved": 1, "trainer": map[string]any{"local_id": 3, "tiles_away": 2}}
			}
			line, _ := json.Marshal(map[string]any{"id": req.ID, "type": kind, "payload": payload})
			if _, err := nc.Write(append(line, '\n')); err != nil {
				return
			}
		}
	}()
}

// serveOne runs serve over a fresh hub and run log, with a fake driver of game connected, and returns the
// exit code, the output and the run log's path.
func serveOne(t *testing.T, text, game string, opts scenario.Options) (int, string, string) {
	t.Helper()
	s, err := scenario.Parse(strings.NewReader(text))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	hub, err := driver.Listen("127.0.0.1:0", nil)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	runs, err := runlog.Open(t.TempDir())
	if err != nil {
		t.Fatalf("run log: %v", err)
	}
	if game != "" {
		fakeDriver(t, hub, game)
	}
	var out, errOut bytes.Buffer
	opts.Out = &out
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	code := serve(ctx, hub, runs, t.TempDir(), []*scenario.Scenario{s}, opts, 5*time.Second, &out, &errOut)
	runs.Close()
	return code, out.String() + errOut.String(), runs.Path()
}

func TestServePassesAndLabelsTheRunLog(t *testing.T) {
	code, out, logPath := serveOne(t, sight, "fakegame", scenario.Options{})
	if code != 0 || !strings.Contains(out, "sight: PASS, 3 of 3") {
		t.Fatalf("exit %d:\n%s", code, out)
	}
	// The run log is the server's own: each run's setup reached by the cheat, its steps walked.
	body, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	claims := map[string]string{}
	for _, line := range strings.Split(strings.TrimSpace(string(body)), "\n") {
		var rec struct {
			Type    string         `json:"type"`
			Segment runlog.Segment `json:"segment"`
		}
		if json.Unmarshal([]byte(line), &rec) == nil && rec.Type == "segment" {
			claims[rec.Segment.Label] = rec.Segment.Claim
		}
	}
	for n := 1; n <= 3; n++ {
		label := "scenario sight run " + string(rune('0'+n)) + "/3"
		if claims[label+": setup"] != "reached" || claims[label+": steps"] != "walked" {
			t.Errorf("run %d: setup %q, steps %q; want reached and walked\n%s", n, claims[label+": setup"], claims[label+": steps"], body)
		}
	}
}

func TestServeFailsABrokenExpectation(t *testing.T) {
	broken := strings.Replace(sight, `tiles_away", "equals": 2`, `tiles_away", "equals": 3`, 1)
	if broken == sight {
		t.Fatal("the replacement did not apply")
	}
	code, out, _ := serveOne(t, broken, "fakegame", scenario.Options{})
	if code != 1 || !strings.Contains(out, "run 1/3 FAIL at steps 1 (walk): trainer.tiles_away: want 3, got 2") {
		t.Fatalf("exit %d:\n%s", code, out)
	}
}

func TestServeRefusesAnotherGame(t *testing.T) {
	code, out, _ := serveOne(t, sight, "othergame", scenario.Options{})
	if code != 2 || !strings.Contains(out, "sight not run") {
		t.Fatalf("exit %d:\n%s", code, out)
	}
}

func TestServeRefusesAnUnknownTool(t *testing.T) {
	unknown := strings.Replace(sight, `"tool": "walk"`, `"tool": "walkk"`, 1)
	code, out, _ := serveOne(t, unknown, "fakegame", scenario.Options{})
	if code != 2 || !strings.Contains(out, `calls "walkk", which the server does not have`) {
		t.Fatalf("exit %d:\n%s", code, out)
	}
}

func TestServeWithNoDriver(t *testing.T) {
	s, _ := scenario.Parse(strings.NewReader(sight))
	hub, err := driver.Listen("127.0.0.1:0", nil)
	if err != nil {
		t.Fatal(err)
	}
	var out bytes.Buffer
	code := serve(context.Background(), hub, nil, t.TempDir(), []*scenario.Scenario{s}, scenario.Options{Out: &out}, 300*time.Millisecond, &out, &out)
	if code != 2 || !strings.Contains(out.String(), "no driver connected") {
		t.Fatalf("exit %d:\n%s", code, out.String())
	}
}
