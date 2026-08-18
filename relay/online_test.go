package relay

// Tests for everything past the cosmetic state plane: the event plane, the
// room sequencer, leases, escrow, feature negotiation, late-join snapshots
// and session resumption.
//
// The concurrency tests here are the point of the file, not decoration.
// agent_docs/testing.md's durable lesson is that a test asserting an
// invariant under concurrent clients found a relay race locally in 100 runs
// once written, where the race detector had only caught it by accident and in
// a misleading place — and full online is almost entirely concurrency bugs.
// So the invariants (exactly one lease holder, one identical total order for
// every member, both-or-neither on an exchange) are asserted against many
// clients racing, not against a tidy two-client sequence.

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// allFeatures is the full opt-in set, for tests that want every capability on.
var allFeatures = []string{
	protocol.FeatureEventV1,
	protocol.FeatureLeaseV1,
	protocol.FeatureEscrowV1,
	protocol.FeatureSnapshotV1,
	protocol.FeatureResumeV1,
}

func dialFeatureClient(t *testing.T, addr, room, name string, features []string) *testClient {
	t.Helper()
	return dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            room,
		DisplayName:     name,
		Features:        features,
	})
}

func (tc *testClient) send(t protocol.MessageType, payload any) {
	tc.t.Helper()
	b, err := json.Marshal(payload)
	if err != nil {
		tc.t.Fatalf("marshal %s: %v", t, err)
	}
	env, err := json.Marshal(protocol.Envelope{Type: t, Payload: b})
	if err != nil {
		tc.t.Fatalf("marshal envelope: %v", err)
	}
	if err := tc.conn.Send(env); err != nil {
		tc.t.Fatalf("send %s: %v", t, err)
	}
}

// nextOfType drains messages until one of the wanted type arrives, so a test
// asserting on (say) a LeaseState is not derailed by an unrelated Join. Fails
// the test on timeout rather than returning a zero value.
func (tc *testClient) nextOfType(want protocol.MessageType, timeout time.Duration) protocol.Envelope {
	tc.t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case env := <-tc.envs:
			if env.Type == want {
				return env
			}
		case <-deadline:
			tc.t.Fatalf("timed out waiting for a %q message", want)
			return protocol.Envelope{}
		}
	}
}

func (tc *testClient) expectLeaseState(timeout time.Duration) protocol.LeaseState {
	tc.t.Helper()
	var st protocol.LeaseState
	if err := json.Unmarshal(tc.nextOfType(protocol.TypeLeaseState, timeout).Payload, &st); err != nil {
		tc.t.Fatalf("unmarshal lease_state: %v", err)
	}
	return st
}

func (tc *testClient) expectEscrowState(timeout time.Duration) protocol.EscrowState {
	tc.t.Helper()
	var st protocol.EscrowState
	if err := json.Unmarshal(tc.nextOfType(protocol.TypeEscrowState, timeout).Payload, &st); err != nil {
		tc.t.Fatalf("unmarshal escrow_state: %v", err)
	}
	return st
}

func (tc *testClient) expectEvent(timeout time.Duration) protocol.Event {
	tc.t.Helper()
	var ev protocol.Event
	if err := json.Unmarshal(tc.nextOfType(protocol.TypeEvent, timeout).Payload, &ev); err != nil {
		tc.t.Fatalf("unmarshal event: %v", err)
	}
	return ev
}

// expectNothingOfType asserts no message of that type arrives within the
// window — the shape most of the negative assertions here need (an event that
// must not reach a third party, a leave that must not be broadcast).
func (tc *testClient) expectNothingOfType(unwanted protocol.MessageType, window time.Duration) {
	tc.t.Helper()
	deadline := time.After(window)
	for {
		select {
		case env := <-tc.envs:
			if env.Type == unwanted {
				tc.t.Fatalf("received an unwanted %q message", unwanted)
			}
		case <-deadline:
			return
		}
	}
}

// ---------------------------------------------------------------------------
// Feature negotiation
// ---------------------------------------------------------------------------

// TestRoomFeatureSetIsStickyAndMismatchIsRefused is the hazard
// agent_docs/beyond-cosmetic.md §3 names: one client advertising lease.v1 and
// claiming properly while another does not and simply acts means conflict
// resolution silently does not work, and everything looks fine until it
// doesn't. Refusing at the handshake is what turns that into a legible
// failure.
func TestRoomFeatureSetIsStickyAndMismatchIsRefused(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureLeaseV1})
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	if len(w1.Features) != 1 || w1.Features[0] != protocol.FeatureLeaseV1 {
		t.Fatalf("welcome features = %v, want [%s]", w1.Features, protocol.FeatureLeaseV1)
	}

	// A client advertising nothing must be refused, not quietly admitted:
	// "declared nothing" is a real value that has to match, unlike an
	// undeclared game_version.
	c2 := dialFeatureClient(t, addr, "room1", "bob", nil)
	defer c2.conn.Close()
	env := c2.next(timeout)
	if env.Type != protocol.TypeReject {
		t.Fatalf("cosmetic client got %q joining a lease room, want a reject", env.Type)
	}
	var rej protocol.Reject
	if err := json.Unmarshal(env.Payload, &rej); err != nil {
		t.Fatalf("unmarshal reject: %v", err)
	}
	if rej.Reason != protocol.ReasonFeatureMismatch {
		t.Fatalf("reject reason = %q, want %q", rej.Reason, protocol.ReasonFeatureMismatch)
	}
}

// TestFeatureSetMatchesRegardlessOfOrderOrDuplicates confirms the stickiness
// check compares capability SETS, not the literal arrays. Two clients built
// from different config files should not fail to share a room because one
// listed its features in a different order.
func TestFeatureSetMatchesRegardlessOfOrderOrDuplicates(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice",
		[]string{protocol.FeatureLeaseV1, protocol.FeatureEventV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	c2 := dialFeatureClient(t, addr, "room1", "bob",
		[]string{protocol.FeatureEventV1, protocol.FeatureLeaseV1, protocol.FeatureEventV1})
	defer c2.conn.Close()
	if w := c2.expectWelcome(timeout); w.PlayerID == "" {
		t.Fatal("second client was not admitted despite an identical feature set")
	}
}

// TestEventDroppedWhenRoomDidNotNegotiateIt is the other half of opt-in: a
// capability the room never agreed on must not run at all, which is what lets
// the relay stay free of any per-game table.
func TestEventDroppedWhenRoomDidNotNegotiateIt(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureLeaseV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	c1.send(protocol.TypeEvent, protocol.Event{Payload: json.RawMessage(`{"hi":1}`)})
	c1.expectNothingOfType(protocol.TypeEvent, 300*time.Millisecond)
}

// ---------------------------------------------------------------------------
// Event plane
// ---------------------------------------------------------------------------

// TestEventBroadcastReachesEveryoneIncludingSender covers the echo, which is
// not a convenience: the sequencer stamp is the relay's, so the sender has no
// other way to learn where its own action landed in the total order.
func TestEventBroadcastReachesEveryoneIncludingSender(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEventV1})
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureEventV1})
	defer c2.conn.Close()
	c2.expectWelcome(timeout)

	// From is deliberately a lie here — the relay must overwrite it with the
	// connection's own assigned id, exactly as it does for State.PlayerID.
	c1.send(protocol.TypeEvent, protocol.Event{
		From:    "somebody-else",
		CorrID:  "req-1",
		Payload: json.RawMessage(`{"offer":"x"}`),
	})

	for _, tc := range []*testClient{c1, c2} {
		ev := tc.expectEvent(timeout)
		if ev.From != w1.PlayerID {
			t.Fatalf("event From = %q, want the sender's assigned id %q", ev.From, w1.PlayerID)
		}
		if ev.Seq == 0 {
			t.Fatal("event carried no sequencer stamp")
		}
		if ev.CorrID != "req-1" {
			t.Fatalf("corr_id = %q, want it echoed unchanged", ev.CorrID)
		}
	}
}

// TestAddressedEventReachesOnlyTheAddresseeAndSender confirms `to` actually
// routes rather than broadcasting — the one field of an event the relay reads.
func TestAddressedEventReachesOnlyTheAddresseeAndSender(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEventV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureEventV1})
	defer c2.conn.Close()
	w2 := c2.expectWelcome(timeout)
	c3 := dialFeatureClient(t, addr, "room1", "carol", []string{protocol.FeatureEventV1})
	defer c3.conn.Close()
	c3.expectWelcome(timeout)

	c1.send(protocol.TypeEvent, protocol.Event{To: w2.PlayerID, Payload: json.RawMessage(`1`)})

	if ev := c2.expectEvent(timeout); string(ev.Payload) != "1" {
		t.Fatalf("addressee got payload %s, want 1", ev.Payload)
	}
	c1.expectEvent(timeout) // the sender's own echo
	c3.expectNothingOfType(protocol.TypeEvent, 300*time.Millisecond)
}

// TestOversizedEventIsDroppedNotFragmented pins the deliberate absence of
// application-level fragmentation. An event past MaxEventBytes means the
// payload should have been a reference to the data, not the data.
func TestOversizedEventIsDroppedNotFragmented(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEventV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	big := make([]byte, protocol.MaxEventBytes+64)
	for i := range big {
		big[i] = 'a'
	}
	payload, err := json.Marshal(string(big))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	c1.send(protocol.TypeEvent, protocol.Event{Payload: payload})
	c1.expectNothingOfType(protocol.TypeEvent, 300*time.Millisecond)
}

// TestSequencerGivesEveryMemberOneIdenticalTotalOrder is the invariant that
// makes sequencer authority worth anything: it is not enough that events
// arrive, they must arrive in the SAME order at every member, even when
// several clients send concurrently.
//
// This is authority over order, which needs no game knowledge — as opposed to
// authority over meaning, which would.
func TestSequencerGivesEveryMemberOneIdenticalTotalOrder(t *testing.T) {
	const (
		senders          = 4
		eventsPerSender  = 15
		expectedReceived = senders * eventsPerSender
	)
	addr := startServer(t)

	clients := make([]*testClient, senders)
	for i := range clients {
		clients[i] = dialFeatureClient(t, addr, "room1", fmt.Sprintf("p%d", i), []string{protocol.FeatureEventV1})
		defer clients[i].conn.Close()
		clients[i].expectWelcome(timeout)
	}
	// Everyone must be in the room before anyone sends, or an early event
	// would legitimately not reach a client that had not joined yet. Client i
	// learns about the clients that joined AFTER it via Join; the ones before
	// it came in its own Welcome roster.
	for i, tc := range clients {
		for n := i + 1; n < senders; n++ {
			tc.nextOfType(protocol.TypeJoin, timeout)
		}
	}

	var wg sync.WaitGroup
	for i, tc := range clients {
		wg.Add(1)
		go func(i int, tc *testClient) {
			defer wg.Done()
			for n := 0; n < eventsPerSender; n++ {
				tc.send(protocol.TypeEvent, protocol.Event{
					Payload: json.RawMessage(fmt.Sprintf(`{"who":%d,"n":%d}`, i, n)),
				})
			}
		}(i, tc)
	}
	wg.Wait()

	// Each client's observed sequence of (seq, from, payload) must be
	// identical to every other's. Comparing the whole list, not just the
	// stamps: a relay that stamped consistently but delivered out of order
	// would pass a weaker check and still be broken.
	var reference []string
	for ci, tc := range clients {
		observed := make([]string, 0, expectedReceived)
		var lastSeq uint64
		for n := 0; n < expectedReceived; n++ {
			ev := tc.expectEvent(4 * time.Second)
			if ev.Seq <= lastSeq {
				t.Fatalf("client %d saw seq %d after %d — not monotonic", ci, ev.Seq, lastSeq)
			}
			lastSeq = ev.Seq
			observed = append(observed, fmt.Sprintf("%d|%s|%s", ev.Seq, ev.From, ev.Payload))
		}
		if reference == nil {
			reference = observed
			continue
		}
		for n := range observed {
			if observed[n] != reference[n] {
				t.Fatalf("client %d observed %q at position %d, but client 0 observed %q — the order is not total",
					ci, observed[n], n, reference[n])
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Leases
// ---------------------------------------------------------------------------

// TestExactlyOneClaimantWinsAContestedLease is the core lease invariant, and
// the reason this file exists: many clients race for one key, and the relay
// must produce exactly one holder and tell everyone the same answer.
//
// The relay never judges merit, only arrival — it picks the first claim and
// that becomes the fact by fiat. Arbitrary-but-consistent is the whole trick.
func TestExactlyOneClaimantWinsAContestedLease(t *testing.T) {
	const claimants = 6
	addr := startServer(t)

	clients := make([]*testClient, claimants)
	for i := range clients {
		clients[i] = dialFeatureClient(t, addr, "room1", fmt.Sprintf("p%d", i), []string{protocol.FeatureLeaseV1})
		defer clients[i].conn.Close()
		clients[i].expectWelcome(timeout)
	}

	var wg sync.WaitGroup
	for _, tc := range clients {
		wg.Add(1)
		go func(tc *testClient) {
			defer wg.Done()
			tc.send(protocol.TypeLease, protocol.Lease{
				Op: protocol.LeaseClaim, Key: "route103:rarecandy", TTLMs: 30000,
			})
		}(tc)
	}
	wg.Wait()

	// Every client either won or was denied; collect the first answer each
	// one gets that names a holder, and require them all to agree.
	holders := make(map[string]int)
	for i, tc := range clients {
		st := tc.expectLeaseState(timeout)
		if st.Key != "route103:rarecandy" {
			t.Fatalf("client %d got a lease_state for key %q", i, st.Key)
		}
		if st.Holder == "" {
			t.Fatalf("client %d got a lease_state with no holder (reason %q)", i, st.Reason)
		}
		holders[st.Holder]++
	}
	if len(holders) != 1 {
		t.Fatalf("clients disagree about who holds the key: %v", holders)
	}
	var winner string
	for h := range holders {
		winner = h
	}

	// And a claim by someone who was not in the contest still loses, now that
	// it has settled — a denial goes only to the asker. A fresh client rather
	// than one of the racers, so this assertion cannot accidentally read a
	// lease_state still queued from the contest above.
	late := dialFeatureClient(t, addr, "room1", "late", []string{protocol.FeatureLeaseV1})
	defer late.conn.Close()
	late.expectWelcome(timeout)
	late.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "route103:rarecandy"})
	st := late.expectLeaseState(timeout)
	if st.Reason != protocol.LeaseDenied || st.Holder != winner {
		t.Fatalf("second claim got reason %q holder %q, want %q held by %q",
			st.Reason, st.Holder, protocol.LeaseDenied, winner)
	}
}

// TestLeaseReleaseFreesTheKeyForTheNextClaimant confirms the ordinary
// hand-off, and that a release is broadcast rather than told only to the
// holder — everyone needs to know a key is free.
func TestLeaseReleaseFreesTheKeyForTheNextClaimant(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureLeaseV1})
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureLeaseV1})
	defer c2.conn.Close()
	c2.expectWelcome(timeout)

	c1.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "k"})
	if st := c1.expectLeaseState(timeout); st.Holder != w1.PlayerID {
		t.Fatalf("claim not granted: %+v", st)
	}
	c2.expectLeaseState(timeout) // c2 learns alice holds it

	c1.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseRelease, Key: "k"})
	if st := c2.expectLeaseState(timeout); st.Reason != protocol.LeaseReleased || st.Holder != "" {
		t.Fatalf("release broadcast = %+v, want a free key with reason %q", st, protocol.LeaseReleased)
	}

	c2.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "k"})
	if st := c2.expectLeaseState(timeout); st.Reason != protocol.LeaseGranted {
		t.Fatalf("claim after release = %+v, want granted", st)
	}
}

// TestLeaseExpiresWithoutRenew covers the half of lease authority that is
// actually hard: lifetime. A holder that stops talking must not wedge a key
// forever, and only a clock can guarantee that without game knowledge.
func TestLeaseExpiresWithoutRenew(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureLeaseV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	// MinLeaseTTL is the shortest the relay will honour; asking for less is
	// clamped up to it rather than refused.
	c1.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "k", TTLMs: 1})
	if st := c1.expectLeaseState(timeout); st.Reason != protocol.LeaseGranted {
		t.Fatalf("claim = %+v, want granted", st)
	}
	st := c1.expectLeaseState(protocol.MinLeaseTTL + 2*time.Second)
	if st.Reason != protocol.LeaseExpired || st.Holder != "" {
		t.Fatalf("after the TTL got %+v, want the key free with reason %q", st, protocol.LeaseExpired)
	}
}

// TestLeaseIsFreedWhenItsHolderDisconnects is the disconnect half of the same
// problem — and is reported distinctly from an expiry, because an adapter may
// reasonably treat "they hung up" and "they went quiet" differently. The relay
// does not decide which; it says which happened.
func TestLeaseIsFreedWhenItsHolderDisconnects(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureLeaseV1})
	c1.expectWelcome(timeout)
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureLeaseV1})
	defer c2.conn.Close()
	c2.expectWelcome(timeout)

	c1.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "k"})
	c1.expectLeaseState(timeout)
	c2.expectLeaseState(timeout)

	c1.conn.Close()

	if st := c2.expectLeaseState(timeout); st.Reason != protocol.LeaseHolderLeft || st.Holder != "" {
		t.Fatalf("after the holder dropped got %+v, want free with reason %q", st, protocol.LeaseHolderLeft)
	}
}

// ---------------------------------------------------------------------------
// Escrow
// ---------------------------------------------------------------------------

func openEscrow(t *testing.T, a, b *testClient, id, withID string) {
	t.Helper()
	a.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: id, With: withID})
	for _, tc := range []*testClient{a, b} {
		if st := tc.expectEscrowState(timeout); st.Phase != protocol.EscrowPhaseOpen {
			t.Fatalf("open phase = %q, want %q", st.Phase, protocol.EscrowPhaseOpen)
		}
	}
}

// TestEscrowRevealsBlobsOnlyOnCommit is the atomicity property stated
// directly: neither side may see the other's contribution until the exchange
// has completed, or the second depositor could decide what to offer after
// seeing what it was offered.
func TestEscrowRevealsBlobsOnlyOnCommit(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEscrowV1})
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureEscrowV1})
	defer c2.conn.Close()
	w2 := c2.expectWelcome(timeout)

	openEscrow(t, c1, c2, "trade-1", w2.PlayerID)

	c1.send(protocol.TypeEscrow, protocol.Escrow{
		Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`{"mon":"mudkip"}`),
	})
	for _, tc := range []*testClient{c1, c2} {
		if st := tc.expectEscrowState(timeout); len(st.Blobs) != 0 {
			t.Fatalf("blobs revealed at phase %q — they must only appear on commit", st.Phase)
		}
	}

	c2.send(protocol.TypeEscrow, protocol.Escrow{
		Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`{"mon":"torchic"}`),
	})
	for _, tc := range []*testClient{c1, c2} {
		st := tc.expectEscrowState(timeout)
		if st.Phase != protocol.EscrowPhaseDeposited {
			t.Fatalf("phase = %q, want %q", st.Phase, protocol.EscrowPhaseDeposited)
		}
		if len(st.Blobs) != 0 {
			t.Fatal("blobs revealed once both deposited — still too early, neither side has committed")
		}
	}

	c1.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowCommit, ID: "trade-1"})
	for _, tc := range []*testClient{c1, c2} {
		if st := tc.expectEscrowState(timeout); len(st.Blobs) != 0 {
			t.Fatal("blobs revealed on one commit — an exchange completes only when BOTH commit")
		}
	}

	c2.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowCommit, ID: "trade-1"})
	for _, tc := range []*testClient{c1, c2} {
		st := tc.expectEscrowState(timeout)
		if st.Phase != protocol.EscrowPhaseCommitted {
			t.Fatalf("phase = %q, want %q", st.Phase, protocol.EscrowPhaseCommitted)
		}
		// Both parties receive the identical map — that is what makes the
		// swap both-or-neither from each side's point of view.
		if string(st.Blobs[w1.PlayerID]) != `{"mon":"mudkip"}` || string(st.Blobs[w2.PlayerID]) != `{"mon":"torchic"}` {
			t.Fatalf("committed blobs = %v, want both parties' deposits", st.Blobs)
		}
	}
}

// TestEscrowAbortDiscardsBothBlobs is the "neither" half. An abort must
// destroy the deposits rather than deliver them, which is what makes it safe
// to trigger on a disconnect.
func TestEscrowAbortDiscardsBothBlobs(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEscrowV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureEscrowV1})
	defer c2.conn.Close()
	w2 := c2.expectWelcome(timeout)

	openEscrow(t, c1, c2, "trade-1", w2.PlayerID)
	c1.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`"a"`)})
	c1.expectEscrowState(timeout)
	c2.expectEscrowState(timeout)
	c2.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`"b"`)})
	c1.expectEscrowState(timeout)
	c2.expectEscrowState(timeout)

	c2.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowAbort, ID: "trade-1"})
	for _, tc := range []*testClient{c1, c2} {
		st := tc.expectEscrowState(timeout)
		if st.Phase != protocol.EscrowPhaseAborted {
			t.Fatalf("phase = %q, want %q", st.Phase, protocol.EscrowPhaseAborted)
		}
		if len(st.Blobs) != 0 {
			t.Fatalf("aborted exchange still delivered blobs %v", st.Blobs)
		}
	}
}

// TestEscrowAbortsWhenAPartyDisconnects is the one-side-vanishes case
// agent_docs/beyond-cosmetic.md §5 calls out as never examined and the source
// of real-world duplication bugs. An exchange whose counterparty is gone can
// never complete, and leaving it open would hold the other side's deposit
// hostage until the timeout.
func TestEscrowAbortsWhenAPartyDisconnects(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEscrowV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureEscrowV1})
	w2 := c2.expectWelcome(timeout)

	openEscrow(t, c1, c2, "trade-1", w2.PlayerID)
	c1.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`"mine"`)})
	c1.expectEscrowState(timeout)
	c2.expectEscrowState(timeout)

	c2.conn.Close()

	st := c1.expectEscrowState(timeout)
	if st.Phase != protocol.EscrowPhaseAborted || st.Reason != protocol.EscrowReasonPartyLeft {
		t.Fatalf("after the counterparty dropped got phase %q reason %q, want %q/%q",
			st.Phase, st.Reason, protocol.EscrowPhaseAborted, protocol.EscrowReasonPartyLeft)
	}
	if len(st.Blobs) != 0 {
		t.Fatal("an exchange aborted by a disconnect still delivered blobs")
	}
}

// TestEscrowRefusesANonMemberCounterparty stops an exchange being opened
// against an id that is not in the room, which would otherwise sit pinned
// until its timeout with nobody able to complete it.
func TestEscrowRefusesANonMemberCounterparty(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEscrowV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	c1.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: "t", With: "p999"})
	st := c1.expectEscrowState(timeout)
	if st.Phase != protocol.EscrowPhaseAborted || st.Reason != protocol.EscrowReasonRejected {
		t.Fatalf("open against a stranger got %q/%q, want %q/%q",
			st.Phase, st.Reason, protocol.EscrowPhaseAborted, protocol.EscrowReasonRejected)
	}
}

// ---------------------------------------------------------------------------
// Late-join snapshot
// ---------------------------------------------------------------------------

// TestLateJoinerIsSeededWithExistingPlayersState covers Join.State, reserved
// since the contract was written and populated for the first time here.
// Without it a newcomer sees nothing at all until every existing player
// happens to move.
func TestLateJoinerIsSeededWithExistingPlayersState(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureSnapshotV1})
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	c1.sendState(protocol.State{AreaID: "0:9", Position: []float64{4, 5}, Anim: "idle"})

	// Give the relay a moment to record it before the second client joins;
	// without an ordering point the test would race the forward path.
	time.Sleep(100 * time.Millisecond)

	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureSnapshotV1})
	defer c2.conn.Close()
	c2.expectWelcome(timeout)

	var join protocol.Join
	if err := json.Unmarshal(c2.nextOfType(protocol.TypeJoin, timeout).Payload, &join); err != nil {
		t.Fatalf("unmarshal join: %v", err)
	}
	if join.PlayerID != w1.PlayerID {
		t.Fatalf("seeded join is for %q, want %q", join.PlayerID, w1.PlayerID)
	}
	if join.State == nil {
		t.Fatal("seeded join carried no state — the newcomer sees nothing until alice next moves")
	}
	if join.State.AreaID != "0:9" || len(join.State.Position) != 2 || join.State.Position[0] != 4 {
		t.Fatalf("seeded state = %+v, want alice's last sample", join.State)
	}
}

// TestNoSnapshotWithoutTheCapability keeps the previous behaviour exactly
// intact for a room that did not ask — the reason this is opt-in at all.
func TestNoSnapshotWithoutTheCapability(t *testing.T) {
	addr := startServer(t)

	c1 := dialTestClient(t, addr, "emerald", "room1", "alice")
	defer c1.conn.Close()
	c1.expectWelcome(timeout)
	c1.sendState(protocol.State{AreaID: "0:9", Position: []float64{4, 5}})
	time.Sleep(100 * time.Millisecond)

	c2 := dialTestClient(t, addr, "emerald", "room1", "bob")
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c2.expectNothingOfType(protocol.TypeJoin, 300*time.Millisecond)
}

// ---------------------------------------------------------------------------
// Session resumption
// ---------------------------------------------------------------------------

// TestResumeKeepsThePlayerIDAndTheRoomNeverSeesALeave is the user-visible
// point of resumption: a network blip stops costing everyone else a despawn
// and a respawn.
func TestResumeKeepsThePlayerIDAndTheRoomNeverSeesALeave(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:      make(map[string]*Room),
		MaxClients: DefaultMaxClients,
	})

	c1 := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	w1 := c1.expectWelcome(timeout)
	if w1.ResumeToken == "" {
		t.Fatal("welcome carried no resume token despite resume.v1")
	}
	c2 := dialFeatureClient(t, addr, "room1", "bob", allFeatures)
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.nextOfType(protocol.TypeJoin, timeout) // alice learns about bob

	// Alice holds a key, then her connection drops underneath her.
	c1.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "k"})
	c1.expectLeaseState(timeout)
	c2.expectLeaseState(timeout)
	c1.conn.Close()

	// Bob must see nothing at all — no leave, and no lease release.
	c2.expectNothingOfType(protocol.TypeLeave, 300*time.Millisecond)

	back := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
		Features:        allFeatures,
		ResumeToken:     w1.ResumeToken,
	})
	defer back.conn.Close()

	w := back.expectWelcome(timeout)
	if !w.Resumed {
		t.Fatal("welcome did not report a resumption")
	}
	if w.PlayerID != w1.PlayerID {
		t.Fatalf("resumed as %q, want the original identity %q", w.PlayerID, w1.PlayerID)
	}
	if w.ResumeToken == "" || w.ResumeToken == w1.ResumeToken {
		t.Fatal("resume token was not rotated — tokens are single-use")
	}
	// The lease survived the drop, and is replayed to the resumed client.
	if st := back.expectLeaseState(timeout); st.Holder != w1.PlayerID || st.Key != "k" {
		t.Fatalf("resumed client's lease snapshot = %+v, want it still holding \"k\"", st)
	}
	// And bob never learned any of it happened.
	c2.expectNothingOfType(protocol.TypeJoin, 300*time.Millisecond)
}

// TestResumeGraceExpiryBecomesARealLeave is the other side: an identity is
// held, not held forever. A player who is genuinely gone must free its keys
// and its slot, or one departure blocks a key nobody is coming back for.
func TestResumeGraceExpiryBecomesARealLeave(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:       make(map[string]*Room),
		MaxClients:  DefaultMaxClients,
		ResumeGrace: 200 * time.Millisecond,
	})

	c1 := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	w1 := c1.expectWelcome(timeout)
	c2 := dialFeatureClient(t, addr, "room1", "bob", allFeatures)
	defer c2.conn.Close()
	c2.expectWelcome(timeout)
	c1.nextOfType(protocol.TypeJoin, timeout)

	c1.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "k"})
	c1.expectLeaseState(timeout)
	c2.expectLeaseState(timeout)

	c1.conn.Close()

	if st := c2.expectLeaseState(2 * time.Second); st.Reason != protocol.LeaseHolderLeft {
		t.Fatalf("after the grace window got lease reason %q, want %q", st.Reason, protocol.LeaseHolderLeft)
	}
	var leave protocol.Leave
	if err := json.Unmarshal(c2.nextOfType(protocol.TypeLeave, timeout).Payload, &leave); err != nil {
		t.Fatalf("unmarshal leave: %v", err)
	}
	if leave.PlayerID != w1.PlayerID {
		t.Fatalf("leave named %q, want %q", leave.PlayerID, w1.PlayerID)
	}
}

// TestCommittedEscrowSurvivesAPartyCrashingBeforeItHearsTheOutcome is the
// crash-injection case the whole retention mechanism exists for, and the one
// that decides whether "both or neither" is a real guarantee or one that only
// holds while both sockets stay up.
//
// The scenario: alice deposits and commits, then her connection dies. Bob
// deposits and commits, so the exchange COMPLETES while alice is not there to
// hear it — the relay's committed message is written to a suspended
// connection and goes nowhere. Alice comes back and must be told the outcome,
// with both blobs, or she is permanently unsure whether she gave something
// away for nothing.
//
// This is precisely the failure that never shows up in testing and always
// shows up in the field, so it gets an explicit test rather than being
// assumed from the retention constant's existence.
func TestCommittedEscrowSurvivesAPartyCrashingBeforeItHearsTheOutcome(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:      make(map[string]*Room),
		MaxClients: DefaultMaxClients,
	})

	alice := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	wA := alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", allFeatures)
	defer bob.conn.Close()
	wB := bob.expectWelcome(timeout)
	alice.nextOfType(protocol.TypeJoin, timeout)

	openEscrow(t, alice, bob, "trade-1", wB.PlayerID)

	alice.send(protocol.TypeEscrow, protocol.Escrow{
		Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`"alice-item"`),
	})
	alice.expectEscrowState(timeout)
	bob.expectEscrowState(timeout)
	alice.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowCommit, ID: "trade-1"})
	alice.expectEscrowState(timeout)
	bob.expectEscrowState(timeout)

	// Alice's connection dies mid-exchange. Her identity is held, so the
	// exchange must NOT be aborted — a suspended party is not a departed one.
	alice.conn.Close()

	bob.send(protocol.TypeEscrow, protocol.Escrow{
		Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`"bob-item"`),
	})
	bob.expectEscrowState(timeout)
	bob.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowCommit, ID: "trade-1"})

	// Bob sees it complete. Alice, being gone, sees nothing at all.
	st := bob.expectEscrowState(timeout)
	if st.Phase != protocol.EscrowPhaseCommitted {
		t.Fatalf("bob's phase = %q, want %q — a suspended party must not abort a live exchange", st.Phase, protocol.EscrowPhaseCommitted)
	}
	if string(st.Blobs[wA.PlayerID]) != `"alice-item"` {
		t.Fatalf("bob's committed blobs = %v, want alice's deposit included", st.Blobs)
	}

	// Alice reconnects and must learn what happened while she was gone.
	back := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
		Features:        allFeatures,
		ResumeToken:     wA.ResumeToken,
	})
	defer back.conn.Close()
	if w := back.expectWelcome(timeout); !w.Resumed {
		t.Fatal("alice did not resume, so the retained exchange is unreachable")
	}

	replayed := back.expectEscrowState(timeout)
	if replayed.ID != "trade-1" || replayed.Phase != protocol.EscrowPhaseCommitted {
		t.Fatalf("replayed exchange = %+v, want trade-1 committed", replayed)
	}
	if string(replayed.Blobs[wB.PlayerID]) != `"bob-item"` {
		t.Fatalf("replayed blobs = %v — alice cannot complete the swap without bob's side", replayed.Blobs)
	}
}

// TestEscrowAbortsIfACrashedPartyNeverComesBack is the other half: retention
// is not forgiveness. Once the grace window closes the party has genuinely
// left, and an exchange that can never complete must release the other side's
// deposit rather than hold it hostage until the 60s escrow timeout.
func TestEscrowAbortsIfACrashedPartyNeverComesBack(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:       make(map[string]*Room),
		MaxClients:  DefaultMaxClients,
		ResumeGrace: 200 * time.Millisecond,
	})

	alice := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", allFeatures)
	defer bob.conn.Close()
	wB := bob.expectWelcome(timeout)
	alice.nextOfType(protocol.TypeJoin, timeout)

	openEscrow(t, alice, bob, "trade-1", wB.PlayerID)
	bob.send(protocol.TypeEscrow, protocol.Escrow{
		Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`"bob-item"`),
	})
	alice.expectEscrowState(timeout)
	bob.expectEscrowState(timeout)

	alice.conn.Close()

	st := bob.expectEscrowState(2 * time.Second)
	if st.Phase != protocol.EscrowPhaseAborted || st.Reason != protocol.EscrowReasonPartyLeft {
		t.Fatalf("after the grace window got %q/%q, want %q/%q",
			st.Phase, st.Reason, protocol.EscrowPhaseAborted, protocol.EscrowReasonPartyLeft)
	}
	if len(st.Blobs) != 0 {
		t.Fatal("an abort still delivered bob's own deposit back as if it had committed")
	}
}

// TestStaleResumeTokenJoinsFreshRatherThanFailing pins the degradation rule:
// being away slightly too long must cost a new identity, never the ability to
// play.
func TestStaleResumeTokenJoinsFreshRatherThanFailing(t *testing.T) {
	addr := startServer(t)

	c := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
		Features:        allFeatures,
		ResumeToken:     "deadbeefdeadbeefdeadbeefdeadbeef",
	})
	defer c.conn.Close()

	w := c.expectWelcome(timeout)
	if w.PlayerID == "" {
		t.Fatal("a stale resume token cost the client its join")
	}
	if w.Resumed {
		t.Fatal("a fabricated token was reported as a successful resumption")
	}
}

// ---------------------------------------------------------------------------
// Introspection
// ---------------------------------------------------------------------------

// TestSnapshotReportsWhatTheRelayThinksIsTrue covers the debugging aid, which
// is worth a test for one specific reason: it is the tool someone reaches for
// when something is already wrong, so a snapshot that quietly reports the
// wrong thing is worse than none at all.
//
// It also pins the two omissions that are deliberate rather than incidental —
// resume tokens and escrow blobs never appear, being a credential and the
// contents of a trade in progress respectively.
func TestSnapshotReportsWhatTheRelayThinksIsTrue(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), MaxClients: DefaultMaxClients}
	addr := startServerWith(t, s)

	alice := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	wA := alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", allFeatures)
	defer bob.conn.Close()
	wB := bob.expectWelcome(timeout)
	alice.nextOfType(protocol.TypeJoin, timeout)

	alice.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "k", TTLMs: 30000})
	alice.expectLeaseState(timeout)
	bob.expectLeaseState(timeout)

	openEscrow(t, alice, bob, "trade-1", wB.PlayerID)
	alice.send(protocol.TypeEscrow, protocol.Escrow{
		Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`"a-secret-item"`),
	})
	alice.expectEscrowState(timeout)
	bob.expectEscrowState(timeout)

	snap := s.Snapshot()
	if snap.Clients != 2 || len(snap.Rooms) != 1 {
		t.Fatalf("snapshot = %d clients / %d rooms, want 2/1", snap.Clients, len(snap.Rooms))
	}
	room := snap.Rooms[0]
	if len(room.Members) != 2 || room.Seq == 0 {
		t.Fatalf("room snapshot = %d members seq=%d, want 2 members and a moving sequencer", len(room.Members), room.Seq)
	}
	if len(room.Leases) != 1 || room.Leases[0].Holder != wA.PlayerID || room.Leases[0].ExpiresIn <= 0 {
		t.Fatalf("lease snapshot = %+v, want \"k\" held by %s with time left", room.Leases, wA.PlayerID)
	}
	if len(room.Escrows) != 1 || len(room.Escrows[0].Deposited) != 1 || room.Escrows[0].Terminal {
		t.Fatalf("escrow snapshot = %+v, want one live exchange with a single deposit", room.Escrows)
	}

	// The rendered form is what a host actually reads, so assert on it too —
	// and on what must NOT be in it.
	rendered := snap.String()
	if !strings.Contains(rendered, `lease "k" held by `+wA.PlayerID) {
		t.Fatalf("rendered snapshot does not name the lease holder:\n%s", rendered)
	}
	if strings.Contains(rendered, "a-secret-item") {
		t.Fatalf("rendered snapshot leaked an escrow blob — a trade's contents are not debugging output:\n%s", rendered)
	}
	if wA.ResumeToken == "" || strings.Contains(rendered, wA.ResumeToken) {
		t.Fatalf("rendered snapshot leaked a resume token, which is a session credential:\n%s", rendered)
	}

	// A suspended identity is the state hardest to diagnose without this, so
	// it must be visible and labelled.
	alice.conn.Close()
	deadline := time.Now().Add(2 * time.Second)
	for {
		snap = s.Snapshot()
		if snap.SuspendedSessions == 1 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("a dropped identity never showed as suspended:\n%s", snap.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !strings.Contains(snap.String(), "SUSPENDED") {
		t.Fatalf("rendered snapshot does not flag the suspended member:\n%s", snap.String())
	}
}

// ---------------------------------------------------------------------------
// Room-scoped vs client-scoped capabilities
// ---------------------------------------------------------------------------

// TestClientScopedCapabilitiesDoNotSplitARoom is the point of the split. A
// capability that concerns only one client and the relay must not force every
// other member to be reconfigured in lockstep — no peer participates in it, so
// there is nothing for them to disagree about.
//
// The original design made every capability sticky, which meant enabling
// resumption cost a coordinated config change across every player for a
// feature none of them take part in. That is friction with no safety bought,
// and the surest way to have nobody enable it.
func TestClientScopedCapabilitiesDoNotSplitARoom(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:      make(map[string]*Room),
		MaxClients: DefaultMaxClients,
	})

	// A plain cosmetic client creates the room, advertising nothing at all.
	plain := dialFeatureClient(t, addr, "room1", "plain", nil)
	defer plain.conn.Close()
	if w := plain.expectWelcome(timeout); len(w.Features) != 0 {
		t.Fatalf("cosmetic client's welcome carried features %v, want none", w.Features)
	}

	// A client wanting only client-scoped capabilities joins the same room.
	fancy := dialFeatureClient(t, addr, "room1", "fancy",
		[]string{protocol.FeatureResumeV1, protocol.FeatureSnapshotV1})
	defer fancy.conn.Close()
	w := fancy.expectWelcome(timeout)
	if w.PlayerID == "" {
		t.Fatal("a client wanting only client-scoped capabilities was refused a cosmetic room")
	}
	if w.ResumeToken == "" {
		t.Fatal("resume.v1 was not honoured, even though it needs no agreement from anyone")
	}
	if !protocol.HasFeature(w.Features, protocol.FeatureResumeV1) {
		t.Fatalf("welcome features = %v, want resume.v1 reported as in force for this client", w.Features)
	}

	// And it genuinely works: the fancy client drops and resumes, while the
	// plain client — which has never heard of resumption — sees nothing.
	plainSaw := make(chan struct{})
	go func() {
		plain.expectNothingOfType(protocol.TypeLeave, 700*time.Millisecond)
		close(plainSaw)
	}()
	fancy.conn.Close()
	<-plainSaw

	back := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "fancy",
		Features:        []string{protocol.FeatureResumeV1, protocol.FeatureSnapshotV1},
		ResumeToken:     w.ResumeToken,
	})
	defer back.conn.Close()
	got := back.expectWelcome(timeout)
	if !got.Resumed || got.PlayerID != w.PlayerID {
		t.Fatalf("resume in a mixed room gave resumed=%v id=%q, want true and %q",
			got.Resumed, got.PlayerID, w.PlayerID)
	}
}

// TestRoomScopedCapabilityStillSplitsARoom is the other half: the split must
// not have quietly weakened the check that matters. A capability peers take
// part in still has to match exactly, or conflict resolution fails silently.
func TestRoomScopedCapabilityStillSplitsARoom(t *testing.T) {
	addr := startServer(t)

	// A room-scoped capability mixed with a client-scoped one: only the
	// room-scoped half is compared, so this must still be refused.
	c1 := dialFeatureClient(t, addr, "room1", "alice",
		[]string{protocol.FeatureLeaseV1, protocol.FeatureResumeV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	// Same client-scoped set, different room-scoped set: refused.
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureResumeV1})
	defer c2.conn.Close()
	env := c2.next(timeout)
	if env.Type != protocol.TypeReject {
		t.Fatalf("a client missing the room's lease.v1 got %q, want a reject", env.Type)
	}

	// And differing ONLY in a client-scoped capability is fine.
	c3 := dialFeatureClient(t, addr, "room1", "carol", []string{protocol.FeatureLeaseV1})
	defer c3.conn.Close()
	if w := c3.expectWelcome(timeout); w.PlayerID == "" {
		t.Fatal("a client differing only in a client-scoped capability was refused")
	}
}

// TestSnapshotIsPerRecipientNotPerRoom confirms the seed follows the receiving
// client's own request, since it changes only what that client receives.
func TestSnapshotIsPerRecipientNotPerRoom(t *testing.T) {
	addr := startServer(t)

	mover := dialFeatureClient(t, addr, "room1", "mover", nil)
	defer mover.conn.Close()
	mover.expectWelcome(timeout)
	mover.sendState(protocol.State{AreaID: "0:9", Position: []float64{4, 5}})
	time.Sleep(100 * time.Millisecond)

	// Wants a seed and must get one.
	wanting := dialFeatureClient(t, addr, "room1", "wanting", []string{protocol.FeatureSnapshotV1})
	defer wanting.conn.Close()
	wanting.expectWelcome(timeout)
	var join protocol.Join
	if err := json.Unmarshal(wanting.nextOfType(protocol.TypeJoin, timeout).Payload, &join); err != nil {
		t.Fatalf("unmarshal join: %v", err)
	}
	if join.State == nil {
		t.Fatal("a client that asked for a seed did not get one")
	}

	// Does not want one, in the same room, and must not get one.
	plain := dialFeatureClient(t, addr, "room1", "plain", nil)
	defer plain.conn.Close()
	plain.expectWelcome(timeout)
	plain.expectNothingOfType(protocol.TypeJoin, 300*time.Millisecond)
}

// TestResumeTakesOverAConnectionTheRelayHasNotNoticedIsDead is the case that
// makes resumption work in the field rather than only in tests.
//
// A client's connection dies without the relay noticing — routine on quic,
// where a hard-killed peer sends no close frame and the connection lingers
// until quic's idle timeout (measured 2026-08-17: ~17s, against an immediate
// RST on tcp). The client reconnects INSIDE that window, while the relay still
// believes the old connection is fine.
//
// The original design registered a session only on disconnect, so the token
// matched nothing here: the client got a fresh player_id and its old ghost
// stood there until the timeout. That is strictly worse than not having
// resumption, and it is the common case — which is why this is tested by
// resuming without ever closing the first connection.
func TestResumeTakesOverAConnectionTheRelayHasNotNoticedIsDead(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:      make(map[string]*Room),
		MaxClients: DefaultMaxClients,
	})

	alice := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	defer alice.conn.Close()
	wA := alice.expectWelcome(timeout)
	bob := dialFeatureClient(t, addr, "room1", "bob", allFeatures)
	defer bob.conn.Close()
	bob.expectWelcome(timeout)
	alice.nextOfType(protocol.TypeJoin, timeout)

	// Deliberately NOT closing alice's connection: the relay must still
	// believe it is live when the replacement arrives.
	back := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
		Features:        allFeatures,
		ResumeToken:     wA.ResumeToken,
	})
	defer back.conn.Close()

	w := back.expectWelcome(timeout)
	if !w.Resumed {
		t.Fatal("a takeover was not reported as a resumption — the client would treat this as a new session")
	}
	if w.PlayerID != wA.PlayerID {
		t.Fatalf("took over as %q, want the original identity %q", w.PlayerID, wA.PlayerID)
	}

	// Bob must see none of it: no leave, no join, no duplicate. The resource
	// side of a takeover is asserted separately, in
	// TestTakeoverLeavesExactlyOneMemberAndOneSlot.
	bob.expectNothingOfType(protocol.TypeLeave, 400*time.Millisecond)
}

// TestTakeoverLeavesExactlyOneMemberAndOneSlot guards the resource half of a
// takeover: the replaced connection must not leave its member entry, its
// server-wide slot, or a second ghost behind.
func TestTakeoverLeavesExactlyOneMemberAndOneSlot(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), MaxClients: DefaultMaxClients}
	addr := startServerWith(t, s)

	alice := dialFeatureClient(t, addr, "room1", "alice", allFeatures)
	defer alice.conn.Close()
	wA := alice.expectWelcome(timeout)

	back := dialTestClientWithHello(t, addr, protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          "emerald",
		Room:            "room1",
		DisplayName:     "alice",
		Features:        allFeatures,
		ResumeToken:     wA.ResumeToken,
	})
	defer back.conn.Close()
	back.expectWelcome(timeout)

	// The superseded connection's own OnDisconnect fires asynchronously; give
	// it a moment and then require the books to balance.
	deadline := time.Now().Add(2 * time.Second)
	for {
		snap := s.Snapshot()
		if len(snap.Rooms) == 1 && len(snap.Rooms[0].Members) == 1 &&
			snap.Clients == 1 && snap.SuspendedSessions == 0 {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("after a takeover the relay still shows:\n%s", snap.String())
		}
		time.Sleep(25 * time.Millisecond)
	}
}

// TestVoluntaryLeaveIsImmediateEvenWithResumptionOn is the fix for a bug the
// 2026-08-17 loopback session found: with resume.v1 on, quitting the game left
// every other player staring at a frozen ghost for the whole grace window,
// because the relay only ever saw a socket close and could not tell a
// deliberate exit from a bad connection.
//
// The core discarding its own resume token was not enough — that only decides
// where the NEXT connection lands and says nothing to the relay about this one.
// A client now says goodbye explicitly.
func TestVoluntaryLeaveIsImmediateEvenWithResumptionOn(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:      make(map[string]*Room),
		MaxClients: DefaultMaxClients,
		// Long enough that a suspension would be unmistakable in the timings
		// below rather than a race against the grace expiring on its own.
		ResumeGrace: 30 * time.Second,
	})

	quitter := dialFeatureClient(t, addr, "room1", "quitter", allFeatures)
	if w := quitter.expectWelcome(timeout); w.ResumeToken == "" {
		t.Fatal("resumption was not on, so this test would pass for the wrong reason")
	}
	watcher := dialFeatureClient(t, addr, "room1", "watcher", allFeatures)
	defer watcher.conn.Close()
	watcher.expectWelcome(timeout)
	quitter.nextOfType(protocol.TypeJoin, timeout)

	// Say goodbye, then hang up — exactly what the core does when its adapter
	// (the game) goes away.
	quitter.send(protocol.TypeLeave, protocol.Leave{})
	time.Sleep(150 * time.Millisecond)
	quitter.conn.Close()

	// The watcher must see a real leave promptly, NOT after 30 seconds.
	env := watcher.nextOfType(protocol.TypeLeave, 3*time.Second)
	var leave protocol.Leave
	if err := json.Unmarshal(env.Payload, &leave); err != nil {
		t.Fatalf("unmarshal leave: %v", err)
	}
	if leave.PlayerID == "" {
		t.Fatal("leave named nobody")
	}
}

// TestUnexplainedDropStillGetsTheGraceWindow is the other side of the same
// coin: only an explicit goodbye skips the grace. A client that simply
// vanishes — which is what a network failure looks like — must still be held,
// or the fix above would have quietly disabled resumption altogether.
func TestUnexplainedDropStillGetsTheGraceWindow(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:       make(map[string]*Room),
		MaxClients:  DefaultMaxClients,
		ResumeGrace: 30 * time.Second,
	})

	dropper := dialFeatureClient(t, addr, "room1", "dropper", allFeatures)
	dropper.expectWelcome(timeout)
	watcher := dialFeatureClient(t, addr, "room1", "watcher", allFeatures)
	defer watcher.conn.Close()
	watcher.expectWelcome(timeout)
	dropper.nextOfType(protocol.TypeJoin, timeout)

	// No goodbye: just gone.
	dropper.conn.Close()

	watcher.expectNothingOfType(protocol.TypeLeave, 1*time.Second)
}

// TestSnapshotShowsPerMemberClientScopedCapabilities covers the question
// introspection most obviously invites once a player drops and is NOT held:
// why not. The answer is usually "that client never asked for resume.v1",
// which is a per-client fact and so cannot appear on the room's feature line.
func TestSnapshotShowsPerMemberClientScopedCapabilities(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), MaxClients: DefaultMaxClients}
	addr := startServerWith(t, s)

	resumable := dialFeatureClient(t, addr, "room1", "resumable",
		[]string{protocol.FeatureLeaseV1, protocol.FeatureResumeV1})
	defer resumable.conn.Close()
	wR := resumable.expectWelcome(timeout)

	// Same room-scoped set, no client-scoped extras — so it shares the room
	// but is NOT resumable, which is exactly the difference to surface.
	plain := dialFeatureClient(t, addr, "room1", "plain", []string{protocol.FeatureLeaseV1})
	defer plain.conn.Close()
	wP := plain.expectWelcome(timeout)

	room := s.Snapshot().Rooms[0]
	byID := map[string][]string{}
	for _, m := range room.Members {
		byID[m.PlayerID] = m.Features
	}
	if !protocol.HasFeature(byID[wR.PlayerID], protocol.FeatureResumeV1) {
		t.Fatalf("member %s shows features %v, want resume.v1", wR.PlayerID, byID[wR.PlayerID])
	}
	if len(byID[wP.PlayerID]) != 0 {
		t.Fatalf("member %s shows features %v, want none", wP.PlayerID, byID[wP.PlayerID])
	}
	// A room-scoped capability belongs on the room line, not repeated on every
	// member.
	if protocol.HasFeature(byID[wR.PlayerID], protocol.FeatureLeaseV1) {
		t.Fatalf("member line repeated the room-scoped lease.v1: %v", byID[wR.PlayerID])
	}
	if !protocol.HasFeature(room.Features, protocol.FeatureLeaseV1) {
		t.Fatalf("room features = %v, want lease.v1", room.Features)
	}
}

// suspend used to create the session's grace timer AFTER releasing s.mu, while
// forgetSessionsOf reads it under s.mu and takeSession reads it just after —
// an unsynchronised write against two guarded reads. It is reachable in the
// ordinary way, not a rare one: a client reconnecting with its token in the
// same instant the relay notices its old socket died is the quic takeover case
// takeSession's own doc comment calls routine.
//
// The consequence was mild (an un-stopped timer whose callback finds nothing to
// do), which is exactly why it needed a test rather than an argument — this is
// the class of bug CI's `-race` job exists for, and the one thing that reports
// it is the race detector. Locally this passes either way; on CI it does not.
func TestSuspendDoesNotRaceWithResumeOnTheSessionTimer(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), ResumeGrace: time.Minute}
	r := newRoom("emerald", "", "room1", nil)

	for i := 0; i < 200; i++ {
		token := fmt.Sprintf("tok-%d", i)
		c := &Client{PlayerID: fmt.Sprintf("p%d", i), Conn: &recordingTransport{}}
		r.tryAdd(c)
		s.registerSession(r, c.PlayerID, token, "")

		// All three of the paths that touch sess.timer, at once.
		var wg sync.WaitGroup
		wg.Add(3)
		go func() { defer wg.Done(); s.suspend(r, c, token) }()
		go func() { defer wg.Done(); s.takeSession(token, "room1", "emerald") }()
		go func() { defer wg.Done(); s.forgetSessionsOf(r, c.PlayerID) }()
		wg.Wait()
	}
}
