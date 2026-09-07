package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// TestChaserFollowsTheLocalPlayerBehindByItsDelay: with the player walking
// x = t/10ms and a 100ms delay, the chaser renders where the player was
// ~100ms ago, cosmetic, offline (no relay involved in the feed at all).
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

// TestChaserPackIsSpacedAndNumbered: three chasers with 50ms spacing are
// three peers at three different lags, named "Pack 1..3", never two on the
// same spot while the player moves; count clamps to the max.
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

	// No count cap (2026-09-06): 99 asked is 99 started. The old cap of 8 is
	// what a tester hit; this line fails if it ever comes back.
	c.mu.Lock()
	c.ChaserCount = 99
	c.mu.Unlock()
	if n := c.StartChasers(); n != 99 {
		t.Fatalf("count 99 started %d, want all 99 (no cap)", n)
	}
	c.StopChasers()
	// The one bound left is the roster itself: a count past every seat is
	// clamped to the roster's size rather than allocating that many queues.
	c.mu.Lock()
	c.ChaserCount = 1 << 20
	c.mu.Unlock()
	if n := c.StartChasers(); n != protocol.MaxRosterSize {
		t.Fatalf("count 1<<20 started %d, want the roster size %d", n, protocol.MaxRosterSize)
	}
	c.StopChasers()
}

// TestChaserSeamsOnALiveGapAndIsOffByDefault: 2s of silence (a menu) makes
// the chaser leave and reappear rather than glide; disabled means no peer.
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
	// Silence: nil frames for longer than the seam threshold. The chaser
	// ages out (3s) or seams (1.5s gap) -- either way it must be gone, then
	// come back with the next in-game frame.
	for i := 0; i < 8; i++ {
		fa.frame(nil)
		time.Sleep(200 * time.Millisecond)
	}
	// Back in the game, far from where the pack last saw the player. Keep
	// feeding frames out here: the pack follows the LIVE stream, so the
	// reappearance is wherever the player is now, never a glide from x=19.
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

// TestChaserPolicyIsPushedOnlyWhenContactIsOn: session_policy carries
// chaser_contact only when the config asks for it (and no shipped adapter
// honours it yet -- that is per game, ADR-gated).
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
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserContact = true
	c.mu.Unlock()
	c.pushSessionPolicy()
	select {
	case p := <-fa.policies:
		if p.ChaserContact != "enabled" {
			t.Fatalf("chaser_contact = %q, want enabled", p.ChaserContact)
		}
	case <-time.After(testTimeout):
		t.Fatal("no session_policy after turning contact on")
	}
}

// TestChaserNeverSpawnsOnAStandingPlayer (the user's rule, 2026-09-03): a
// player who stands still gets no chaser however long they wait; once they
// move, the chaser appears only after the spawn window and `delay` behind.
func TestChaserNeverSpawnsOnAStandingPlayer(t *testing.T) {
	c, _, fa := startLocalPeerCore(t)
	c.mu.Lock()
	c.ChaserEnabled = true
	c.ChaserDelay = 50 * time.Millisecond
	c.ChaserSpawnDelay = 200 * time.Millisecond
	c.mu.Unlock()
	c.StartChasers()
	const id = "chaser:1"
	// Standing still for well over delay + spawn: nothing may appear.
	for i := 0; i < 40; i++ {
		fa.frame(&protocol.State{AreaID: "a", Position: []float64{5, 5}})
		time.Sleep(10 * time.Millisecond)
	}
	if _, ok := fa.renderMsgOf(id); ok {
		t.Fatal("a chaser spawned on a player who never moved")
	}
	// Now move. The chaser may not appear before 200ms of movement.
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

// TestChaserPackClampsAnAbsurdSpacingFast (found by FuzzEverything, 2026-09-03):
// count 8 with spacing 48h must not size a channel to 336 hours of samples on
// the bridge goroutine. StartChasers returns at once and every chaser's delay
// is at most maxChaserBehind.
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

// TestChaserHistoryIsFlatInTheCount is the 1.69 GB regression (2026-09-07).
//
// A tester's 512-chaser pack at 1s delay/1s spacing allocated a private queue
// PER CHASER, each sized to that chaser's own delay: 13.2 million
// protocol.State slots, ~1.69 GB, taken on the bridge goroutine the moment the
// adapter attached and taken again on every reconnect. The pack shares one
// history now, so the deepest delay alone sizes it and adding chasers costs
// nothing. Asserted as "512 costs the same as 2 at the same depth", which is
// the property, rather than as a byte count, which would be a machine detail.
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
	// Same depth (the deepest chaser is 512s behind either way), 256x the
	// chasers. Under the old private queues the second number was ~256x the
	// first; now they are equal.
	deep := slotsFor(2, 511*time.Second)
	full := slotsFor(512, time.Second)
	if deep != full {
		t.Fatalf("2 chasers at depth 512s hold %d slots, 512 chasers at the same depth hold %d -- "+
			"the history must be sized by the deepest delay alone, not by the count", deep, full)
	}
	// And the absolute figure stays small: the whole 512-pack is one ring of
	// 514s at 100Hz. The old arrangement needed 13.2 million slots for this.
	if want := int((514 * time.Second).Milliseconds() / 10); full != want {
		t.Fatalf("512-pack history is %d slots, want %d", full, want)
	}
}

// TestChaserHistoryLapsIntoASeamRatherThanAHole: a reader that falls further
// behind than the history's slack loses its OLDEST unread samples and is told
// so, instead of the writer dropping the newest and punching an invisible hole
// into the middle of the trail (the 2026-09-05 despawn/respawn cycle).
func TestChaserHistoryLapsIntoASeamRatherThanAHole(t *testing.T) {
	h := newChaserHistory(4)
	for i := 0; i < 4; i++ {
		h.add(protocol.State{Timestamp: int64(i)})
	}
	if s, got, lapped, ok, _ := h.read(0); !ok || lapped || got != 0 || s.Timestamp != 0 {
		t.Fatalf("read(0) on an exactly-full history = (%v, %d, lapped %v, ok %v), want the oldest sample untouched",
			s.Timestamp, got, lapped, ok)
	}
	// Two more writes lap a reader still sitting at 0.
	h.add(protocol.State{Timestamp: 4})
	h.add(protocol.State{Timestamp: 5})
	s, got, lapped, ok, _ := h.read(0)
	if !ok || !lapped {
		t.Fatalf("read(0) after the ring wrapped = (lapped %v, ok %v), want a lapped read", lapped, ok)
	}
	if got != 2 || s.Timestamp != 2 {
		t.Fatalf("lapped read resumed at index %d (ts %d), want the oldest surviving sample, index 2", got, s.Timestamp)
	}
	// The NEWEST sample is always present: that is the direction that matters.
	if s, _, _, ok, _ := h.read(5); !ok || s.Timestamp != 5 {
		t.Fatalf("newest sample missing after a wrap: ok %v ts %d", ok, s.Timestamp)
	}
}

// TestChaserHistoryWakesAWaiterWithoutLosingIt covers the lost-wakeup the
// one-lock read() exists to prevent: a reader that finds nothing must get a
// channel that a write landing immediately afterwards still closes.
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

// TestChaserHoldsWhileThePlayerIsFrozen (ADR 0053): while the adapter says the
// player is frozen -- a pickup popup, the pause menu -- the chaser stops where
// it is instead of spending the pause converging onto a player who cannot
// move, and once play resumes it follows again the same distance behind, with
// no seam. Measured live 2026-09-04: a 110-second popup left the chaser inside
// the player, which is what blocks chaser_contact. Without the fix the chaser
// walks the whole gap during the freeze and the first assertion fails.
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
	// Move until the chaser is on screen and behind.
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
	// FREEZE: the pawn holds still for 400ms (four times the delay) while the
	// adapter keeps sending the same frame, as a real freeze does.
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
	// One 50ms sleep slice of samples may still land after the message; any
	// more than that means the clock kept running.
	if at.Position[0] > atFreeze+6 {
		t.Fatalf("chaser advanced from %v to %v during a freeze (player held at %v); it should hold", atFreeze, at.Position[0], held)
	}
	if at.Position[0] >= held-2 {
		t.Fatalf("chaser converged onto the frozen player: at %v, player at %v", at.Position[0], held)
	}
	// RESUME from where the player stood: the chaser follows again, about a
	// delay behind, and was never despawned (a 400ms freeze is under the seam
	// threshold on the wall clock, and no gap at all on the gameplay clock).
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

// TestChaserTapThinsTheAdapterFrameRate (2026-09-05): a chaser's queue is
// sized for 100 samples a second of its delay, and an adapter that sends one
// sample per frame at ~180fps filled it -- a full queue drops the NEWEST
// samples until the oldest fall due, cutting a hole longer than the seam
// threshold into every chaser more than ~6s behind, which then despawned and
// respawned on the player with a period of delay+spawn (watched live, read off
// the log). The tap now hands the pack at most one sample per 10ms. Driven on
// the fake clock: 500 frames 2ms apart must reach the chaser as ~100, not 500.
// Without the thinning this counts 500 and fails.
func TestChaserTapThinsTheAdapterFrameRate(t *testing.T) {
	clk := newFakeClock()
	c := New()
	c.timeSrc = clk
	c.ChaserEnabled = true
	c.ChaserDelay = 10 * time.Second // nothing falls due inside the test
	// A short spawn window: the goroutine DRAINS the queue until the player has
	// moved for this long (samples before that are skipped, not delayed), then
	// blocks on the first due sample and everything after it queues up.
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
	// 500 frames over 1s at 2ms: one sample per 10ms is 100. Asserted on what
	// the tap WROTE rather than on what is still unread -- the shared history
	// never drains, so the written count is the thinning itself rather than a
	// figure that also depends on how far the goroutine happened to get.
	if got := hist.written(); got < 95 || got > 101 {
		t.Fatalf("the tap wrote %d samples after 500 frames 2ms apart; want ~100 (one per 10ms)", got)
	}
}
