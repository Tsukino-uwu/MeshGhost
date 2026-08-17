package relay

// Tests for world custody. Four of these exist because the obvious
// implementation of this feature is wrong in four separate ways, and every one
// of them produces SILENT permanent divergence — no error anywhere, just two
// clients looking at different worlds. They are marked as such; if one starts
// failing, the answer is never to relax it.

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// worldFeatures is the minimum a room needs for this plane: custody plus the
// leases that gate every write.
var worldFeatures = []string{protocol.FeatureLeaseV1, protocol.FeatureWorldV1}

// recordingTransport captures every payload written to it, in write order.
// Ordering is the point of most of this file, so what matters is the ORDER
// Send was called in, not merely the set of messages that arrived.
type recordingTransport struct {
	mu sync.Mutex
	// delay is slept inside every write, to widen the window in which a
	// missing serialization point can show itself. Without it a race that is
	// real still needs an unlucky scheduler to appear.
	delay time.Duration
	// block, when non-nil, holds the first write until it is closed.
	block   chan struct{}
	blocked bool
	got     [][]byte
}

func (rt *recordingTransport) Send(payload []byte) error {
	rt.mu.Lock()
	if rt.block != nil && !rt.blocked {
		rt.blocked = true
		ch := rt.block
		rt.mu.Unlock()
		<-ch
		rt.mu.Lock()
	}
	delay := rt.delay
	cp := append([]byte(nil), payload...)
	rt.got = append(rt.got, cp)
	rt.mu.Unlock()
	if delay > 0 {
		time.Sleep(delay)
	}
	return nil
}

func (rt *recordingTransport) SendUnreliable(payload []byte) error { return rt.Send(payload) }
func (rt *recordingTransport) OnReceive(func([]byte))              {}
func (rt *recordingTransport) OnDisconnect(func(error))            {}
func (rt *recordingTransport) OnError(func(error))                 {}
func (rt *recordingTransport) Close() error                        { return nil }

// received returns the envelopes captured so far, in write order.
func (rt *recordingTransport) received(t *testing.T) []protocol.Envelope {
	t.Helper()
	rt.mu.Lock()
	defer rt.mu.Unlock()
	out := make([]protocol.Envelope, 0, len(rt.got))
	for _, b := range rt.got {
		var env protocol.Envelope
		if err := json.Unmarshal(b, &env); err != nil {
			t.Fatalf("unmarshal captured envelope: %v", err)
		}
		out = append(out, env)
	}
	return out
}

// worldStates returns just the world messages, decoded, in write order.
func (rt *recordingTransport) worldStates(t *testing.T) []protocol.WorldState {
	t.Helper()
	var out []protocol.WorldState
	for _, env := range rt.received(t) {
		if env.Type != protocol.TypeWorldState {
			continue
		}
		var st protocol.WorldState
		if err := json.Unmarshal(env.Payload, &st); err != nil {
			t.Fatalf("unmarshal world_state: %v", err)
		}
		out = append(out, st)
	}
	return out
}

// worldRoom builds a room with the world plane on and the named members
// already in it, returning each member's recorder.
func worldRoom(t *testing.T, features []string, ids ...string) (*Room, map[string]*recordingTransport) {
	t.Helper()
	r := newRoom("emerald", "", "room1", features)
	rts := make(map[string]*recordingTransport, len(ids))
	for _, id := range ids {
		rt := &recordingTransport{}
		rts[id] = rt
		r.tryAdd(&Client{PlayerID: id, Conn: rt})
	}
	return r, rts
}

func blob(s string) json.RawMessage {
	b, _ := json.Marshal(map[string]string{"v": s})
	return b
}

// setWorld is one reliable set, the ordinary way a key is created.
func setWorld(r *Room, from, authority, key, value string) {
	r.handleWorld(from, protocol.World{
		Op: protocol.WorldSet, Authority: authority, Key: key, Blob: blob(value), Reliable: true,
	})
}

func worldKeysOf(r *Room) []string {
	r.mu.Lock()
	defer r.mu.Unlock()
	out := make([]string, 0, len(r.world))
	for wk := range r.world {
		out = append(out, wk.authority+"/"+wk.key)
	}
	return out
}

// ---------------------------------------------------------------------------
// The four corrections. Each of these fails against the obvious design.
// ---------------------------------------------------------------------------

// TestLossyWorldWriteIsOrderedAgainstAReliableDrop is the wire-visible form of
// "Reliable selects the delivery variant ONLY, never the serialization".
//
// The tempting design is that a lossy write skips sendMu the way the state
// plane does. It cannot, and the failure is silent: a lossy set can be stamped
// first and delivered second, so the relay's map holds one value while every
// client's last-received is a different one — and nothing ever corrects it,
// because snapshots go only to joiners and a key may never be written again. A
// drop overtaken by a stale set is worse still: the entity is resurrected
// permanently for everyone but the relay.
//
// Asserted as strictly increasing stamps in DELIVERY order, under concurrent
// writers, with a delay inside every write to widen the window. Worth running
// with -count=10 -race, per agent_docs/testing.md.
func TestLossyWorldWriteIsOrderedAgainstAReliableDrop(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1", "p2")
	watcher := rts["p2"]
	watcher.delay = 200 * time.Microsecond

	r.sendMu.Lock()
	r.mu.Lock()
	r.leases = map[string]*lease{"sim": {holder: "p1", expiresAt: time.Now().Add(time.Minute)}}
	r.mu.Unlock()
	r.sendMu.Unlock()

	// Create the keys first: a lossy write may not create one.
	for i := 0; i < 4; i++ {
		setWorld(r, "p1", "sim", fmt.Sprintf("e%d", i), "initial")
	}

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		key := fmt.Sprintf("e%d", i)
		wg.Add(1)
		go func() {
			defer wg.Done()
			for n := 0; n < 20; n++ {
				// Alternating lossy motion and a reliable drop/recreate: the
				// exact mix the serialization has to hold together.
				r.handleWorld("p1", protocol.World{
					Op: protocol.WorldSet, Authority: "sim", Key: key,
					Blob: blob("moving"), Reliable: false,
				})
				if n%7 == 6 {
					r.handleWorld("p1", protocol.World{
						Op: protocol.WorldDrop, Authority: "sim", Key: key, Reliable: true,
					})
					setWorld(r, "p1", "sim", key, "respawned")
				}
			}
		}()
	}
	wg.Wait()

	states := watcher.worldStates(t)
	if len(states) < 50 {
		t.Fatalf("watcher received only %d world messages, too few to prove anything", len(states))
	}
	var last uint64
	for i, st := range states {
		if st.Seq <= last {
			t.Fatalf("world message %d arrived with seq %d after already delivering %d "+
				"-- the relay's stamp order and its delivery order have come apart, so a stale "+
				"write can permanently overwrite a newer one", i, st.Seq, last)
		}
		last = st.Seq
	}
}

// TestWorldSurvivesItsAuthorityLeaseExpiring is one third of "never tie world
// lifetime to lease lifetime".
//
// Freeing entries in freeLeaseLocked is the obvious wrong turn, and it destroys
// the world in exactly the case the feature exists for: a host crashing arrives
// there via expireSuspended -> finishLeave -> releaseLeasesOfLocked.
func TestWorldSurvivesItsAuthorityLeaseExpiring(t *testing.T) {
	r, _ := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")

	// Wind the expiry into the past and fire the callback by hand, rather than
	// waiting out a real TTL — expireLease re-checks the clock, so this is the
	// same code path a timer takes.
	r.mu.Lock()
	r.leases["sim"].expiresAt = time.Now().Add(-time.Second)
	r.mu.Unlock()
	r.expireLease("sim", "p1")

	r.mu.Lock()
	held := len(r.leases)
	entities := len(r.world)
	r.mu.Unlock()
	if held != 0 {
		t.Fatalf("lease still held after expiry, got %d", held)
	}
	if entities != 1 {
		t.Fatalf("world had %d entities after the authority lease expired, want 1 "+
			"-- an expiring lease must not destroy the world its successor is meant to adopt",
			entities)
	}
}

// TestWorldSurvivesACleanRelease: a host handing off DELIBERATELY still wants
// the world to reach its successor. This is the case a crash test would miss.
func TestWorldSurvivesACleanRelease(t *testing.T) {
	r, _ := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseRelease, Key: "sim"})

	if got := worldKeysOf(r); len(got) != 1 {
		t.Fatalf("world held %v after a clean release, want the entity to survive", got)
	}
}

// TestWorldSurvivesTheHolderDisconnecting is the case custody exists for at
// all: the host is gone and a successor must find the world where it was left.
func TestWorldSurvivesTheHolderDisconnecting(t *testing.T) {
	s := NewServer()
	r, _ := worldRoom(t, worldFeatures, "p1", "p2")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")

	s.finishLeave(r, "p1")

	if got := worldKeysOf(r); len(got) != 1 {
		t.Fatalf("world held %v after the holder left, want the entity to survive for its successor", got)
	}
	r.mu.Lock()
	_, stillLeased := r.leases["sim"]
	r.mu.Unlock()
	if stillLeased {
		t.Fatal("the authority lease was not released when its holder left")
	}
}

// TestLateJoinWorldSeedIsNotOvertakenByAConcurrentWrite covers the latent bug
// this feature exposes: handleConn's old seed block took r.mu and delivered
// WITHOUT sendMu.
//
// State got away with that because a stale seed self-corrects within 50ms — the
// next sample from that player overwrites it. A world seed does not: delivered
// after a concurrently-broadcast newer write, it leaves the joiner permanently
// stale with nothing to correct it. joinSnapshot must therefore serialize
// against an in-flight broadcast, which is what this asserts: while a broadcast
// is stalled mid-delivery, a join seed must not slip past it.
func TestLateJoinWorldSeedIsNotOvertakenByAConcurrentWrite(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1", "p2")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")

	// p2's transport blocks on its next write, so the broadcast below is
	// caught mid-delivery with sendMu held.
	rts["p2"].block = make(chan struct{})

	joiner := &recordingTransport{}
	r.tryAdd(&Client{PlayerID: "p3", Conn: joiner})

	broadcastStarted := make(chan struct{})
	broadcastDone := make(chan struct{})
	go func() {
		close(broadcastStarted)
		setWorld(r, "p1", "sim", "boss", "newer")
		close(broadcastDone)
	}()
	<-broadcastStarted
	time.Sleep(100 * time.Millisecond)

	seedDone := make(chan struct{})
	go func() {
		r.joinSnapshot("p3")
		close(seedDone)
	}()

	select {
	case <-seedDone:
		t.Fatal("the join seed was built and delivered while a world broadcast was still in flight " +
			"-- it can therefore be delivered after a newer write and leave the joiner permanently stale")
	case <-time.After(200 * time.Millisecond):
	}

	close(rts["p2"].block)
	<-broadcastDone
	select {
	case <-seedDone:
	case <-time.After(timeout):
		t.Fatal("the join seed never completed after the broadcast finished")
	}

	// p3 was already a member, so it also received the broadcast. What matters
	// is that the seed it eventually got came AFTER that broadcast in the total
	// order and carries the newer value -- a seed built before it and delivered
	// after would silently revert this client and nothing would correct it.
	states := joiner.worldStates(t)
	if len(states) != 2 {
		t.Fatalf("joiner got %d world messages, want the broadcast and then its seed", len(states))
	}
	seed := states[1]
	if seed.Reason != protocol.WorldSnapshot {
		t.Fatalf("the second message was %q, want the seed to come last", seed.Reason)
	}
	if seed.Seq <= states[0].Seq {
		t.Fatalf("the seed was stamped %d, behind the broadcast at %d", seed.Seq, states[0].Seq)
	}
	if len(seed.Entries) != 1 || !strings.Contains(string(seed.Entries[0].Blob), "newer") {
		t.Fatalf("joiner was seeded with %+v, want the newer value", seed.Entries)
	}
}

// ---------------------------------------------------------------------------
// Authority
// ---------------------------------------------------------------------------

// TestStaleHostCannotWriteAfterHandover is the whole reason writes are
// lease-gated: a departing host's in-flight packets must not overwrite the new
// host's world after handover.
func TestStaleHostCannotWriteAfterHandover(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1", "p2")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "from-p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseRelease, Key: "sim"})
	r.handleLease("p2", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})

	before := len(rts["p2"].worldStates(t))
	setWorld(r, "p1", "sim", "boss", "stale-from-p1")

	// The relay's copy is untouched.
	r.mu.Lock()
	got := string(r.world[worldKey{authority: "sim", key: "boss"}].blob)
	r.mu.Unlock()
	if strings.Contains(got, "stale") {
		t.Fatalf("a stale host's write was stored: %s", got)
	}
	// Nobody else heard it.
	if after := len(rts["p2"].worldStates(t)); after != before {
		t.Fatalf("the new holder received %d world messages from the stale host, want 0", after-before)
	}
	// And the stale host was told, rather than left believing its writes land.
	denials := rts["p1"].worldStates(t)
	last := denials[len(denials)-1]
	if last.Reason != protocol.WorldDenied {
		t.Fatalf("stale host's last world message was %q, want %q", last.Reason, protocol.WorldDenied)
	}
	if last.Holder != "p2" {
		t.Fatalf("denial named holder %q, want p2 -- it should say who actually has the authority now", last.Holder)
	}
}

// TestWorldWriteWithoutTheLeaseIsDenied covers the ordinary case: a client that
// never claimed at all.
func TestWorldWriteWithoutTheLeaseIsDenied(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1")
	setWorld(r, "p1", "sim", "boss", "alive")

	if got := worldKeysOf(r); len(got) != 0 {
		t.Fatalf("a write with no lease at all was stored: %v", got)
	}
	states := rts["p1"].worldStates(t)
	if len(states) != 1 || states[0].Reason != protocol.WorldDenied {
		t.Fatalf("got %+v, want a single denial", states)
	}
}

// TestAdoptionIntoAnEmptyWorldStillSendsOneSnapshot is the assertion whose
// absence would let a regression pass EVERYTHING.
//
// A new holder has to know when it may start writing. Until its adoption has
// landed it cannot tell "there is nothing to adopt" from "what I am about to
// overwrite has not arrived yet", and a host that guesses wrong writes
// generation 1 over a world already at generation 2 — a rollback, silent, and
// permanent. So an adoption sends exactly one snapshot even when the world is
// empty, and "empty" is the case an implementation naturally optimises away.
//
// **Nothing else catches that.** Every other test in this file uses a non-empty
// world, so all of them would still pass. Worse, the soak rig would report zero
// invariant violations rather than a failure, because
// cmd/meshghost-fakeadapter's isHolder refuses to write until its adoption has
// landed — so it would simply never write anything, and a run that exercised
// nothing looks exactly like a run that passed. Same shape as CLAUDE.md's rule
// about a diagnostic that breaks the thing it measures.
func TestAdoptionIntoAnEmptyWorldStillSendsOneSnapshot(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})

	states := rts["p1"].worldStates(t)
	if len(states) != 1 {
		t.Fatalf("taking an authority over an empty world produced %d world messages, want exactly "+
			"1 -- without it a new host cannot tell an empty world from an adoption still in "+
			"flight, and writes over a world it has not seen", len(states))
	}
	if states[0].Reason != protocol.WorldSnapshot {
		t.Fatalf("got reason %q, want %q", states[0].Reason, protocol.WorldSnapshot)
	}
	if len(states[0].Entries) != 0 {
		t.Fatalf("the snapshot carried %+v, want nothing", states[0].Entries)
	}
	if states[0].Holder != "p1" {
		t.Fatalf("the snapshot named holder %q, want p1", states[0].Holder)
	}
}

// TestHandoverSnapshotIsSentOnlyWhenTheHolderChanges. A renew, and a re-claim
// by the current holder, must produce none — otherwise the busiest client's
// whole world goes back on the wire at its own renew rate.
func TestHandoverSnapshotIsSentOnlyWhenTheHolderChanges(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")

	// One already, from the grant above: the adoption snapshot into what was
	// then an empty world. Asserted rather than merely used as a baseline, so
	// this test cannot silently start measuring from zero.
	before := len(rts["p1"].worldStates(t))
	if before != 1 {
		t.Fatalf("expected exactly the adoption snapshot before the renew, got %d messages", before)
	}
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseRenew, Key: "sim"})
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	if after := len(rts["p1"].worldStates(t)); after != before {
		t.Fatalf("a renew and a re-claim produced %d extra world messages, want 0", after-before)
	}
}

// TestAdoptionSnapshotFollowsTheGrantWithNothingBetween is the wire-visible
// form of "the snapshot must be built inside grantLeaseLocked".
//
// If it were dispatched afterwards, the new holder could receive its grant,
// legally begin writing, and only then receive a snapshot built before its own
// writes — reverting itself, with the relay's map correct and the new host
// stale. Contiguity in the delivery order is what proves it was not.
func TestAdoptionSnapshotFollowsTheGrantWithNothingBetween(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1", "p2")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseRelease, Key: "sim"})
	r.handleLease("p2", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})

	envs := rts["p2"].received(t)
	grantAt := -1
	for i, env := range envs {
		if env.Type != protocol.TypeLeaseState {
			continue
		}
		var st protocol.LeaseState
		if err := json.Unmarshal(env.Payload, &st); err != nil {
			t.Fatalf("unmarshal lease_state: %v", err)
		}
		if st.Reason == protocol.LeaseGranted && st.Holder == "p2" {
			grantAt = i
		}
	}
	if grantAt < 0 {
		t.Fatal("p2 never saw its own grant")
	}
	if grantAt+1 >= len(envs) {
		t.Fatal("p2 was granted the authority and never received the world it was meant to adopt")
	}
	next := envs[grantAt+1]
	if next.Type != protocol.TypeWorldState {
		t.Fatalf("the message after the grant was %q, want a world snapshot immediately after it", next.Type)
	}
	var snap protocol.WorldState
	if err := json.Unmarshal(next.Payload, &snap); err != nil {
		t.Fatalf("unmarshal world_state: %v", err)
	}
	if snap.Reason != protocol.WorldSnapshot {
		t.Fatalf("got reason %q, want %q", snap.Reason, protocol.WorldSnapshot)
	}
	if len(snap.Entries) != 1 || snap.Entries[0].Key != "boss" {
		t.Fatalf("adoption snapshot carried %+v, want the one entity that existed", snap.Entries)
	}
	if snap.Holder != "p2" {
		t.Fatalf("adoption snapshot named holder %q, want p2", snap.Holder)
	}
}

// ---------------------------------------------------------------------------
// Ordinary coverage
// ---------------------------------------------------------------------------

// TestWorldDroppedWhenRoomDidNotNegotiateIt: no capability, no plane. A room
// that never asked for custody must never run a line of it.
func TestWorldDroppedWhenRoomDidNotNegotiateIt(t *testing.T) {
	addr := startServer(t)
	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureLeaseV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	c1.send(protocol.TypeLease, protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	c1.expectLeaseState(timeout)
	c1.send(protocol.TypeWorld, protocol.World{
		Op: protocol.WorldSet, Authority: "sim", Key: "boss", Blob: blob("alive"), Reliable: true,
	})
	c1.expectNothingOfType(protocol.TypeWorldState, 250*time.Millisecond)
}

// TestWorldWithoutLeasesIsAnnouncedRatherThanSilent. The combination is
// incoherent — every write names an authority that cannot exist — and is
// deliberately NOT made to imply lease.v1, since that would change the sticky
// feature-set key and silently stop matching rooms that already agreed on the
// old one.
func TestWorldWithoutLeasesIsAnnouncedRatherThanSilent(t *testing.T) {
	addr := startServer(t)
	c1 := dialFeatureClient(t, addr, "room1", "alice", []string{protocol.FeatureWorldV1})
	defer c1.conn.Close()
	c1.expectWelcome(timeout)

	c1.send(protocol.TypeWorld, protocol.World{
		Op: protocol.WorldSet, Authority: "sim", Key: "boss", Blob: blob("alive"), Reliable: true,
	})
	c1.expectNothingOfType(protocol.TypeWorldState, 250*time.Millisecond)
}

// TestOversizedWorldBlobIsDroppedNotFragmented. Same answer an oversized event
// gets: an entity that does not fit means the blob should be a reference to the
// data rather than the data.
func TestOversizedWorldBlobIsDroppedNotFragmented(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1", "p2")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})

	huge, err := json.Marshal(strings.Repeat("x", protocol.MaxWorldBlobBytes+1))
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	req := protocol.World{Op: protocol.WorldSet, Authority: "sim", Key: "boss", Blob: huge, Reliable: true}
	if protocol.ValidateWorld(req) {
		t.Fatal("ValidateWorld accepted an oversized blob")
	}
	// The relay never sees it, so nothing is stored and nothing is sent.
	if got := worldKeysOf(r); len(got) != 0 {
		t.Fatalf("world held %v", got)
	}
	if got := rts["p2"].worldStates(t); len(got) != 0 {
		t.Fatalf("a peer received %d world messages for a write that never passed validation", len(got))
	}
}

// TestWorldCapDeniesRatherThanDroppingSilently, and an overwrite at the cap
// still succeeds — the bound is on distinct keys, not on writes.
func TestWorldCapDeniesRatherThanDroppingSilently(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	for i := 0; i < protocol.MaxWorldKeysPerRoom; i++ {
		setWorld(r, "p1", "sim", fmt.Sprintf("e%d", i), "alive")
	}

	before := len(rts["p1"].worldStates(t))
	setWorld(r, "p1", "sim", "one-too-many", "alive")
	states := rts["p1"].worldStates(t)
	if len(states) != before+1 {
		t.Fatalf("a refused write produced %d messages, want exactly one denial", len(states)-before)
	}
	if got := states[len(states)-1].Reason; got != protocol.WorldTooMany {
		t.Fatalf("got reason %q, want %q -- silence would leave a host believing it spawned "+
			"an entity nobody has", got, protocol.WorldTooMany)
	}

	// Overwriting an existing key at the cap is fine.
	setWorld(r, "p1", "sim", "e0", "updated")
	r.mu.Lock()
	got := string(r.world[worldKey{authority: "sim", key: "e0"}].blob)
	r.mu.Unlock()
	if !strings.Contains(got, "updated") {
		t.Fatalf("an overwrite at the cap was refused: %s", got)
	}
}

// TestLossyWriteCannotCreateAKey. Creation and deletion must travel the same
// ordered plane, or a create dispatched before a drop can arrive after it and
// resurrect the entity permanently — the relay's map has it deleted, so no
// snapshot ever contradicts the resurrection.
func TestLossyWriteCannotCreateAKey(t *testing.T) {
	r, _ := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})

	r.handleWorld("p1", protocol.World{
		Op: protocol.WorldSet, Authority: "sim", Key: "boss", Blob: blob("alive"), Reliable: false,
	})
	if got := worldKeysOf(r); len(got) != 0 {
		t.Fatalf("a lossy write created %v -- creation must be reliable", got)
	}

	// Created reliably, it then updates lossily just fine.
	setWorld(r, "p1", "sim", "boss", "alive")
	r.handleWorld("p1", protocol.World{
		Op: protocol.WorldSet, Authority: "sim", Key: "boss", Blob: blob("moved"), Reliable: false,
	})
	r.mu.Lock()
	got := string(r.world[worldKey{authority: "sim", key: "boss"}].blob)
	r.mu.Unlock()
	if !strings.Contains(got, "moved") {
		t.Fatalf("a lossy update to an existing key was refused: %s", got)
	}
}

// TestTwoAuthoritiesMaySharreAKey: entries are namespaced by authority, because
// two authorities colliding on one key has no defined resolution and picking
// one would make the relay adjudicate game content.
func TestTwoAuthoritiesMaySharreAKey(t *testing.T) {
	r, _ := worldRoom(t, worldFeatures, "p1", "p2")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim-a"})
	r.handleLease("p2", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim-b"})
	setWorld(r, "p1", "sim-a", "boss", "from-a")
	setWorld(r, "p2", "sim-b", "boss", "from-b")

	r.mu.Lock()
	a := string(r.world[worldKey{authority: "sim-a", key: "boss"}].blob)
	b := string(r.world[worldKey{authority: "sim-b", key: "boss"}].blob)
	r.mu.Unlock()
	if !strings.Contains(a, "from-a") || !strings.Contains(b, "from-b") {
		t.Fatalf("the two authorities' entries collided: %s / %s", a, b)
	}
}

// TestWriterIsExcludedFromItsOwnWorldBroadcast. Unlike an event — where the
// echo is how a sender learns its own stamp — the host is by definition the
// authoritative source, and echoing would double the busiest client's inbound.
func TestWriterIsExcludedFromItsOwnWorldBroadcast(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1", "p2")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")

	// p1 gets exactly one message: the adoption snapshot its own grant produced,
	// which is empty because the world was empty at that point. What it must
	// never get is its own write echoed back. The count is asserted as well as
	// the contents — a bare loop over the messages would pass just as happily on
	// zero of them, which is the regression
	// TestAdoptionIntoAnEmptyWorldStillSendsOneSnapshot exists to catch.
	own := rts["p1"].worldStates(t)
	if len(own) != 1 {
		t.Fatalf("the writer received %d world messages, want exactly its own adoption snapshot",
			len(own))
	}
	for _, st := range own {
		if st.Reason != protocol.WorldSnapshot {
			t.Fatalf("the writer received a %q message about its own write, want only its "+
				"adoption snapshot", st.Reason)
		}
		if len(st.Entries) != 0 {
			t.Fatalf("the writer's adoption snapshot carried %+v, want nothing -- the world was "+
				"empty when it took the authority", st.Entries)
		}
	}
	if got := len(rts["p2"].worldStates(t)); got != 1 {
		t.Fatalf("the peer received %d world messages, want 1", got)
	}
}

// TestWorldSeedIsNotGatedOnSnapshotV1. world.v1 is room-scoped, so every member
// has it by construction; copying stateSnapshotLocked's per-recipient gate
// wholesale would silently leave late joiners looking at an empty world.
func TestWorldSeedIsNotGatedOnSnapshotV1(t *testing.T) {
	r, _ := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")

	// A joiner that did NOT ask for snapshot.v1.
	joiner := &recordingTransport{}
	r.tryAdd(&Client{PlayerID: "p2", Conn: joiner})
	r.joinSnapshot("p2")

	states := joiner.worldStates(t)
	if len(states) != 1 || len(states[0].Entries) != 1 {
		t.Fatalf("a joiner without snapshot.v1 got %+v, want the room's world", states)
	}
}

// TestResumingClientIsSentTheWorld: a resuming non-host has missed every lossy
// write it was away for, and nothing else will ever resend them.
func TestResumingClientIsSentTheWorld(t *testing.T) {
	r, rts := worldRoom(t, worldFeatures, "p1", "p2")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")

	before := len(rts["p2"].worldStates(t))
	r.resumeSnapshot("p2")
	states := rts["p2"].worldStates(t)
	if len(states) != before+1 || states[len(states)-1].Reason != protocol.WorldSnapshot {
		t.Fatalf("a resuming client got %d extra world messages, want one snapshot", len(states)-before)
	}
}

// TestIntrospectionShowsWorldSizeButNeverBlobs. Same posture as escrow blobs:
// a debugging aid must not become a way to read the contents of a room.
func TestIntrospectionShowsWorldSizeButNeverBlobs(t *testing.T) {
	r, _ := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "a-secret-value")

	snap := r.snapshot(time.Now())
	if len(snap.World) != 1 {
		t.Fatalf("snapshot showed %d entities, want 1", len(snap.World))
	}
	if snap.World[0].BlobBytes == 0 || snap.World[0].Seq == 0 {
		t.Fatalf("snapshot showed %+v, want a byte size and a stamp", snap.World[0])
	}
	rendered := Snapshot{Rooms: []RoomSnapshot{snap}}.String()
	if strings.Contains(rendered, "a-secret-value") {
		t.Fatalf("the rendered snapshot leaked a blob's contents:\n%s", rendered)
	}
	if !strings.Contains(rendered, "world \"sim\"") {
		t.Fatalf("the rendered snapshot did not mention the world at all:\n%s", rendered)
	}
}

// TestOrphanedWorldIsCalledOutInIntrospection. A world nobody holds is the
// state custody exists to produce, not a fault, and someone reading the log
// while wondering why nobody is simulating needs that difference stated.
func TestOrphanedWorldIsCalledOutInIntrospection(t *testing.T) {
	r, _ := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	setWorld(r, "p1", "sim", "boss", "alive")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseRelease, Key: "sim"})

	rendered := Snapshot{Rooms: []RoomSnapshot{r.snapshot(time.Now())}}.String()
	if !strings.Contains(rendered, "NOBODY holds this authority") {
		t.Fatalf("an orphaned world was not called out:\n%s", rendered)
	}
}

// TestWorldSnapshotIsBatchedNotFragmented. A full room's world does not fit one
// datagram, so it is split — and every message it splits into must be
// independently complete and applicable, with no reassembly anywhere.
func TestWorldSnapshotIsBatchedNotFragmented(t *testing.T) {
	r, _ := worldRoom(t, worldFeatures, "p1")
	r.handleLease("p1", protocol.Lease{Op: protocol.LeaseClaim, Key: "sim"})
	big := json.RawMessage(`"` + strings.Repeat("x", protocol.MaxWorldBlobBytes-16) + `"`)
	for i := 0; i < protocol.MaxWorldKeysPerRoom; i++ {
		r.handleWorld("p1", protocol.World{
			Op: protocol.WorldSet, Authority: "sim", Key: fmt.Sprintf("e%02d", i),
			Blob: big, Reliable: true,
		})
	}

	joiner := &recordingTransport{}
	r.tryAdd(&Client{PlayerID: "p2", Conn: joiner})
	r.joinSnapshot("p2")

	states := joiner.worldStates(t)
	if len(states) < 2 {
		t.Fatalf("a full world produced %d messages -- expected it to batch across several", len(states))
	}
	seen := map[string]bool{}
	for i, st := range states {
		if len(st.Entries) == 0 {
			t.Fatalf("message %d carried no entries", i)
		}
		if st.Reason != protocol.WorldSnapshot || st.Authority != "sim" {
			t.Fatalf("message %d was not a self-describing snapshot: %+v", i, st)
		}
		for _, e := range st.Entries {
			if seen[e.Key] {
				t.Fatalf("key %q appeared in two messages -- entries must never be split", e.Key)
			}
			seen[e.Key] = true
			if len(e.Blob) != len(big) {
				t.Fatalf("key %q arrived with %d blob bytes, want %d -- an entry was split",
					e.Key, len(e.Blob), len(big))
			}
		}
	}
	if len(seen) != protocol.MaxWorldKeysPerRoom {
		t.Fatalf("the batched snapshot carried %d entities, want %d", len(seen), protocol.MaxWorldKeysPerRoom)
	}
}
