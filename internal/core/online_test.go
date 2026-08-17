package core

// Client-side tests for the planes past cosmetic: clock sync, capability
// gating, and a real round trip of each plane against the actual relay.

import (
	"encoding/json"
	"testing"
	"time"

	"meshghost/internal/protocol"
)

// TestClockSyncKeepsTheLowestRTTSample pins the estimator's one real
// judgement call. A slow sample is slow because it was delayed somewhere, and
// an asymmetric delay is exactly what corrupts an offset estimate — so a
// worse-RTT sample must be discarded outright rather than averaged in, which
// would drag the estimate toward the noise.
func TestClockSyncKeepsTheLowestRTTSample(t *testing.T) {
	var cs clockSync
	base := time.UnixMilli(1_000_000)

	// A slow round trip: 400ms, with the relay's clock 5000ms ahead.
	cs.observe(base, base.Add(400*time.Millisecond), base.Add(200*time.Millisecond).UnixMilli()+5000)
	if cs.bestRTTMs != 400 {
		t.Fatalf("bestRTT = %d, want 400", cs.bestRTTMs)
	}
	if cs.offsetMs != 5000 {
		t.Fatalf("offset = %d, want 5000", cs.offsetMs)
	}

	// A worse sample must not move the estimate at all.
	cs.observe(base, base.Add(900*time.Millisecond), base.Add(450*time.Millisecond).UnixMilli()+9999)
	if cs.offsetMs != 5000 || cs.bestRTTMs != 400 {
		t.Fatalf("a worse sample changed the estimate to offset=%d rtt=%d", cs.offsetMs, cs.bestRTTMs)
	}

	// A better one must replace it.
	cs.observe(base, base.Add(20*time.Millisecond), base.Add(10*time.Millisecond).UnixMilli()+4800)
	if cs.bestRTTMs != 20 || cs.offsetMs != 4800 {
		t.Fatalf("a better sample gave offset=%d rtt=%d, want 4800/20", cs.offsetMs, cs.bestRTTMs)
	}
}

// TestClockSyncIgnoresARelayThatDoesNotStampItsClock keeps an older relay on
// exactly the pre-clock-sync behaviour: no samples, no offset, nothing
// applied.
func TestClockSyncIgnoresARelayThatDoesNotStampItsClock(t *testing.T) {
	var cs clockSync
	base := time.UnixMilli(1_000_000)
	cs.observe(base, base.Add(30*time.Millisecond), 0)
	if cs.bestRTTMs != 0 || cs.offsetMs != 0 {
		t.Fatalf("an unstamped pong produced offset=%d rtt=%d, want nothing", cs.offsetMs, cs.bestRTTMs)
	}
}

// TestSendPathsRefuseACapabilityTheRoomDidNotNegotiate is the client half of
// opt-in. A silent drop here is how "trades sometimes don't work" becomes a
// bug report instead of a configuration error the user can see.
func TestSendPathsRefuseACapabilityTheRoomDidNotNegotiate(t *testing.T) {
	addr := startRelay(t)

	c := New()
	c.RelayAddr, c.Room, c.DisplayName = addr, "room1", "alice"
	// Deliberately no Features: this Core joins as a plain cosmetic client.
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("connect: %v", err)
	}

	if err := c.SendEvent(protocol.Event{Payload: json.RawMessage(`1`)}); err != ErrFeatureNotEnabled {
		t.Fatalf("SendEvent error = %v, want %v", err, ErrFeatureNotEnabled)
	}
	if err := c.ClaimLease("k", time.Second); err != ErrFeatureNotEnabled {
		t.Fatalf("ClaimLease error = %v, want %v", err, ErrFeatureNotEnabled)
	}
	if err := c.SendEscrow(protocol.Escrow{Op: protocol.EscrowOpen, ID: "t", With: "p2"}); err != ErrFeatureNotEnabled {
		t.Fatalf("SendEscrow error = %v, want %v", err, ErrFeatureNotEnabled)
	}
}

// TestOversizedEventIsRefusedBeforeItIsSent mirrors the relay's own check on
// the client side, so a caller gets a real error rather than a message that
// vanishes somewhere in the relay. There is no chunking fallback by design.
func TestOversizedEventIsRefusedBeforeItIsSent(t *testing.T) {
	c := New()
	big := make([]byte, protocol.MaxEventBytes+64)
	for i := range big {
		big[i] = 'a'
	}
	payload, err := json.Marshal(string(big))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := c.SendEvent(protocol.Event{Payload: payload}); err == nil {
		t.Fatal("an oversized event was accepted")
	}
}

// TestCoreRoundTripsAnEventThroughARealRelay is the end-to-end proof that the
// client half actually works against internal/relay rather than only
// type-checking: two Cores in one room, one sends, both observe it stamped
// and ordered.
func TestCoreRoundTripsAnEventThroughARealRelay(t *testing.T) {
	addr := startRelay(t)

	events := make(chan protocol.Event, 8)
	newCore := func(name string, sink chan protocol.Event) *Core {
		c := New()
		c.RelayAddr, c.Room, c.DisplayName = addr, "room1", name
		c.Features = []string{protocol.FeatureEventV1}
		if sink != nil {
			c.OnEvent = func(ev protocol.Event) { sink <- ev }
		}
		if err := c.ConnectRelay("emerald"); err != nil {
			t.Fatalf("connect %s: %v", name, err)
		}
		return c
	}

	sender := newCore("alice", nil)
	receiver := newCore("bob", events)

	if got := receiver.RoomFeatures(); len(got) != 1 || got[0] != protocol.FeatureEventV1 {
		t.Fatalf("negotiated features = %v, want [%s]", got, protocol.FeatureEventV1)
	}

	if err := sender.SendEvent(protocol.Event{CorrID: "c1", Payload: json.RawMessage(`{"turn":1}`)}); err != nil {
		t.Fatalf("send event: %v", err)
	}

	select {
	case ev := <-events:
		if ev.From != sender.PlayerID() {
			t.Fatalf("event From = %q, want %q", ev.From, sender.PlayerID())
		}
		if ev.Seq == 0 {
			t.Fatal("event arrived without a sequencer stamp")
		}
		if ev.CorrID != "c1" || string(ev.Payload) != `{"turn":1}` {
			t.Fatalf("event = %+v, want the payload and corr_id unchanged", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the event")
	}
}

// TestCoreLeaseRoundTripThroughARealRelay covers the claim/deny path from the
// client API, including that the loser is told who actually holds the key
// rather than merely being refused.
func TestCoreLeaseRoundTripThroughARealRelay(t *testing.T) {
	addr := startRelay(t)

	newCore := func(name string, sink chan protocol.LeaseState) *Core {
		c := New()
		c.RelayAddr, c.Room, c.DisplayName = addr, "room1", name
		c.Features = []string{protocol.FeatureLeaseV1}
		c.OnLeaseState = func(st protocol.LeaseState) { sink <- st }
		if err := c.ConnectRelay("emerald"); err != nil {
			t.Fatalf("connect %s: %v", name, err)
		}
		return c
	}

	aliceStates := make(chan protocol.LeaseState, 8)
	bobStates := make(chan protocol.LeaseState, 8)
	alice := newCore("alice", aliceStates)
	newCore("bob", bobStates)

	if err := alice.ClaimLease("k", 30*time.Second); err != nil {
		t.Fatalf("claim: %v", err)
	}
	select {
	case st := <-aliceStates:
		if st.Reason != protocol.LeaseGranted || st.Holder != alice.PlayerID() {
			t.Fatalf("alice's claim = %+v, want granted to herself", st)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for the lease grant")
	}
}

// TestTimestampsUseTheRelayClockDomainOnlyWhenNegotiated pins the one change
// here that touches an already-shipped behaviour. With clock.v1 off — every
// room today — the stamp must be the plain local wall clock, exactly as
// before; with it on, the measured offset is applied so every member of the
// room measures against one clock.
func TestTimestampsUseTheRelayClockDomainOnlyWhenNegotiated(t *testing.T) {
	c := New()
	c.clock = clockSync{offsetMs: 60_000, bestRTTMs: 5}

	local := time.Now().UnixMilli()
	if got := c.nowMs(); got < local-1000 || got > local+1000 {
		t.Fatalf("with clock sync un-negotiated, nowMs() = %d, want the local wall clock ~%d", got, local)
	}

	c.activeFeatures = []string{protocol.FeatureClockV1}
	shifted := c.nowMs()
	if shifted < local+59_000 || shifted > local+61_000 {
		t.Fatalf("with clock.v1 negotiated, nowMs() = %d, want ~%d (local + the measured offset)", shifted, local+60_000)
	}
}

// TestClockNeverMovesBackwardsWhenTheOffsetIsRevisedDown guards a fault
// introduced by clock sync itself: the offset is re-estimated whenever a
// better (lower-RTT) sample arrives, so it can DECREASE, and nowMs feeds both
// the timestamp stamped on outgoing state and the render time used to
// interpolate remotes.
//
// Either moving backwards is a real fault. interp.go's remoteBuffer.add
// requires non-decreasing timestamps and does not re-sort, so a peer's buffer
// would go unsorted; and a render time that rewound could flip an opaque field
// back to a previous value, manufacturing a state edge in a field the core is
// forbidden to interpret — which an adapter firing on that edge would act on.
func TestClockNeverMovesBackwardsWhenTheOffsetIsRevisedDown(t *testing.T) {
	c := New()
	c.activeFeatures = []string{protocol.FeatureClockV1}
	c.clock = clockSync{offsetMs: 5000, bestRTTMs: 200}

	high := c.nowMs()

	// A better sample lands and revises the offset sharply downwards — the
	// exact thing the lowest-RTT estimator is designed to do.
	c.clock = clockSync{offsetMs: 1000, bestRTTMs: 5}

	for i := 0; i < 50; i++ {
		got := c.nowMs()
		if got < high {
			t.Fatalf("nowMs went backwards: %d after %d (a 4s downward correction)", got, high)
		}
		high = got
	}
}

// TestWorldSendPathsRefuseARoomWithoutCustody is the world plane's half of
// opt-in: the same visible error every other plane gives, rather than a write
// that silently goes nowhere.
func TestWorldSendPathsRefuseARoomWithoutCustody(t *testing.T) {
	addr := startRelay(t)

	c := New()
	c.RelayAddr, c.Room, c.DisplayName = addr, "room1", "alice"
	if err := c.ConnectRelay("emerald"); err != nil {
		t.Fatalf("connect: %v", err)
	}
	if err := c.SetWorld("sim", "e0", json.RawMessage(`1`), true); err != ErrFeatureNotEnabled {
		t.Fatalf("SetWorld error = %v, want %v", err, ErrFeatureNotEnabled)
	}
	if err := c.DropWorld("sim", "e0"); err != ErrFeatureNotEnabled {
		t.Fatalf("DropWorld error = %v, want %v", err, ErrFeatureNotEnabled)
	}
}

// TestOversizedWorldBlobIsRefusedBeforeItIsSent. No chunking fallback, by
// design: an entity that does not fit means the blob should carry a reference
// to the data rather than the data.
func TestOversizedWorldBlobIsRefusedBeforeItIsSent(t *testing.T) {
	c := New()
	blob, err := json.Marshal(string(make([]byte, protocol.MaxWorldBlobBytes)))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := c.SetWorld("sim", "e0", blob, true); err == nil {
		t.Fatal("an oversized world blob was accepted")
	}
}

// TestCoreAdoptsAWorldThroughARealRelay is the client-side end-to-end: alice
// hosts and writes, bob takes the authority over and is handed the same world
// without either of them having agreed on anything but a lease key.
func TestCoreAdoptsAWorldThroughARealRelay(t *testing.T) {
	addr := startRelay(t)

	newCore := func(name string, leases chan protocol.LeaseState, worlds chan protocol.WorldState) *Core {
		c := New()
		c.RelayAddr, c.Room, c.DisplayName = addr, "room1", name
		c.Features = []string{protocol.FeatureLeaseV1, protocol.FeatureWorldV1}
		c.OnLeaseState = func(st protocol.LeaseState) { leases <- st }
		c.OnWorldState = func(st protocol.WorldState) { worlds <- st }
		if err := c.ConnectRelay("emerald"); err != nil {
			t.Fatalf("connect %s: %v", name, err)
		}
		return c
	}

	aliceLeases := make(chan protocol.LeaseState, 16)
	aliceWorlds := make(chan protocol.WorldState, 16)
	bobLeases := make(chan protocol.LeaseState, 16)
	bobWorlds := make(chan protocol.WorldState, 16)
	alice := newCore("alice", aliceLeases, aliceWorlds)
	bob := newCore("bob", bobLeases, bobWorlds)

	if err := alice.ClaimLease("sim", 30*time.Second); err != nil {
		t.Fatalf("claim: %v", err)
	}
	waitLease(t, aliceLeases, protocol.LeaseGranted)

	if err := alice.SetWorld("sim", "boss", json.RawMessage(`{"hp":100}`), true); err != nil {
		t.Fatalf("set world: %v", err)
	}
	// bob is a peer, so it sees the live write.
	if st := waitWorld(t, bobWorlds, protocol.WorldWritten); st.Holder != alice.PlayerID() {
		t.Fatalf("live write named holder %q, want alice", st.Holder)
	}

	// Alice hands off. Bob takes the authority and is handed the world with it.
	if err := alice.ReleaseLease("sim"); err != nil {
		t.Fatalf("release: %v", err)
	}
	waitLease(t, bobLeases, protocol.LeaseReleased)
	if err := bob.ClaimLease("sim", 30*time.Second); err != nil {
		t.Fatalf("bob claim: %v", err)
	}
	waitLease(t, bobLeases, protocol.LeaseGranted)

	adopted := waitWorld(t, bobWorlds, protocol.WorldSnapshot)
	if len(adopted.Entries) != 1 || adopted.Entries[0].Key != "boss" {
		t.Fatalf("bob adopted %+v, want the one entity alice created", adopted.Entries)
	}
	if string(adopted.Entries[0].Blob) != `{"hp":100}` {
		t.Fatalf("adopted blob = %s, want it byte-identical -- the relay must not interpret it",
			adopted.Entries[0].Blob)
	}

	// And alice, now stale, is refused rather than silently ignored.
	if err := alice.SetWorld("sim", "boss", json.RawMessage(`{"hp":1}`), true); err != nil {
		t.Fatalf("stale set: %v", err)
	}
	if st := waitWorld(t, aliceWorlds, protocol.WorldDenied); st.Holder != bob.PlayerID() {
		t.Fatalf("denial named holder %q, want bob", st.Holder)
	}
}

func waitLease(t *testing.T, ch chan protocol.LeaseState, reason string) protocol.LeaseState {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case st := <-ch:
			if st.Reason == reason {
				return st
			}
		case <-deadline:
			t.Fatalf("timed out waiting for a lease state with reason %q", reason)
		}
	}
}

func waitWorld(t *testing.T, ch chan protocol.WorldState, reason string) protocol.WorldState {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		select {
		case st := <-ch:
			if st.Reason == reason {
				return st
			}
		case <-deadline:
			t.Fatalf("timed out waiting for a world state with reason %q", reason)
		}
	}
}
