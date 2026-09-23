// Command trials runs one fight recipe N times against a live driver and scores each try: won or
// not, game time, hits taken with what hit, the target's HP left. It is how one build of a fight
// reflex is judged against another: five tries of the same setup, never one (the TEVI phase log,
// 2026-09-17: "one try per build proves nothing").
//
//	go run ./cmd/trials -listen 127.0.0.1:7872 -recipe games/tevi/trials/ribauld_infernal.json -n 5 -set chain_guard=false
//
// A recipe is JSON: `setup`, the calls that bring the game to the fight each try (restore, the walk
// in, the dialogue); `fight`, the reflex call made in chunks until it ends; `on_paused`, the calls
// that clear a window the game opens mid-fight, repeated until the game is back in play (a TEVI tutorial window takes no
// Confirm until it has stood a while in real time: the game is paused under it, 2026-09-23); `fast`, the fight chunks run
// with the clock's fast action on (dialogue and windows at the game's own pace: TEVI's dialogue took no Confirm while fast);
// `max_frames`, the game time a try may take. -set
// overrides one of the fight's args (the value is JSON, else a string), so a rule switched per call
// is tried without a rebuild. Each try goes to runs/trials/<time>.ndjson with its chunks, and the
// last line is the summary.
//
// Run from autoplay/. Like mcpcall, it starts its own core; the driver must be on -listen's port.
package main

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type call struct {
	Name      string         `json:"name"`
	Arguments map[string]any `json:"arguments,omitempty"`
}

type recipe struct {
	Setup     []call `json:"setup"`
	Fight     call   `json:"fight"`
	OnPaused  []call `json:"on_paused"`
	Fast      bool   `json:"fast"`
	Timeline  bool   `json:"timeline"`
	MaxFrames int    `json:"max_frames"`
}

// hit is one damage_taken event during a try's fight.
type hit struct {
	Damage     float64 `json:"damage"`
	BulletType string  `json:"bullet_type,omitempty"`
	Source     string  `json:"source,omitempty"`
}

// try is one try's score.
type try struct {
	N        int              `json:"n"`
	Won      bool             `json:"won"`
	Outcome  string           `json:"outcome"`
	Frames   int              `json:"frames"`
	Seconds  float64          `json:"seconds"`
	Hits     int              `json:"hits"`
	Damage   float64          `json:"damage"`
	HitList  []hit            `json:"hit_list"`
	Unlocks  []string         `json:"unlocks,omitempty"`  // popup_shown title and text: a new move announced mid-fight
	Timeline []map[string]any `json:"timeline,omitempty"` // the target's changes, frame by frame, from the flight recorder
	BossHP   any              `json:"boss_hp_end"`
	Chunks   []map[string]any `json:"chunks"`
	Error    string           `json:"error,omitempty"`
	Duration string           `json:"wall_time"`
}

// summary is the line a build is judged by.
type summary struct {
	Label         string         `json:"label"`
	Set           map[string]any `json:"set"`
	Tries         int            `json:"tries"`
	Wins          int            `json:"wins"`
	MedianWinSecs float64        `json:"median_win_seconds"`
	Hits          int            `json:"hits"`
	HitlessWins   int            `json:"hitless_wins"`
	HitsBy        map[string]int `json:"hits_by"`
}

type setFlags map[string]any

func (s setFlags) String() string { return fmt.Sprint(map[string]any(s)) }
func (s setFlags) Set(v string) error {
	k, val, ok := strings.Cut(v, "=")
	if !ok || k == "" {
		return fmt.Errorf("-set wants key=value, got %q", v)
	}
	var parsed any
	if err := json.Unmarshal([]byte(val), &parsed); err != nil {
		parsed = val
	}
	s[k] = parsed
	return nil
}

func main() {
	listen := flag.String("listen", "127.0.0.1:7870", "the core's driver port")
	coreCmd := flag.String("core", "go run ./cmd/autoplay", "the command that starts the core, run from autoplay/")
	logPath := flag.String("log", "runs/core.log", "the core's log file")
	recipePath := flag.String("recipe", "", "the recipe JSON")
	n := flag.Int("n", 5, "tries")
	label := flag.String("label", "", "a name for this build in the summary")
	wait := flag.Duration("wait", 60*time.Second, "how long to wait for a driver")
	sets := setFlags{}
	flag.Var(sets, "set", "key=value overriding one of the fight's args (repeatable)")
	flag.Parse()

	raw, err := os.ReadFile(*recipePath)
	if err != nil {
		fail("read -recipe: %v", err)
	}
	var r recipe
	if err := json.Unmarshal(raw, &r); err != nil {
		fail("-recipe: %v", err)
	}
	if r.Fight.Name == "" {
		fail("-recipe has no fight")
	}
	if r.MaxFrames <= 0 {
		r.MaxFrames = 60 * 60 * 5
	}
	applySets(&r.Fight, sets)

	ctx := context.Background()
	argv := append(strings.Fields(*coreCmd), "-listen", *listen, "-log", *logPath)
	client := mcp.NewClient(&mcp.Implementation{Name: "trials", Version: "dev"}, nil)
	session, err := client.Connect(ctx, &mcp.CommandTransport{Command: exec.Command(argv[0], argv[1:]...)}, nil)
	if err != nil {
		fail("start the core: %v", err)
	}
	defer session.Close()
	if !waitForDriver(ctx, session, *wait) {
		fail("no driver connected within %s", *wait)
	}

	if err := os.MkdirAll("runs/trials", 0o755); err != nil {
		fail("%v", err)
	}
	outPath := filepath.Join("runs/trials", time.Now().Format("2006-01-02_150405")+".ndjson")
	out, err := os.Create(outPath)
	if err != nil {
		fail("%v", err)
	}
	defer out.Close()
	enc := json.NewEncoder(out)
	_ = enc.Encode(map[string]any{"recipe": *recipePath, "label": *label, "set": sets, "fight": r.Fight})

	var tries []try
	for i := 1; i <= *n; i++ {
		t := runTry(ctx, session, r, i)
		tries = append(tries, t)
		_ = enc.Encode(t)
		fmt.Printf("try %d: %s won=%v %.1fs hits=%d damage=%.0f boss_hp=%v unlocks=%v wall=%s%s\n", t.N, t.Outcome, t.Won, t.Seconds, t.Hits, t.Damage, t.BossHP, t.Unlocks, t.Duration, errSuffix(t.Error))
	}
	s := summarize(*label, sets, tries)
	_ = enc.Encode(map[string]any{"summary": s})
	line, _ := json.Marshal(s)
	fmt.Printf("SUMMARY %s\n(tries in %s)\n", line, outPath)
}

func errSuffix(e string) string {
	if e == "" {
		return ""
	}
	return " error=" + e
}

func applySets(fight *call, sets setFlags) {
	if len(sets) == 0 {
		return
	}
	if fight.Arguments == nil {
		fight.Arguments = map[string]any{}
	}
	args, _ := fight.Arguments["args"].(map[string]any)
	if args == nil {
		args = map[string]any{}
	}
	for k, v := range sets {
		args[k] = v
	}
	fight.Arguments["args"] = args
}

// runTry plays one try: the setup, then the fight in chunks until it ends or the try runs out of time.
func runTry(ctx context.Context, s *mcp.ClientSession, r recipe, n int) try {
	began := time.Now()
	t := try{N: n, HitList: []hit{}}
	for _, c := range r.Setup {
		_, err := callJSON(ctx, s, c)
		// After a loss the game runs its game-over and reload, and a restore refuses until its save managers are back.
		for retry := 0; err != nil && c.Name == "restore" && strings.Contains(err.Error(), "not loaded") && retry < 30; retry++ {
			_, _ = callJSON(ctx, s, call{Name: "clock", Arguments: map[string]any{"action": "release"}})
			_, _ = callJSON(ctx, s, call{Name: "wait", Arguments: map[string]any{"frames": 60}})
			_, err = callJSON(ctx, s, c)
		}
		if err != nil {
			t.Outcome, t.Error = "setup_failed", c.Name+": "+err.Error()
			t.Duration = time.Since(began).Round(time.Second).String()
			return t
		}
	}
	since := newestEvent(ctx, s)
	fast := func(on bool) {
		if r.Fast {
			_, _ = callJSON(ctx, s, call{Name: "clock", Arguments: map[string]any{"action": "fast", "on": on}})
		}
	}
	defer fast(false)
	paused := 0
	for t.Frames < r.MaxFrames {
		fast(true)
		res, err := callJSON(ctx, s, r.Fight)
		if err != nil {
			// A window the game opened (a new move's tutorial) pauses it: the fight refuses to start until it is closed.
			if strings.Contains(err.Error(), "not in paused") && paused < 3 && len(r.OnPaused) > 0 {
				paused++
				fast(false)
				clearPause(ctx, s, r.OnPaused)
				continue
			}
			t.Outcome, t.Error = "error", err.Error()
			break
		}
		t.Chunks = append(t.Chunks, trimChunk(res))
		if r.Timeline {
			t.Timeline = append(t.Timeline, targetTimeline(ctx, s, intOf(res["frames"]))...)
		}
		t.Frames += intOf(res["frames"])
		t.Hits += intOf(res["hits_taken"])
		if tg, ok := res["target"].(map[string]any); ok {
			t.BossHP = tg["hp_end"]
		}
		t.Outcome, _ = res["outcome"].(string)
		if t.Outcome == "mode_changed" && paused < 3 && len(r.OnPaused) > 0 {
			paused++
			fast(false)
			clearPause(ctx, s, r.OnPaused)
			continue
		}
		if t.Outcome != "timeout" {
			break
		}
	}
	t.Won = t.Outcome == "defeated"
	t.Seconds = float64(t.Frames) / 60
	t.HitList, t.Unlocks = hitsSince(ctx, s, since)
	for _, h := range t.HitList {
		t.Damage += h.Damage
	}
	t.Duration = time.Since(began).Round(time.Second).String()
	return t
}

// clearPause runs the on_paused calls until the last one's answer finds the game in play again, at most 40 rounds.
func clearPause(ctx context.Context, s *mcp.ClientSession, calls []call) {
	for round := 0; round < 40; round++ {
		var last map[string]any
		for _, c := range calls {
			last, _ = callJSON(ctx, s, c)
		}
		if modeOf(last) == "play" {
			return
		}
	}
}

// modeOf reads the game's mode from an answer's `after` observation.
func modeOf(res map[string]any) string {
	after, _ := res["after"].(map[string]any)
	m, _ := after["mode"].(string)
	return m
}

// targetTimeline reads the flight recorder over a chunk's frames and keeps each frame where the nearest enemy (the fight's
// target: a boss fight has one) changed logic state, animation, armor state or whether it is in hitstun, and every 50 HP
// it lost: what a break looks like, and what the player was doing, without keeping 600 rows a chunk.
func targetTimeline(ctx context.Context, s *mcp.ClientSession, frames int) []map[string]any {
	if frames < 1 {
		return nil
	}
	if frames > 600 {
		frames = 600
	}
	m, err := callJSON(ctx, s, call{Name: "recent", Arguments: map[string]any{"frames": frames, "every": 1}})
	if err != nil {
		return nil
	}
	cols, _ := m["columns"].([]any)
	ncols, _ := m["near_columns"].([]any)
	types, _ := m["types"].([]any)
	rows, _ := m["rows"].([]any)
	idx := func(list []any, name string) int {
		for i, c := range list {
			if c == name {
				return i
			}
		}
		return -1
	}
	name := func(v any) any {
		if i, ok := v.(float64); ok && int(i) >= 0 && int(i) < len(types) {
			return types[int(i)]
		}
		return v
	}
	cNear, cFrame, cLogic, cAnim, cHP := idx(cols, "near"), idx(cols, "frame"), idx(cols, "logic"), idx(cols, "anim"), idx(cols, "hp")
	nHP, nAnim, nLogic, nStun, nArmor, nRec := idx(ncols, "hp"), idx(ncols, "anim"), idx(ncols, "logic"), idx(ncols, "hitstun_raw"), idx(ncols, "armor"), idx(ncols, "armor_recovering")
	if cNear < 0 || nHP < 0 {
		return nil
	}
	var out []map[string]any
	var last string
	lastHP := -1.0
	for _, rv := range rows {
		row, _ := rv.([]any)
		if len(row) <= cNear {
			continue
		}
		near, _ := row[cNear].([]any)
		if len(near) == 0 {
			continue
		}
		e, _ := near[0].([]any)
		if len(e) <= nRec {
			continue
		}
		hp, _ := e[nHP].(float64)
		stun, _ := e[nStun].(float64)
		key := fmt.Sprint(name(e[nLogic]), "|", name(e[nAnim]), "|", e[nRec], "|", stun > 0)
		if key == last && (lastHP < 0 || lastHP-hp < 50) {
			continue
		}
		last, lastHP = key, hp
		out = append(out, map[string]any{
			"frame": row[cFrame], "hp": hp, "logic": name(e[nLogic]), "anim": name(e[nAnim]), "hitstun": stun,
			"armor": e[nArmor], "recovering": e[nRec],
			"her": fmt.Sprint(name(row[cLogic]), "|", name(row[cAnim]), "|", row[cHP]),
		})
	}
	return out
}

// trimChunk keeps a chunk's score and drops what makes it large (the observation after it).
func trimChunk(res map[string]any) map[string]any {
	keep := map[string]any{}
	for _, k := range []string{"outcome", "frames", "hits_taken", "attacks", "ranged", "jumps", "dodges", "orb_pushes", "orb_frames", "spiral_slashes", "upper_slashes", "break_launches", "punish_frames", "backflips", "hp_start", "hp_end", "target"} {
		if v, ok := res[k]; ok {
			keep[k] = v
		}
	}
	return keep
}

func summarize(label string, sets setFlags, tries []try) summary {
	s := summary{Label: label, Set: sets, Tries: len(tries), HitsBy: map[string]int{}}
	var winSecs []float64
	for _, t := range tries {
		s.Hits += t.Hits
		if t.Won {
			s.Wins++
			winSecs = append(winSecs, t.Seconds)
			if t.Hits == 0 {
				s.HitlessWins++
			}
		}
		for _, h := range t.HitList {
			k := h.BulletType
			if k == "" {
				k = h.Source
			}
			if k == "" {
				k = "unknown"
			}
			s.HitsBy[k]++
		}
	}
	s.MedianWinSecs = median(winSecs)
	return s
}

func median(v []float64) float64 {
	if len(v) == 0 {
		return 0
	}
	c := append([]float64(nil), v...)
	sort.Float64s(c)
	m := len(c) / 2
	if len(c)%2 == 1 {
		return c[m]
	}
	return (c[m-1] + c[m]) / 2
}

func intOf(v any) int {
	f, _ := v.(float64)
	return int(f)
}

func callJSON(ctx context.Context, s *mcp.ClientSession, c call) (map[string]any, error) {
	args := c.Arguments
	if args == nil {
		args = map[string]any{}
	}
	res, err := s.CallTool(ctx, &mcp.CallToolParams{Name: c.Name, Arguments: args})
	if err != nil {
		return nil, err
	}
	text := textOf(res)
	if res.IsError {
		return nil, fmt.Errorf("%s", text)
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(text), &m); err != nil {
		return map[string]any{"text": text}, nil
	}
	return m, nil
}

func newestEvent(ctx context.Context, s *mcp.ClientSession) float64 {
	m, err := callJSON(ctx, s, call{Name: "events", Arguments: map[string]any{"since": 0}})
	if err != nil {
		return 0
	}
	f, _ := m["newest"].(float64)
	return f
}

// hitsSince reads the damage_taken events since a sequence number, and the titles of the popups shown.
func hitsSince(ctx context.Context, s *mcp.ClientSession, since float64) ([]hit, []string) {
	hits := []hit{}
	var unlocks []string
	m, err := callJSON(ctx, s, call{Name: "events", Arguments: map[string]any{"since": since}})
	if err != nil {
		return hits, unlocks
	}
	evs, _ := m["events"].([]any)
	for _, e := range evs {
		em, _ := e.(map[string]any)
		p, _ := em["payload"].(map[string]any)
		if p == nil {
			continue
		}
		if h, ok := hitOf(p); ok {
			hits = append(hits, h)
		}
		if k, _ := p["kind"].(string); k == "popup_shown" {
			// The title is the kind ("NEW MOVE"); the text names the move and how to use it.
			title, _ := p["title"].(string)
			text, _ := p["text"].(string)
			unlocks = append(unlocks, strings.TrimSpace(title+": "+text))
		}
	}
	return hits, unlocks
}

// hitOf reads a damage_taken payload: the kind at the top level or under "kind", the fields beside it or under "data".
func hitOf(p map[string]any) (hit, bool) {
	kind, _ := p["kind"].(string)
	if kind == "" {
		kind, _ = p["type"].(string)
	}
	if kind != "damage_taken" {
		return hit{}, false
	}
	d := p
	if inner, ok := p["data"].(map[string]any); ok {
		d = inner
	}
	h := hit{}
	h.Damage, _ = d["damage"].(float64)
	h.BulletType, _ = d["bullet_type"].(string)
	switch src := d["source"].(type) {
	case string:
		h.Source = src
	case map[string]any:
		h.Source, _ = src["type"].(string)
		if h.Source == "" {
			h.Source, _ = src["name"].(string)
		}
	}
	return h, true
}

func textOf(res *mcp.CallToolResult) string {
	var b strings.Builder
	for _, c := range res.Content {
		if tc, ok := c.(*mcp.TextContent); ok {
			b.WriteString(tc.Text)
		}
	}
	return b.String()
}

func waitForDriver(ctx context.Context, session *mcp.ClientSession, wait time.Duration) bool {
	deadline := time.Now().Add(wait)
	for {
		res, err := session.CallTool(ctx, &mcp.CallToolParams{Name: "status", Arguments: map[string]any{}})
		if err == nil && strings.Contains(textOf(res), `"connected":true`) {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(250 * time.Millisecond)
	}
}

func fail(format string, a ...any) {
	fmt.Fprintf(os.Stderr, "trials: "+format+"\n", a...)
	os.Exit(1)
}
