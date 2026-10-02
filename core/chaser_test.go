package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestChaserFollowsTheLocalPlayerBehindByItsDelay: with the player walking x = t/10ms and a 100ms delay, the chaser
// renders where the player was about 100ms ago, cosmetic, with no relay at all.
func TestChaserFollowsTheLocalPlayerBehindByItsDelay(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 100 * time.Millisecond
	c.ChaserSpawnDelay = 50 * time.Millisecond
	c.ChaserName = "Chaser"
	c.ChaserColor = "#7A2A2A"
	c.mu.Unlock()
	if n := c.StartChasers(); n != 1 {
		t.Fatalf("StartChasers = %d, want 1", n)
	}
	const id = "chaser:1"
	start := time.Now()
	var lag float64 = -1
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		x := float64(time.Since(start) / (10 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}, Anim: "run"})
		time.Sleep(10 * time.Millisecond)
		if m, ok := fa.renderMsgOf(id); ok && x > 30 {
			if !m.Cosmetic {
				t.Fatalf("chaser rendered without cosmetic=true: %+v", m)
			}
			lag = x - m.State.Position[0]
			break
		}
	}
	// 100ms behind is 10 samples; allow scheduling slack either way.
	if lag < 5 || lag > 20 {
		t.Fatalf("chaser lag = %v samples (10ms each), want about 10 for a 100ms delay", lag)
	}
	fa.mu.Lock()
	name := fa.names[id]
	fa.mu.Unlock()
	if name.DisplayName != "Chaser" || name.Color != "#7A2A2A" {
		t.Fatalf("chaser nametag %+v", name)
	}
	c.StopChasers()
	pumpUntil(t, fa, func() bool { return drainDespawns(fa, id) > 0 }, "the chaser to despawn on StopChasers")
}

// TestChaserPackIsSpacedAndNumbered: three chasers with 50ms spacing are three peers at three lags, named "Pack 1..3";
// any count up to the roster size starts, and a larger one clamps to it.
func TestChaserPackIsSpacedAndNumbered(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserCount = 3
	c.ChaserDelay = 100 * time.Millisecond
	c.ChaserSpacing = 50 * time.Millisecond
	c.ChaserSpawnDelay = 50 * time.Millisecond
	c.ChaserName = "Pack"
	c.mu.Unlock()
	if n := c.StartChasers(); n != 3 {
		t.Fatalf("StartChasers = %d, want 3", n)
	}
	start := time.Now()
	deadline := time.Now().Add(testTimeout)
	var xs [3]float64
	seen := false
	for time.Now().Before(deadline) && !seen {
		x := float64(time.Since(start) / (10 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
		if x < 40 {
			continue
		}
		all := true
		for i := 0; i < 3; i++ {
			m, ok := fa.renderMsgOf("chaser:" + string(rune('1'+i)))
			if !ok {
				all = false
				break
			}
			xs[i] = m.State.Position[0]
		}
		seen = all
	}
	if !seen {
		t.Fatal("not all three chasers rendered")
	}
	if !(xs[0] > xs[1] && xs[1] > xs[2]) {
		t.Fatalf("chasers not spaced back-to-front: %v", xs)
	}
	fa.mu.Lock()
	n2 := fa.names["chaser:2"].DisplayName
	fa.mu.Unlock()
	if n2 != "Pack 2" {
		t.Fatalf("chaser 2 is named %q, want \"Pack 2\"", n2)
	}
	c.StopChasers()

	c.mu.Lock()
	c.ChaserCount = 99
	c.mu.Unlock()
	if n := c.StartChasers(); n != 99 {
		t.Fatalf("count 99 started %d, want all 99 (no cap)", n)
	}
	c.StopChasers()
	c.mu.Lock()
	c.ChaserCount = 1 << 20
	c.mu.Unlock()
	if n := c.StartChasers(); n != protocol.MaxRosterSize {
		t.Fatalf("count 1<<20 started %d, want the roster size %d", n, protocol.MaxRosterSize)
	}
	c.StopChasers()
}

// TestChaserSeamsOnALiveGapAndIsOffByDefault: 1.6s of silence (a menu) makes the chaser leave and reappear rather
// than glide; disabled means no peer.
func TestChaserSeamsOnALiveGapAndIsOffByDefault(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	if n := c.StartChasers(); n != 0 {
		t.Fatalf("chaser off by default, but StartChasers = %d", n)
	}
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 50 * time.Millisecond
	c.ChaserSpawnDelay = 30 * time.Millisecond
	c.mu.Unlock()
	c.StartChasers()
	const id = "chaser:1"
	for i := 0; i < 20; i++ {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{float64(i), 0}})
		time.Sleep(10 * time.Millisecond)
	}
	pumpUntil(t, fa, func() bool { _, ok := fa.renderMsgOf(id); return ok }, "the chaser to appear")
	drainDespawns(fa, id)
	// Nil frames for longer than the seam threshold.
	for i := 0; i < 8; i++ {
		fa.frame(nil)
		time.Sleep(200 * time.Millisecond)
	}
	// The pack follows the live stream, so it reappears where the player is now, never gliding from x=19.
	gone, back := false, false
	deadline := time.Now().Add(testTimeout)
	for i := 0; time.Now().Before(deadline) && !(gone && back); i++ {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{100 + float64(i), 0}})
		time.Sleep(10 * time.Millisecond)
		if drainDespawns(fa, id) > 0 {
			gone = true
		}
		if m, ok := fa.renderMsgOf(id); ok && m.State.Position[0] >= 100 {
			back = true
		}
	}
	if !gone {
		t.Fatal("the chaser never despawned across a 1.6s gap in the live stream")
	}
	if !back {
		t.Fatal("the chaser never reappeared where the player is after the gap")
	}
	c.StopChasers()
}

// TestChaserPolicyIsPushedOnlyWhenContactIsOn: session_policy carries chaser_contact as the mode's word, "hurt" or
// "kill", and omits it when contact is off or the chaser is disabled, since then no ghost exists for it to apply to.
func TestChaserPolicyIsPushedOnlyWhenContactIsOn(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.relayPolicyKnown = true
	c.relayGhostCollision = protocol.GhostCollisionDisabled
	c.mu.Unlock()
	c.pushSessionPolicy()
	select {
	case p := <-fa.policies:
		if p.ChaserContact != "" {
			t.Fatalf("chaser_contact %q pushed with contact off", p.ChaserContact)
		}
	case <-time.After(testTimeout):
		t.Fatal("no session_policy")
	}
	set := func(enabled bool, mode ChaserContact) {
		c.mu.Lock()
		c.ChaserEnabled = enabled
		c.ChaserContact = mode
		c.sentGhostCollision = ""
		c.mu.Unlock()
		c.pushSessionPolicy()
	}
	expect := func(want, why string) {
		t.Helper()
		select {
		case p := <-fa.policies:
			if p.ChaserContact != want {
				t.Fatalf("chaser_contact = %q, want %q (%s)", p.ChaserContact, want, why)
			}
		case <-time.After(testTimeout):
			t.Fatalf("no session_policy (%s)", why)
		}
	}
	set(true, ChaserContactHurt)
	expect("hurt", "after turning contact to hurt")
	set(true, ChaserContactKill)
	expect("kill", "after turning contact to kill")
	set(false, ChaserContactKill)
	expect("", "chaser disabled: no ghost for contact to apply to")
	set(true, ChaserContactOff)
	expect("", "contact off with the chaser on")
}

// TestParseChaserContactReadsTheLegacyBool: a config from when chaser.contact was a bool keeps its meaning (true is
// "hurt"), and anything that is not a mode is an error rather than a silent default.
func TestParseChaserContactReadsTheLegacyBool(t *testing.T) {
	for in, want := range map[string]ChaserContact{
		"": ChaserContactOff, "off": ChaserContactOff, "false": ChaserContactOff,
		"hurt": ChaserContactHurt, "true": ChaserContactHurt,
		"kill": ChaserContactKill,
	} {
		got, err := ParseChaserContact(in)
		if err != nil || got != want {
			t.Errorf("ParseChaserContact(%q) = %q, %v; want %q", in, got, err, want)
		}
	}
	for _, bad := range []string{"maybe", "enabled", "HURT", "1"} {
		if got, err := ParseChaserContact(bad); err == nil {
			t.Errorf("ParseChaserContact(%q) = %q with no error; want an error", bad, got)
		}
	}
	if ChaserContactOff.Active() || ChaserContact("").Active() {
		t.Error("off is not an active mode")
	}
	if !ChaserContactHurt.Active() || !ChaserContactKill.Active() {
		t.Error("hurt and kill are the active modes")
	}
}

// TestChaserNeverSpawnsOnAStandingPlayer: a player who stands still gets no chaser however long they wait; once they
// move, the chaser appears only after the spawn window.
func TestChaserNeverSpawnsOnAStandingPlayer(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 50 * time.Millisecond
	c.ChaserSpawnDelay = 200 * time.Millisecond
	c.mu.Unlock()
	c.StartChasers()
	const id = "chaser:1"
	for i := 0; i < 40; i++ {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{5, 5}})
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok := fa.renderMsgOf(id); ok {
		t.Fatal("a chaser spawned on a player who never moved")
	}
	start := time.Now()
	appeared := time.Duration(0)
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && appeared == 0 {
		x := 5 + float64(time.Since(start)/(10*time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 5}})
		time.Sleep(10 * time.Millisecond)
		if _, ok := fa.renderMsgOf(id); ok {
			appeared = time.Since(start)
		}
	}
	if appeared == 0 {
		t.Fatal("the chaser never appeared after the player started moving")
	}
	if appeared < 200*time.Millisecond {
		t.Fatalf("the chaser appeared %s after the first movement, before the 200ms spawn window", appeared)
	}
	c.StopChasers()
}

// TestChaserPackClampsAnAbsurdSpacingFast: count 8 with spacing 48h must not size the history to 336 hours of samples
// on the bridge goroutine; StartChasers returns at once and every delay is at most maxChaserBehind.
func TestChaserPackClampsAnAbsurdSpacingFast(t *testing.T) {
	c := New()
	c.ChaserEnabled = true
	c.ChaserCount = 8
	c.ChaserDelay = 0
	c.ChaserSpacing = 48 * time.Hour
	start := time.Now()
	if n := c.StartChasers(); n != 8 {
		t.Fatalf("started %d, want 8", n)
	}
	if took := time.Since(start); took > time.Second {
		t.Fatalf("StartChasers took %s with an absurd spacing", took)
	}
	c.chaserMu.Lock()
	slots := len(c.chaserHist.buf)
	for _, ch := range c.chasers {
		if ch.delay > maxChaserBehind {
			t.Fatalf("%s: delay %v -- not clamped", ch.id, ch.delay)
		}
	}
	c.chaserMu.Unlock()
	if want := int((maxChaserBehind + chaserHistorySlack).Milliseconds() / 10); slots > want {
		t.Fatalf("history holds %d slots, want at most %d -- not clamped", slots, want)
	}
	c.StopChasers()
}

// TestChaserHistoryIsFlatInTheCount: the pack shares one history sized by the deepest delay alone, so 512 chasers cost
// the same as 2 at the same depth.
func TestChaserHistoryIsFlatInTheCount(t *testing.T) {
	slotsFor := func(count int, spacing time.Duration) int {
		c := New()
		c.ChaserEnabled = true
		c.ChaserCount = count
		c.ChaserDelay = time.Second
		c.ChaserSpacing = spacing
		if n := c.StartChasers(); n != count {
			t.Fatalf("StartChasers = %d, want %d", n, count)
		}
		defer c.StopChasers()
		c.chaserMu.Lock()
		defer c.chaserMu.Unlock()
		return len(c.chaserHist.buf)
	}
	// The deepest chaser is 512s behind either way.
	deep := slotsFor(2, 511*time.Second)
	full := slotsFor(512, time.Second)
	if deep != full {
		t.Fatalf("2 chasers at depth 512s hold %d slots, 512 chasers at the same depth hold %d -- "+
			"the history must be sized by the deepest delay alone, not by the count", deep, full)
	}
	// The whole 512-pack is one ring of 514s at 100Hz.
	if want := int((514 * time.Second).Milliseconds() / 10); full != want {
		t.Fatalf("512-pack history is %d slots, want %d", full, want)
	}
}

// TestChaserHistoryLapsIntoASeamRatherThanAHole: a reader that falls further behind than the slack loses its oldest
// unread samples and is told so, rather than the writer dropping the newest and leaving a hole in the trail.
func TestChaserHistoryLapsIntoASeamRatherThanAHole(t *testing.T) {
	h := newChaserHistory(4)
	for i := 0; i < 4; i++ {
		h.add(protocol.State{Timestamp: int64(i)})
	}
	if s, got, lapped, ok, _ := h.read(0); !ok || lapped || got != 0 || s.Timestamp != 0 {
		t.Fatalf("read(0) on an exactly-full history = (%v, %d, lapped %v, ok %v), want the oldest sample untouched",
			s.Timestamp, got, lapped, ok)
	}
	h.add(protocol.State{Timestamp: 4})
	h.add(protocol.State{Timestamp: 5})
	s, got, lapped, ok, _ := h.read(0)
	if !ok || !lapped {
		t.Fatalf("read(0) after the ring wrapped = (lapped %v, ok %v), want a lapped read", lapped, ok)
	}
	if got != 2 || s.Timestamp != 2 {
		t.Fatalf("lapped read resumed at index %d (ts %d), want the oldest surviving sample, index 2", got, s.Timestamp)
	}
	if s, _, _, ok, _ := h.read(5); !ok || s.Timestamp != 5 {
		t.Fatalf("newest sample missing after a wrap: ok %v ts %d", ok, s.Timestamp)
	}
}

// TestChaserHistoryWakesAWaiterWithoutLosingIt: a reader that finds nothing gets a channel that a write landing
// immediately afterwards still closes, the lost wakeup the one-lock read() prevents.
func TestChaserHistoryWakesAWaiterWithoutLosingIt(t *testing.T) {
	h := newChaserHistory(8)
	_, _, _, ok, wait := h.read(0)
	if ok {
		t.Fatal("read(0) on an empty history returned a sample")
	}
	h.add(protocol.State{Timestamp: 7})
	select {
	case <-wait:
	case <-time.After(time.Second):
		t.Fatal("a write after an empty read never woke the waiter")
	}
	if s, _, _, ok, _ := h.read(0); !ok || s.Timestamp != 7 {
		t.Fatalf("after the wake, read(0) = (ok %v, ts %d), want the written sample", ok, s.Timestamp)
	}
}

// TestChaserHoldsWhileThePlayerIsFrozen: while the adapter says the player is frozen (a pickup popup, the pause
// menu), the chaser holds instead of converging onto the player, and on resume follows the same distance behind, with
// no seam.
func TestChaserHoldsWhileThePlayerIsFrozen(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 100 * time.Millisecond
	c.ChaserSpawnDelay = 50 * time.Millisecond
	c.mu.Unlock()
	if n := c.StartChasers(); n != 1 {
		t.Fatalf("StartChasers = %d, want 1", n)
	}
	const id = "chaser:1"
	frozen := func(f bool) {
		payload, _ := json.Marshal(bridge.PlayerFrozen{Frozen: f})
		env, _ := json.Marshal(bridge.Envelope{Type: bridge.TypePlayerFrozen, Payload: payload})
		if err := fa.conn.Send(env); err != nil {
			t.Fatalf("send player_frozen: %v", err)
		}
	}
	start := time.Now()
	var x float64
	deadline := time.Now().Add(testTimeout)
	seen := false
	for time.Now().Before(deadline) && !seen {
		x = float64(time.Since(start) / (10 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
		if st, ok := fa.rendersOf(id); ok && x > 30 && x-st.Position[0] >= 5 {
			seen = true
		}
	}
	if !seen {
		t.Fatalf("chaser never appeared behind the player")
	}
	// Four times the delay, the adapter still sending the same frame as a real freeze does.
	frozen(true)
	held := x
	at, _ := fa.rendersOf(id)
	atFreeze := at.Position[0]
	until := time.Now().Add(400 * time.Millisecond)
	for time.Now().Before(until) {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{held, 0}})
		time.Sleep(10 * time.Millisecond)
	}
	at, _ = fa.rendersOf(id)
	// One 50ms sleep slice of samples may still land after the message.
	if at.Position[0] > atFreeze+6 {
		t.Fatalf("chaser advanced from %v to %v during a freeze (player held at %v); it should hold", atFreeze, at.Position[0], held)
	}
	if at.Position[0] >= held-2 {
		t.Fatalf("chaser converged onto the frozen player: at %v, player at %v", at.Position[0], held)
	}
	frozen(false)
	base := time.Now()
	var lag float64 = -1
	deadline = time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		x = held + float64(time.Since(base)/(10*time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
		if st, ok := fa.rendersOf(id); ok && x > held+40 {
			lag = x - st.Position[0]
			break
		}
	}
	if lag < 5 || lag > 20 {
		t.Fatalf("after resume the chaser lag = %v samples, want about 10 for a 100ms delay", lag)
	}
	if n := drainDespawns(fa, id); n != 0 {
		t.Fatalf("the chaser despawned %d time(s) across a freeze; a freeze is not a seam", n)
	}
	c.StopChasers()
}

// TestChaserTapThinsTheAdapterFrameRate: the history is sized for 100 samples a second, so the tap hands the pack at
// most one sample per 10ms whatever the adapter's frame rate; 500 frames 2ms apart are written as about 100.
func TestChaserTapThinsTheAdapterFrameRate(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk
	c.ChaserEnabled = true
	c.ChaserDelay = 10 * time.Second // nothing falls due inside the test
	c.ChaserSpawnDelay = 50 * time.Millisecond
	if n := c.StartChasers(); n != 1 {
		t.Fatalf("StartChasers = %d, want 1", n)
	}
	defer c.StopChasers()
	for i := 0; i < 500; i++ {
		clk.Advance(2 * time.Millisecond)
		x := float64(i)
		c.recordLocal(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
	}
	c.chaserMu.Lock()
	hist := c.chaserHist
	c.chaserMu.Unlock()
	// What the tap wrote, not what is unread: that would also depend on how far the goroutine got.
	if got := hist.written(); got < 95 || got > 101 {
		t.Fatalf("the tap wrote %d samples after 500 frames 2ms apart; want ~100 (one per 10ms)", got)
	}
}

// TestChaserResetStartsThePackOver: chaser_reset drops the chaser now, and the fresh pack waits for the player to move
// again, so a pack following the trail through a respawn never lands on a player still standing there.
func TestChaserResetStartsThePackOver(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 100 * time.Millisecond
	c.ChaserSpawnDelay = 50 * time.Millisecond
	c.mu.Unlock()
	if n := c.StartChasers(); n != 1 {
		t.Fatalf("StartChasers = %d, want 1", n)
	}
	const id = "chaser:1"
	lastRender := func() int64 {
		fa.mu.Lock()
		defer fa.mu.Unlock()
		return fa.lastRenderTs[id]
	}
	despawns := func() int {
		fa.mu.Lock()
		defer fa.mu.Unlock()
		return fa.despawnCount[id]
	}
	start := time.Now()
	var x float64
	deadline := time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		x = float64(time.Since(start) / (10 * time.Millisecond))
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{x, 0}})
		time.Sleep(10 * time.Millisecond)
		if _, ok := fa.rendersOf(id); ok && x > 30 {
			break
		}
	}
	if _, ok := fa.rendersOf(id); !ok {
		t.Fatal("chaser never appeared")
	}
	before := despawns()

	env, _ := json.Marshal(bridge.Envelope{Type: bridge.TypeChaserReset, Payload: json.RawMessage("{}")})
	if err := fa.conn.Send(env); err != nil {
		t.Fatalf("send chaser_reset: %v", err)
	}
	held := x
	deadline = time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && despawns() == before {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{held, 0}})
		time.Sleep(10 * time.Millisecond)
	}
	if despawns() == before {
		t.Fatal("chaser_reset did not despawn the chaser")
	}
	// Four times the delay standing still: the fresh pack waits for movement, like a pack at the start of play.
	stamp := lastRender()
	until := time.Now().Add(400 * time.Millisecond)
	for time.Now().Before(until) {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{held, 0}})
		time.Sleep(10 * time.Millisecond)
	}
	if lastRender() != stamp {
		t.Fatal("the fresh pack rendered a chaser before the player moved again")
	}
	moveStart := time.Now()
	deadline = time.Now().Add(testTimeout)
	for time.Now().Before(deadline) && lastRender() == stamp {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{held + float64(time.Since(moveStart)/(10*time.Millisecond)), 0}})
		time.Sleep(10 * time.Millisecond)
	}
	if lastRender() == stamp {
		t.Fatal("no chaser came back after the player moved again")
	}
}

// TestChaserResetIsBoundedAndNeedsAPack: a reset with no pack starts nothing, and a second inside chaserResetMinGap is
// ignored, so an adapter sending one per frame cannot rebuild the history every frame.
func TestChaserResetIsBoundedAndNeedsAPack(t *testing.T) {
	c, _, _ := startLocalPeerCore(t)
	if n, ok := c.ResetChasers(); ok || n != 0 {
		t.Fatalf("ResetChasers with no pack = (%d, %v), want (0, false)", n, ok)
	}
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 100 * time.Millisecond
	c.mu.Unlock()
	if n := c.StartChasers(); n != 1 {
		t.Fatalf("StartChasers = %d, want 1", n)
	}
	if n, ok := c.ResetChasers(); !ok || n != 1 {
		t.Fatalf("first ResetChasers = (%d, %v), want (1, true)", n, ok)
	}
	if _, ok := c.ResetChasers(); ok {
		t.Fatal("a second ResetChasers inside chaserResetMinGap acted, want ignored")
	}
}
