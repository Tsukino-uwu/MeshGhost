package main

import "testing"

func TestSummarizeCountsWinsHitsAndMedian(t *testing.T) {
	tries := []try{
		{Won: true, Seconds: 120, Hits: 0},
		{Won: true, Seconds: 100, Hits: 2, HitList: []hit{{BulletType: "NORMAL"}, {Source: "Ribauld"}}},
		{Won: false, Seconds: 80, Hits: 1, HitList: []hit{{}}},
		{Won: true, Seconds: 140, Hits: 0},
	}
	s := summarize("x", setFlags{}, tries)
	if s.Tries != 4 || s.Wins != 3 || s.Hits != 3 || s.HitlessWins != 2 {
		t.Fatalf("summary %+v", s)
	}
	if s.MedianWinSecs != 120 {
		t.Fatalf("median of 100, 120, 140 = %v, want 120 (a loss's time is never a win's)", s.MedianWinSecs)
	}
	if s.HitsBy["NORMAL"] != 1 || s.HitsBy["Ribauld"] != 1 || s.HitsBy["unknown"] != 1 {
		t.Fatalf("hits_by %v", s.HitsBy)
	}
}

func TestMedianOfEvenAndEmpty(t *testing.T) {
	if m := median([]float64{4, 1, 3, 2}); m != 2.5 {
		t.Fatalf("median = %v", m)
	}
	if m := median(nil); m != 0 {
		t.Fatalf("median of none = %v", m)
	}
}

func TestHitOfReadsDamageTaken(t *testing.T) {
	h, ok := hitOf(map[string]any{"kind": "damage_taken", "damage": 52.0, "bullet_type": "ENERGYBALL_EXPLODE", "source": map[string]any{"type": "EnergyBall"}})
	if !ok || h.Damage != 52 || h.BulletType != "ENERGYBALL_EXPLODE" || h.Source != "EnergyBall" {
		t.Fatalf("hit %+v ok %v", h, ok)
	}
	if _, ok := hitOf(map[string]any{"kind": "hp_changed", "damage": 3.0}); ok {
		t.Fatal("hp_changed read as a hit: a hit reports both, so it would count twice")
	}
}

func TestApplySetsMergesIntoFightArgs(t *testing.T) {
	c := call{Name: "reflex", Arguments: map[string]any{"kind": "fight", "args": map[string]any{"type": "Ribauld"}}}
	sets := setFlags{}
	for _, v := range []string{"hug=5", "orb_mode=active", "tell_filter=true"} {
		if err := sets.Set(v); err != nil {
			t.Fatal(err)
		}
	}
	applySets(&c, sets)
	args := c.Arguments["args"].(map[string]any)
	if args["type"] != "Ribauld" || args["hug"] != 5.0 || args["orb_mode"] != "active" || args["tell_filter"] != true {
		t.Fatalf("args %v", args)
	}
	if err := sets.Set("novalue"); err == nil {
		t.Fatal("-set without = accepted")
	}
}

func TestModeOfReadsAfter(t *testing.T) {
	if m := modeOf(map[string]any{"after": map[string]any{"mode": "play"}}); m != "play" {
		t.Fatalf("mode %q", m)
	}
	if m := modeOf(nil); m != "" {
		t.Fatalf("mode of nothing %q", m)
	}
}
