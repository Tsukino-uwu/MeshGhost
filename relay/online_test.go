package relay

// Tests for the planes past cosmetic. The invariants (one lease holder, one total order for every member,
// both-or-neither on an exchange) are asserted against many clients racing, not a tidy two-client sequence.

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

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

// nextOfType skips other types, so an unrelated Join cannot derail a test waiting on a LeaseState.
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

// Feature negotiation.

// TestRoomFeatureSetIsStickyAndMismatchIsRefused: a client that claims leases beside one that simply acts makes
// conflict resolution fail silently; refusing at the handshake makes it legible.
func TestRoomFeatureSetIsStickyAndMismatchIsRefused(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureLeaseV1})
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	if len(w1.Features) != 1 || w1.Features[0] != protocol.FeatureLeaseV1 {
		t.Fatalf("welcome features = %v, want [%s]", w1.Features, protocol.FeatureLeaseV1)
	}

	// "Declared nothing" is a value that has to match, unlike an undeclared game_version.
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

func TestEventDroppedWhenRoomDidNotNegotiateIt(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureLeaseV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	c1.send(protocol.TypeEvent, protocol.Event{Payload: json.RawMessage(`{"hi":1}`)})
	c1.expectNothingOfType(protocol.TypeEvent, 300*time.Millisecond)
}

// Event plane.

// TestEventBroadcastReachesEveryoneIncludingSender: the echo is the sender's only way to learn where its own action
// landed in the total order.
func TestEventBroadcastReachesEveryoneIncludingSender(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureEventV1})
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureEventV1})
	defer c2.conn.Close()
	c2.expectWelcome(timeout)

	// A forged From: the relay must overwrite it with the connection's assigned id, as for State.PlayerID.
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

// TestOversizedEventIsDroppedNotFragmented: an event past MaxEventBytes should have carried a reference to the data.
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
	// Everyone joins before anyone sends; client i hears later joiners as Joins, earlier ones in its Welcome.
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

	// The whole list, not just the stamps: consistent stamps delivered out of order would pass a weaker check.
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

// Leases.

// TestExactlyOneClaimantWinsAContestedLease: the relay judges arrival, not merit, and tells everyone one holder.
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

	// A fresh client, so this cannot read a lease_state still queued from the contest.
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

// TestLeaseReleaseFreesTheKeyForTheNextClaimant: a release is broadcast, since everyone needs to know a key is free.
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

// TestLeaseExpiresWithoutRenew: a holder that stops talking must not wedge a key, and without game knowledge only a
// clock can guarantee that.
func TestLeaseExpiresWithoutRenew(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureLeaseV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	// Less than MinLeaseTTL is clamped up to it rather than refused.
	c1.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "k", TTLMs: 1})
	if st := c1.expectLeaseState(timeout); st.Reason != protocol.LeaseGranted {
		t.Fatalf("claim = %+v, want granted", st)
	}
	st := c1.expectLeaseState(protocol.MinLeaseTTL + 2*time.Second)
	if st.Reason != protocol.LeaseExpired || st.Holder != "" {
		t.Fatalf("after the TTL got %+v, want the key free with reason %q", st, protocol.LeaseExpired)
	}
}

// TestLeaseIsFreedWhenItsHolderDisconnects: reported apart from an expiry, since an adapter may treat "hung up" and
// "went quiet" differently.
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

// Escrow.

func openEscrow(t *testing.T, a, b *testClient, id, withID string) {
	t.Helper()
	a.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowOpen, ID: id, With: withID})
	for _, tc := range []*testClient{a, b} {
		if st := tc.expectEscrowState(timeout); st.Phase != protocol.EscrowPhaseOpen {
			t.Fatalf("open phase = %q, want %q", st.Phase, protocol.EscrowPhaseOpen)
		}
	}
}

// TestEscrowRevealsBlobsOnlyOnCommit: otherwise the second depositor could choose its offer after seeing the first.
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
		// Both parties receive the identical map, so the swap is both-or-neither from each side.
		if string(st.Blobs[w1.PlayerID]) != `{"mon":"mudkip"}` || string(st.Blobs[w2.PlayerID]) != `{"mon":"torchic"}` {
			t.Fatalf("committed blobs = %v, want both parties' deposits", st.Blobs)
		}
	}
}

// TestEscrowAbortDiscardsBothBlobs: an abort destroys the deposits rather than delivering them, so a disconnect can
// trigger one safely.
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

// TestEscrowAbortsWhenAPartyDisconnects: an exchange whose counterparty is gone can never complete, and left open it
// holds the other side's deposit until the timeout.
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

// TestEscrowRefusesANonMemberCounterparty: an exchange with an id not in the room would sit pinned until its timeout.
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

// Late-join snapshot.

// TestLateJoinerIsSeededWithExistingPlayersState: without Join.State a newcomer sees nobody until each player moves.
func TestLateJoinerIsSeededWithExistingPlayersState(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureSnapshotV1})
	defer c1.conn.Close()
	w1 := c1.expectWelcome(timeout)
	c1.sendState(protocol.State{AreaID: "0:9", Position: []float64{4, 5}, Anim: "idle"})

	// No ordering point exists, so give the relay a moment to record the state before the second client joins.
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

// Session resumption.

// TestResumeKeepsThePlayerIDAndTheRoomNeverSeesALeave: a network blip must not cost the room a despawn and respawn.
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

	c1.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "k"})
	c1.expectLeaseState(timeout)
	c2.expectLeaseState(timeout)
	c1.conn.Close()

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
	if st := back.expectLeaseState(timeout); st.Holder != w1.PlayerID || st.Key != "k" {
		t.Fatalf("resumed client's lease snapshot = %+v, want it still holding \"k\"", st)
	}
	c2.expectNothingOfType(protocol.TypeJoin, 300*time.Millisecond)
}

// TestResumeGraceExpiryBecomesARealLeave: a player who is gone must free its keys and its slot.
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

// TestCommittedEscrowSurvivesAPartyCrashingBeforeItHearsTheOutcome: the exchange completes while alice is suspended,
// and on resume she must be told the outcome with both blobs, or both-or-neither holds only while sockets stay up.
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

	// A suspended party is not a departed one, so the exchange must not abort.
	alice.conn.Close()

	bob.send(protocol.TypeEscrow, protocol.Escrow{
		Op: protocol.EscrowDeposit, ID: "trade-1", Blob: json.RawMessage(`"bob-item"`),
	})
	bob.expectEscrowState(timeout)
	bob.send(protocol.TypeEscrow, protocol.Escrow{Op: protocol.EscrowCommit, ID: "trade-1"})

	st := bob.expectEscrowState(timeout)
	if st.Phase != protocol.EscrowPhaseCommitted {
		t.Fatalf("bob's phase = %q, want %q — a suspended party must not abort a live exchange", st.Phase, protocol.EscrowPhaseCommitted)
	}
	if string(st.Blobs[wA.PlayerID]) != `"alice-item"` {
		t.Fatalf("bob's committed blobs = %v, want alice's deposit included", st.Blobs)
	}

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

// TestEscrowAbortsIfACrashedPartyNeverComesBack: once the grace window closes, an exchange that can never complete
// releases the other side's deposit rather than holding it until the escrow timeout.
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

// TestStaleResumeTokenJoinsFreshRatherThanFailing: away too long costs a new identity, never the ability to play.
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

// Introspection.

// The snapshot never shows a resume token (a credential) or an escrow blob (a trade's contents).
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

	// The rendered form is what a host reads.
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

	// A suspended identity is the hardest state to diagnose without this.
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

// Room-scoped and client-scoped capabilities.

// TestClientScopedCapabilitiesDoNotSplitARoom: no peer takes part in a client-scoped capability, so there is nothing
// for the room to agree on.
func TestClientScopedCapabilitiesDoNotSplitARoom(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:      make(map[string]*Room),
		MaxClients: DefaultMaxClients,
	})

	plain := dialFeatureClient(t, addr, "room1", "plain", nil)
	defer plain.conn.Close()
	if w := plain.expectWelcome(timeout); len(w.Features) != 0 {
		t.Fatalf("cosmetic client's welcome carried features %v, want none", w.Features)
	}

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

	// The fancy client drops and resumes while the plain one, which never heard of resumption, sees nothing.
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

// TestRoomScopedCapabilityStillSplitsARoom: a capability peers take part in must still match exactly.
func TestRoomScopedCapabilityStillSplitsARoom(t *testing.T) {
	addr := startServer(t)

	c1 := dialFeatureClient(t, addr, "room1", "alice",
		[]string{protocol.FeatureLeaseV1, protocol.FeatureResumeV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	// Same client-scoped set, different room-scoped set.
	c2 := dialFeatureClient(t, addr, "room1", "bob", []string{protocol.FeatureResumeV1})
	defer c2.conn.Close()
	env := c2.next(timeout)
	if env.Type != protocol.TypeReject {
		t.Fatalf("a client missing the room's lease.v1 got %q, want a reject", env.Type)
	}

	// Differing only in a client-scoped capability.
	c3 := dialFeatureClient(t, addr, "room1", "carol", []string{protocol.FeatureLeaseV1})
	defer c3.conn.Close()
	if w := c3.expectWelcome(timeout); w.PlayerID == "" {
		t.Fatal("a client differing only in a client-scoped capability was refused")
	}
}

func TestSnapshotIsPerRecipientNotPerRoom(t *testing.T) {
	addr := startServer(t)

	mover := dialFeatureClient(t, addr, "room1", "mover", nil)
	defer mover.conn.Close()
	mover.expectWelcome(timeout)
	mover.sendState(protocol.State{AreaID: "0:9", Position: []float64{4, 5}})
	time.Sleep(100 * time.Millisecond)

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

	plain := dialFeatureClient(t, addr, "room1", "plain", nil)
	defer plain.conn.Close()
	plain.expectWelcome(timeout)
	plain.expectNothingOfType(protocol.TypeJoin, 300*time.Millisecond)
}

// TestResumeTakesOverAConnectionTheRelayHasNotNoticedIsDead: routine on quic, where a hard-killed peer sends no close
// and its connection lingers until the idle timeout, so the client reconnects while the old one still looks live.
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

	// Alice's connection stays open: the relay must still believe it live when the replacement arrives.
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

	// The resource side is TestTakeoverLeavesExactlyOneMemberAndOneSlot.
	bob.expectNothingOfType(protocol.TypeLeave, 400*time.Millisecond)
}

// TestTakeoverLeavesExactlyOneMemberAndOneSlot: the replaced connection leaves no member entry, slot or ghost behind.
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

	// The superseded connection's OnDisconnect fires asynchronously.
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

// TestVoluntaryLeaveIsImmediateEvenWithResumptionOn: a socket close cannot tell a deliberate exit from a bad
// connection, so a quitting client says goodbye and the room sees it leave at once.
func TestVoluntaryLeaveIsImmediateEvenWithResumptionOn(t *testing.T) {
	addr := startServerWith(t, &Server{
		rooms:      make(map[string]*Room),
		MaxClients: DefaultMaxClients,
		// Long enough that a suspension is unmistakable rather than racing the grace expiring.
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

	// Goodbye, then hang up: what the core does when its adapter goes away.
	quitter.send(protocol.TypeLeave, protocol.Leave{})
	time.Sleep(150 * time.Millisecond)
	quitter.conn.Close()

	env := watcher.nextOfType(protocol.TypeLeave, 3*time.Second)
	var leave protocol.Leave
	if err := json.Unmarshal(env.Payload, &leave); err != nil {
		t.Fatalf("unmarshal leave: %v", err)
	}
	if leave.PlayerID == "" {
		t.Fatal("leave named nobody")
	}
}

// TestUnexplainedDropStillGetsTheGraceWindow: only an explicit goodbye skips the grace.
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

	dropper.conn.Close()

	watcher.expectNothingOfType(protocol.TypeLeave, 1*time.Second)
}

// TestSnapshotShowsPerMemberClientScopedCapabilities: why a dropped player was not held is usually "it never asked
// for resume.v1", a per-client fact the room's feature line cannot show.
func TestSnapshotShowsPerMemberClientScopedCapabilities(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), MaxClients: DefaultMaxClients}
	addr := startServerWith(t, s)

	resumable := dialFeatureClient(t, addr, "room1", "resumable",
		[]string{protocol.FeatureLeaseV1, protocol.FeatureResumeV1})
	defer resumable.conn.Close()
	wR := resumable.expectWelcome(timeout)

	// Same room-scoped set and no client-scoped extras: shares the room, not resumable.
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
	// A room-scoped capability belongs on the room line, not on every member.
	if protocol.HasFeature(byID[wR.PlayerID], protocol.FeatureLeaseV1) {
		t.Fatalf("member line repeated the room-scoped lease.v1: %v", byID[wR.PlayerID])
	}
	if !protocol.HasFeature(room.Features, protocol.FeatureLeaseV1) {
		t.Fatalf("room features = %v, want lease.v1", room.Features)
	}
}

// TestSuspendDoesNotRaceWithResumeOnTheSessionTimer: suspend, takeSession and forgetSessionsOf all touch sess.timer,
// and a reconnect in the instant the relay notices the old socket died runs them together. Only -race reports it.
func TestSuspendDoesNotRaceWithResumeOnTheSessionTimer(t *testing.T) {
	s := &Server{rooms: make(map[string]*Room), ResumeGrace: time.Minute}
	r := newRoom("emerald", "", "room1", nil)

	for i := 0; i < 200; i++ {
		token := fmt.Sprintf("tok-%d", i)
		c := &Client{PlayerID: fmt.Sprintf("p%d", i), Conn: &recordingTransport{}}
		r.tryAdd(c)
		s.registerSession(r, c.PlayerID, token, "")

		var wg sync.WaitGroup
		wg.Add(3)
		go func() { defer wg.Done(); s.suspend(r, c, token) }()
		go func() { defer wg.Done(); s.takeSession(token, "room1", "emerald") }()
		go func() { defer wg.Done(); s.forgetSessionsOf(r, c.PlayerID) }()
		wg.Wait()
	}
}
