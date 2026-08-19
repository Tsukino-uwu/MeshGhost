package main

// Tests for the kill-credit checker, continuing controlplane_test.go's rule:
// **a checker with no test of its own passes forever**, including on every run
// where the thing it was watching was broken.
//
// These are also the only place the model in agent_docs/kill-credit.md is
// executable. Its claims — a duplicate cannot double-count, a ratchet cannot
// resurrect, a stale report cannot touch a fresh generation, two participants
// cannot disagree about when something died — are arithmetic over an ordered
// stream, so they can be settled here rather than by watching a game. That is
// the whole reason the rig exists.
//
// Two shapes are used, and the difference matters. Where the correct behaviour
// is a *violation report*, the test asserts exactly one. Where the correct
// behaviour is to *silently do nothing* (a duplicate, a stale generation), the
// test asserts zero violations AND that the fold did not move — because an
// implementation that reported the problem and then applied it anyway would
// pass a violation-count check while being exactly as wrong.
//
// No t.Parallel(): the violation counter is process-wide and bracketed.

import (
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// testCreditChecker builds a checker belonging to "self" at scale 1000,
// reporting through the package-level counter so withCleanViolationCount sees
// it.
func testCreditChecker() *creditChecker {
	return newCreditChecker(creditConfig{on: true, enemies: 1}, "self", 1000, reportViolation)
}

// hit is one damage report from a dealer, at a relay stamp.
func hit(t *testing.T, seq uint64, from string, gen, dseq uint64, amt, scale float64) protocol.Event {
	t.Helper()
	return creditEvent(t, seq, from, creditMsg{
		Op: creditHit, Key: "enemy0", Gen: gen, DealerSeq: dseq, Amt: amt, Scale: scale,
	})
}

// reset advances an enemy to a generation, which is also the only thing that
// makes that generation judgeable by invariant 13.
func reset(t *testing.T, seq uint64, from string, gen uint64) protocol.Event {
	t.Helper()
	return creditEvent(t, seq, from, creditMsg{Op: creditReset, Key: "enemy0", Gen: gen})
}

func creditEvent(t *testing.T, seq uint64, from string, msg creditMsg) protocol.Event {
	t.Helper()
	payload, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal report: %v", err)
	}
	return protocol.Event{From: from, Seq: seq, Payload: payload}
}

// fold returns the checker's accumulated fraction and scale for one generation,
// which is what most of these tests actually assert on.
func fold(t *testing.T, c *creditChecker, gen uint64) (float64, float64, bool) {
	t.Helper()
	c.mu.Lock()
	defer c.mu.Unlock()
	e := c.enc[encKey("enemy0", gen)]
	if e == nil {
		t.Fatalf("no fold for generation %d", gen)
	}
	return e.frac, e.scale, e.dead
}

func TestCreditFoldValuesAHitAgainstTheScaleInForce(t *testing.T) {
	// The core arithmetic of the whole design: ratchet first, then divide. The
	// opener's hit is worth its share of the fight it was actually fighting;
	// once a harder client joins, the same absolute damage is worth less.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 250, 1000))
		c.onEvent(hit(t, 2, "peer", 0, 1, 250, 2000))
	})
	if got != 0 {
		t.Fatalf("legal reports produced %d violation(s), want 0", got)
	}
	frac, scale, _ := fold(t, c, 0)
	// 250/1000 = 0.25 at the opening scale, then the ratchet to 2000 makes the
	// second 250 worth 0.125.
	if want := 0.375; frac != want {
		t.Fatalf("fraction = %v, want %v -- the ratchet must not re-value damage already dealt", frac, want)
	}
	if scale != 2000 {
		t.Fatalf("scale = %v, want 2000", scale)
	}
}

func TestCreditFoldIgnoresADuplicateReport(t *testing.T) {
	// Invariant 9. The correct behaviour is silence, so asserting zero
	// violations is not enough on its own: the fold must not have moved.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 500, 1000))
		c.onEvent(hit(t, 2, "self", 0, 1, 500, 1000)) // same dealer, same dealer seq
	})
	if got != 0 {
		t.Fatalf("a duplicate produced %d violation(s), want 0 -- duplicates are normal", got)
	}
	frac, _, dead := fold(t, c, 0)
	if want := 0.5; frac != want {
		t.Fatalf("fraction = %v, want %v -- the duplicate was applied twice", frac, want)
	}
	if dead {
		t.Fatal("the copy died from a double-counted duplicate")
	}
}

func TestCreditFoldNeverLowersTheScale(t *testing.T) {
	// Invariant 10. A lower-scale report arriving after a higher one must not
	// pull the encounter back down -- the user's "don't scale it downwards",
	// which has to hold across arrival order.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 100, 3000))
		c.onEvent(hit(t, 2, "peer", 0, 1, 100, 1000))
	})
	if got != 0 {
		t.Fatalf("legal reports produced %d violation(s), want 0", got)
	}
	if _, scale, _ := fold(t, c, 0); scale != 3000 {
		t.Fatalf("scale = %v, want 3000 -- a lower report lowered the ratchet", scale)
	}
}

func TestCreditFoldDoesNotResurrectADeadCopy(t *testing.T) {
	// Invariant 11. Once dead, a later report -- including one that ratchets
	// the maximum way up -- changes nothing.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 1000, 1000)) // exactly lethal
		c.onEvent(hit(t, 2, "peer", 0, 1, 10, 9000))   // a big ratchet, after death
	})
	if got != 0 {
		t.Fatalf("legal reports produced %d violation(s), want 0", got)
	}
	frac, _, dead := fold(t, c, 0)
	if !dead {
		t.Fatal("the copy did not die on a lethal report")
	}
	if frac < 1 {
		t.Fatalf("fraction = %v after death, want >= 1 -- the ratchet lifted a dead copy off zero", frac)
	}
}

func TestCreditFoldDiscardsAReportFromAnOlderGeneration(t *testing.T) {
	// Invariant 12, and the case it exists for: a report in flight across a
	// reset. Discarding is correct behaviour, so this asserts silence plus an
	// untouched fold, not a violation.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 100, 1000))
		c.onEvent(creditEvent(t, 2, "peer", creditMsg{Op: creditReset, Key: "enemy0", Gen: 1}))
		c.onEvent(hit(t, 3, "peer", 0, 2, 900, 1000)) // stale: still aimed at gen 0
	})
	if got != 0 {
		t.Fatalf("a stale report produced %d violation(s), want 0 -- it is discarded, not complained about", got)
	}
	if frac, _, _ := fold(t, c, 0); frac != 0.1 {
		t.Fatalf("generation 0 fraction = %v, want 0.1 -- a stale report was applied", frac)
	}
	if frac, _, _ := fold(t, c, 1); frac != 0 {
		t.Fatalf("generation 1 fraction = %v, want 0 -- a stale report leaked into the fresh enemy", frac)
	}
	if c.stale.Load() != 1 {
		t.Fatalf("stale count = %d, want 1", c.stale.Load())
	}
}

func TestCreditFoldCatchesAGenerationAheadOfItsReset(t *testing.T) {
	// The other half of invariant 12. Adopting this silently would let one
	// confused client drag the whole room's generation forward.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 100, 1000))
		c.onEvent(hit(t, 2, "peer", 7, 1, 100, 1000))
	})
	if got != 1 {
		t.Fatalf("a generation ahead of its reset produced %d violation(s), want 1", got)
	}
}

func TestCreditCheckerAcceptsAnAgreedDeath(t *testing.T) {
	// Invariant 13's healthy case. Both participants folded the same ordered
	// ledger, so both crossed zero on the same stamp.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		// The reset is what makes this generation judgeable at all: it is the
		// one event proving this client was present when the fight began.
		c.onEvent(reset(t, 1, "peer", 1))
		c.onEvent(hit(t, 2, "self", 1, 1, 400, 1000))
		c.onEvent(hit(t, 3, "peer", 1, 1, 600, 1000))
		frac, _, dead := fold(t, c, 1)
		if !dead {
			t.Fatalf("the copy did not die at fraction %v", frac)
		}
		c.onEvent(creditEvent(t, 4, "peer", creditMsg{
			Op: creditDeath, Key: "enemy0", Gen: 1, At: 3, Frac: frac,
		}))
	})
	if got != 0 {
		t.Fatalf("an agreed death produced %d violation(s), want 0", got)
	}
	if c.agreedOn.Load() != 1 {
		t.Fatalf("agreed count = %d, want 1", c.agreedOn.Load())
	}
}

func TestCreditCheckerCatchesADisagreementAboutWhenItDied(t *testing.T) {
	// Invariant 13, and the most valuable check in the file: this is what a
	// naive absolute-damage ledger breaks the instant two clients disagree
	// about maximum health.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(reset(t, 1, "peer", 1))
		c.onEvent(hit(t, 2, "self", 1, 1, 400, 1000))
		c.onEvent(hit(t, 3, "peer", 1, 1, 600, 1000))
		c.onEvent(creditEvent(t, 4, "peer", creditMsg{
			Op: creditDeath, Key: "enemy0", Gen: 1, At: 99, Frac: 1,
		}))
	})
	if got != 1 {
		t.Fatalf("a disagreed death stamp produced %d violation(s), want 1", got)
	}
}

func TestCreditCheckerCatchesADisagreementAboutTheTotalDealt(t *testing.T) {
	// Same stamp, different total. Rarer and worse: it means the fold is
	// order-dependent somewhere it must not be.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(reset(t, 1, "peer", 1))
		c.onEvent(hit(t, 2, "self", 1, 1, 400, 1000))
		c.onEvent(hit(t, 3, "peer", 1, 1, 600, 1000))
		c.onEvent(creditEvent(t, 4, "peer", creditMsg{
			Op: creditDeath, Key: "enemy0", Gen: 1, At: 3, Frac: 1.75,
		}))
	})
	if got != 1 {
		t.Fatalf("a disagreed total produced %d violation(s), want 1", got)
	}
}

func TestCreditCheckerDoesNotJudgeAGenerationItJoinedLate(t *testing.T) {
	// A client that joined mid-fight folded a shorter prefix, so its total is
	// legitimately different and it must decline to judge. This is the mistake
	// world.go's checker made on its first soak -- a checker that cries wolf
	// gets switched off, which costs as much as one that never notices.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		// No reset seen, and the first report this client ever sees is already
		// at generation 4: it joined mid-fight.
		c.onEvent(hit(t, 10, "self", 4, 1, 1000, 1000))
		c.onEvent(creditEvent(t, 11, "peer", creditMsg{
			Op: creditDeath, Key: "enemy0", Gen: 4, At: 3, Frac: 1,
		}))
	})
	if got != 0 {
		t.Fatalf("a late joiner judged a fight it did not watch: %d violation(s), want 0", got)
	}
}

func TestCreditOnlyAResetProvesAGenerationWasWatchedFromItsStart(t *testing.T) {
	// The rule behind the two tests above, pinned on its own because it is the
	// easy thing to "simplify" later: an encounter created by a HIT is one this
	// client may have joined at any point, even when that hit is the first
	// thing it ever heard about the enemy. Only a reset proves presence.
	byHit := testCreditChecker()
	byHit.onEvent(hit(t, 1, "self", 0, 1, 100, 1000))
	byReset := testCreditChecker()
	byReset.onEvent(reset(t, 1, "peer", 1))

	byHit.mu.Lock()
	defer byHit.mu.Unlock()
	byReset.mu.Lock()
	defer byReset.mu.Unlock()
	if byHit.enc[encKey("enemy0", 0)].sawStart {
		t.Fatal("an encounter created by a hit claimed it watched the fight from the start")
	}
	if !byReset.enc[encKey("enemy0", 1)].sawStart {
		t.Fatal("an encounter created by a reset did not count as watched from the start")
	}
}

func TestCreditNonParticipantNeverTakesDamageOrDies(t *testing.T) {
	// Invariants 14 and 16 together, in their normal form. This client watches
	// a whole fight go by without ever swinging: it tracks the ledger, its own
	// copy is untouched, and it earns nothing.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		for i := uint64(1); i <= 5; i++ {
			c.onEvent(hit(t, i, "peer", 0, i, 400, 1000))
		}
		c.checkCredit()
	})
	if got != 0 {
		t.Fatalf("a bystander produced %d violation(s), want 0", got)
	}
	frac, _, dead := fold(t, c, 0)
	if frac != 0 {
		t.Fatalf("bystander fraction = %v, want 0 -- a non-participant applied the ledger", frac)
	}
	if dead {
		t.Fatal("a non-participant's copy died -- it never joined the fight")
	}
	if c.rewards.Load() != 0 {
		t.Fatalf("rewards = %d, want 0", c.rewards.Load())
	}
}

func TestCreditParticipantCatchesUpOnJoiningMidFight(t *testing.T) {
	// The documented discontinuity: a bystander that finally swings adopts the
	// accumulated total, so its copy snaps to wherever the fight actually is
	// rather than starting fresh. Named in kill-credit.md as a real visible
	// cost, and asserted here so it cannot quietly become something else.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "peer", 0, 1, 400, 1000))
		c.onEvent(hit(t, 2, "peer", 0, 2, 400, 1000))
		if frac, _, _ := fold(t, c, 0); frac != 0 {
			t.Fatalf("fraction = %v before joining, want 0", frac)
		}
		c.onEvent(hit(t, 3, "self", 0, 1, 100, 1000))
	})
	if got != 0 {
		t.Fatalf("joining mid-fight produced %d violation(s), want 0", got)
	}
	// 0.4 + 0.4 accumulated while a bystander, plus this client's own 0.1.
	if frac, _, _ := fold(t, c, 0); frac != 0.9 {
		t.Fatalf("fraction = %v after joining, want 0.9 -- a late participant did not adopt the accumulated total", frac)
	}
}

func TestCreditIsNotAwardedForAKillThatLandedWhileDead(t *testing.T) {
	// Invariant 15, and the user's own edge case: tag it once, die, get
	// nothing. The kill still happens -- the copy dies -- but no reward.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 100, 1000))
		c.setAlive(false)
		c.onEvent(hit(t, 2, "peer", 0, 1, 900, 1000))
		c.checkCredit()
	})
	if got != 0 {
		t.Fatalf("dying before the kill produced %d violation(s), want 0 -- it is a rule, not a defect", got)
	}
	if _, _, dead := fold(t, c, 0); !dead {
		t.Fatal("the copy did not die -- the fight still resolves for a dead participant")
	}
	if c.rewards.Load() != 0 {
		t.Fatalf("rewards = %d, want 0 -- a dead participant was rewarded", c.rewards.Load())
	}
}

func TestCreditCheckerCatchesARewardTakenWhileDead(t *testing.T) {
	// The same rule from the other side: if the reward is ever handed out
	// anyway, the end-of-run check must say so. Fabricated directly, because
	// the fold above correctly refuses to produce it.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 1000, 1000))
		c.mu.Lock()
		c.enc[encKey("enemy0", 0)].diedWhileDown = true
		c.mu.Unlock()
		c.checkCredit()
	})
	if got != 1 {
		t.Fatalf("a reward taken while dead produced %d violation(s), want 1", got)
	}
}

func TestCreditCheckerCatchesARewardWithoutParticipation(t *testing.T) {
	// Invariant 14 as an assertion rather than as normal behaviour: the fold
	// cannot produce this, so it is fabricated. The check exists because a
	// refactor that moved the participation gate would otherwise hand out
	// rewards in silence.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "peer", 0, 1, 1000, 1000))
		c.mu.Lock()
		e := c.enc[encKey("enemy0", 0)]
		e.credited = true
		c.mu.Unlock()
		c.checkCredit()
	})
	// Two: rewarded without participating, and rewarded for something that
	// never died on this client's copy. Both are true of a fabricated reward.
	if got != 2 {
		t.Fatalf("a reward without participation produced %d violation(s), want 2", got)
	}
}

func TestCreditResetIsIdempotentByGeneration(t *testing.T) {
	// Any client may issue a reset without coordinating, because two clients
	// resetting from the same generation name the same successor and the
	// second is a no-op. Without that this rig would need an elected resetter,
	// which is a mechanism the design does not have and should not grow.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 100, 1000))
		c.onEvent(creditEvent(t, 2, "peerA", creditMsg{Op: creditReset, Key: "enemy0", Gen: 1}))
		c.onEvent(creditEvent(t, 3, "peerB", creditMsg{Op: creditReset, Key: "enemy0", Gen: 1}))
	})
	if got != 0 {
		t.Fatalf("a duplicate reset produced %d violation(s), want 0", got)
	}
	if c.resets.Load() != 1 {
		t.Fatalf("resets = %d, want 1 -- the second reset was not idempotent", c.resets.Load())
	}
}

func TestCreditCheckerIgnoresSomeoneElsesEvents(t *testing.T) {
	// The credit plane shares the event plane with controlplane.go's own
	// chatter, so anything unparseable is another feature's traffic rather
	// than a defect.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(protocol.Event{From: "peer", Seq: 1, Payload: json.RawMessage(`{"hello":"world"}`)})
		c.onEvent(protocol.Event{From: "peer", Seq: 2, Payload: json.RawMessage(`not json at all`)})
	})
	if got != 0 {
		t.Fatalf("foreign events produced %d violation(s), want 0", got)
	}
}

func TestSplitEncKeyRoundTrips(t *testing.T) {
	// deathToAnnounce reconstructs the enemy key and generation from a map key,
	// and getting that wrong would announce deaths for the wrong generation --
	// which invariant 13 would then report against a healthy relay.
	for _, gen := range []uint64{0, 1, 4096} {
		key, got := splitEncKey(encKey("enemy7", gen))
		if key != "enemy7" || got != gen {
			t.Fatalf("splitEncKey round trip = (%q, %d), want (\"enemy7\", %d)", key, got, gen)
		}
	}
}
