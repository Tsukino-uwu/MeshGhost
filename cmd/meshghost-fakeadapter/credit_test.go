package main

// Where the right behaviour is silence (a duplicate, a stale generation), a test asserts no violation and an unmoved
// fold too. No t.Parallel(): the violation counter is process-wide.

import (
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// testCreditChecker builds a checker for "self" at scale 1000 that reports through the process-wide counter.
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

// reset advances an enemy to a generation, the only thing that makes it judgeable by invariant 13.
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

// fold returns this client's own fraction, the scale and whether its copy died, for one generation.
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
	// Ratchet first, then divide: once a harder client joins, the same damage is worth less.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "self", 0, 1, 250, 1000))
		c.onEvent(hit(t, 2, "peer", 0, 1, 250, 2000))
	})
	if got != 0 {
		t.Fatalf("legal reports produced %d violation(s), want 0", got)
	}
	frac, scale, _ := fold(t, c, 0)
	// 250/1000, then 250/2000 after the ratchet.
	if want := 0.375; frac != want {
		t.Fatalf("fraction = %v, want %v -- the ratchet must not re-value damage already dealt", frac, want)
	}
	if scale != 2000 {
		t.Fatalf("scale = %v, want 2000", scale)
	}
}

func TestCreditFoldIgnoresADuplicateReport(t *testing.T) {
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
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		// The reset is the one event proving this client was present when the fight began.
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
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		// No reset seen, and the first report is already at generation 4: it joined mid-fight.
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
	// A bystander that swings adopts the accumulated total: its copy snaps to where the fight is.
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
	// 0.4 + 0.4 while a bystander, plus its own 0.1.
	if frac, _, _ := fold(t, c, 0); frac != 0.9 {
		t.Fatalf("fraction = %v after joining, want 0.9 -- a late participant did not adopt the accumulated total", frac)
	}
}

func TestCreditIsNotAwardedForAKillThatLandedWhileDead(t *testing.T) {
	// Tag it once, die, get nothing: the copy still dies, with no reward.
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
	// Fabricated directly, because the fold refuses to produce it.
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
	// Fabricated directly, because the fold cannot produce it.
	c := testCreditChecker()
	got := withCleanViolationCount(func() {
		c.onEvent(hit(t, 1, "peer", 0, 1, 1000, 1000))
		c.mu.Lock()
		e := c.enc[encKey("enemy0", 0)]
		e.credited = true
		c.mu.Unlock()
		c.checkCredit()
	})
	// Two: no participation, and no death on this client's copy.
	if got != 2 {
		t.Fatalf("a reward without participation produced %d violation(s), want 2", got)
	}
}

func TestCreditResetIsIdempotentByGeneration(t *testing.T) {
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
	for _, gen := range []uint64{0, 1, 4096} {
		key, got := splitEncKey(encKey("enemy7", gen))
		if key != "enemy7" || got != gen {
			t.Fatalf("splitEncKey round trip = (%q, %d), want (\"enemy7\", %d)", key, got, gen)
		}
	}
}
