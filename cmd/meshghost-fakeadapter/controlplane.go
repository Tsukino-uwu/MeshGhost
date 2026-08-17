package main

// The control-plane half of the synthetic-peer rig: N fake clients driving
// events, leases and escrow exchanges at each other while continuously
// checking the invariants those planes exist to provide.
//
// **This is a checker, not just a traffic generator, and that distinction is
// the whole point.** internal/relay's tests already prove the invariants hold
// for a handful of clients over a few seconds on loopback. What they cannot
// reach is a long run, at real client counts, over a real transport, through
// cmd/meshghost-netsim's loss and jitter — which is exactly the shape of bug
// agent_docs/testing.md says concurrency produces: fine in 100 runs, wrong in
// the 101st, and invisible unless something was asserting the whole time.
// Generating traffic and eyeballing the log would find only the failures loud
// enough to crash something.
//
// Three invariants are checked, one per plane:
//
//  1. **Ordering** — every control message a client receives carries a strictly
//     larger sequencer stamp than the last. The relay serializes stamping and
//     delivery per room, so a client seeing 3 before 2 means that serialization
//     broke. This is the check that caught the original ordering defect when
//     the planes were first built.
//  2. **Exclusivity** — a key is granted to a second holder only after the
//     first one gave it up. Anything else means the relay handed one key to two
//     clients, which is the single failure lease authority exists to prevent.
//  3. **Termination** — every exchange reaches `committed` or `aborted`. A
//     trade that simply stops is the hostage case: both deposits pinned, with
//     nothing on either side saying so.
//
// Violations are logged the moment they happen (with enough context to be
// actionable) and counted, and a run that saw any exits non-zero — so this can
// sit in a script or a soak job rather than needing someone to read it.

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"meshghost/internal/core"
	"meshghost/internal/protocol"
)

// violations counts invariant failures across every synthetic client in this
// process. Process-wide rather than per-client because the exit code is, and
// because a violation is a property of the run, not of whichever client
// happened to notice it.
var violations atomic.Uint64

func reportViolation(format string, args ...any) {
	violations.Add(1)
	log.Printf("meshghost-fakeadapter: INVARIANT VIOLATION: "+format, args...)
}

// controlPlane drives and checks one synthetic client's control-plane traffic.
type controlPlane struct {
	core  *core.Core
	index int
	// selfID is this client's relay-assigned player_id, captured once after
	// the handshake. Used to tell its own echoed events from everyone else's,
	// and to pick a deterministic trade partner.
	selfID string

	mu sync.Mutex
	// lastSeq is the highest sequencer stamp seen. Invariant 1 compares
	// against it across events, lease states and escrow states alike: they
	// share one room counter, so a single client's view of all three must be
	// strictly increasing even though it sees only a subset of the messages.
	lastSeq uint64
	// leaseHolder is who this client currently believes holds each key.
	//
	// **Per key, not one holder overall.** It was a single string while the rig
	// only ever contended for one key; once the world plane added a second
	// (its authority), grants for the two keys alternated and invariant 2
	// reported "two holders of one key" about a relay behaving perfectly.
	// Found 2026-08-17 the first time both planes ran together.
	leaseHolder map[string]string
	// peers is every other player_id this client has heard from, learned from
	// event senders rather than the roster — the core deliberately does not
	// expose a roster, and learning peers from traffic exercises the event
	// plane instead of adding an API for the rig's convenience.
	peers map[string]bool
	// openExchanges maps an exchange id to when it started, so invariant 3 can
	// notice one that never finished.
	openExchanges map[string]time.Time

	// world is the world-custody checker, or nil when that plane is off. Its
	// own type in world.go rather than more fields here: it has five
	// invariants of its own and shares nothing with the three above beyond
	// the sequencer stamp, which checkSeq already covers for every plane.
	world *worldChecker

	eventsSeen  atomic.Uint64
	claimsWon   atomic.Uint64
	claimsLost  atomic.Uint64
	tradesDone  atomic.Uint64
	tradesGone  atomic.Uint64
	nextTradeNo atomic.Uint64
}

// newControlPlane builds a checker. Wiring it to a Core is a separate step
// (attach) so the checkers can be tested without one — a checker with no test
// of its own passes forever, including on every run where the thing it was
// watching was broken.
func newControlPlane(index int) *controlPlane {
	return &controlPlane{
		index:         index,
		peers:         make(map[string]bool),
		leaseHolder:   make(map[string]string),
		openExchanges: make(map[string]time.Time),
	}
}

// attach wires this checker to a connected Core and captures its assigned
// player_id. Called after the handshake, since selfID does not exist before
// then and is what tells this client's own echoed events from everyone else's.
func (cp *controlPlane) attach(c *core.Core) {
	cp.core = c
	cp.selfID = c.PlayerID()
	c.OnEvent = cp.onEvent
	c.OnLeaseState = cp.onLeaseState
	c.OnEscrowState = cp.onEscrowState
	if cp.world != nil {
		cp.world.self = cp.selfID
		c.OnWorldState = cp.world.onWorldState
	}
}

// checkSeq is invariant 1. Caller must not hold cp.mu.
func (cp *controlPlane) checkSeq(kind string, seq uint64) {
	if seq == 0 {
		// Unstamped. Only reachable from a relay that predates the sequencer,
		// which cannot happen in a run this rig set up — worth saying rather
		// than silently treating as ordered.
		reportViolation("client %d received an unstamped %s (seq=0)", cp.index, kind)
		return
	}
	cp.mu.Lock()
	defer cp.mu.Unlock()
	if seq <= cp.lastSeq {
		reportViolation("client %d received %s with seq %d after already seeing %d "+
			"-- the relay's stamp order and its delivery order have come apart",
			cp.index, kind, seq, cp.lastSeq)
		return
	}
	cp.lastSeq = seq
}

func (cp *controlPlane) onEvent(ev protocol.Event) {
	cp.checkSeq("event", ev.Seq)
	cp.eventsSeen.Add(1)
	if ev.From == "" || ev.From == cp.selfID {
		return
	}
	cp.mu.Lock()
	cp.peers[ev.From] = true
	cp.mu.Unlock()
}

func (cp *controlPlane) onLeaseState(st protocol.LeaseState) {
	cp.checkSeq("lease_state", st.Seq)
	if cp.world != nil {
		// The world authority is a different key from the contended one below,
		// and its grants are what invariants 5, 6 and 8 are judged against.
		cp.world.onLeaseState(st)
	}

	cp.mu.Lock()
	defer cp.mu.Unlock()
	switch st.Reason {
	case protocol.LeaseGranted:
		// Invariant 2. A grant to somebody else while this client still
		// believes a different holder has it means the key was handed out
		// twice — unless the previous holder released it, which arrives as its
		// own message and clears leaseHolder first.
		if held := cp.leaseHolder[st.Key]; held != "" && held != st.Holder {
			reportViolation("client %d saw key %q granted to %s while %s still held it "+
				"-- two holders of one key",
				cp.index, st.Key, st.Holder, held)
		}
		cp.leaseHolder[st.Key] = st.Holder
		if st.Holder == cp.selfID {
			cp.claimsWon.Add(1)
		}
	case protocol.LeaseReleased, protocol.LeaseExpired, protocol.LeaseHolderLeft:
		delete(cp.leaseHolder, st.Key)
	case protocol.LeaseDenied, protocol.LeaseTooMany:
		// A denial is addressed to the asker alone and says nothing about the
		// room beyond who currently holds the key, so it must NOT be treated
		// as a state change. Counted, because a run where every claim is
		// denied is a working relay and a useless test.
		cp.claimsLost.Add(1)
	}
}

func (cp *controlPlane) onEscrowState(st protocol.EscrowState) {
	cp.checkSeq("escrow_state", st.Seq)

	switch st.Phase {
	case protocol.EscrowPhaseOpen:
		cp.mu.Lock()
		if _, known := cp.openExchanges[st.ID]; !known {
			cp.openExchanges[st.ID] = time.Now()
		}
		cp.mu.Unlock()
		// Whichever side did not open it still has to deposit, and the opener
		// deposits on its own open too — both sides simply deposit as soon as
		// they know the exchange exists.
		cp.deposit(st.ID)
	case protocol.EscrowPhaseDeposited:
		// Both blobs are in. Committing here rather than immediately after
		// depositing is what makes this exercise the real two-step: a commit
		// sent before the other side deposited is legal and is recorded, but
		// it would never test the ordering that matters.
		if err := cp.core.SendEscrow(protocol.Escrow{Op: protocol.EscrowCommit, ID: st.ID}); err != nil {
			log.Printf("meshghost-fakeadapter: client %d could not commit %s: %v", cp.index, st.ID, err)
		}
	case protocol.EscrowPhaseCommitted:
		cp.finish(st.ID)
		cp.tradesDone.Add(1)
		// The blobs must both be present, or "both or neither" did not hold.
		if len(st.Blobs) != 2 {
			reportViolation("client %d got a committed exchange %s carrying %d blob(s), want 2 "+
				"-- one side completed a swap the other never contributed to",
				cp.index, st.ID, len(st.Blobs))
		}
	case protocol.EscrowPhaseAborted:
		cp.finish(st.ID)
		cp.tradesGone.Add(1)
		if len(st.Blobs) != 0 {
			reportViolation("client %d got an ABORTED exchange %s still carrying %d blob(s) "+
				"-- an abort must destroy both deposits, not deliver them",
				cp.index, st.ID, len(st.Blobs))
		}
	}
}

func (cp *controlPlane) deposit(id string) {
	blob, err := json.Marshal(map[string]any{"from": cp.selfID, "exchange": id})
	if err != nil {
		return
	}
	if err := cp.core.SendEscrow(protocol.Escrow{
		Op: protocol.EscrowDeposit, ID: id, Blob: blob,
	}); err != nil {
		log.Printf("meshghost-fakeadapter: client %d could not deposit into %s: %v", cp.index, id, err)
	}
}

func (cp *controlPlane) finish(id string) {
	cp.mu.Lock()
	delete(cp.openExchanges, id)
	cp.mu.Unlock()
}

// checkStalledExchanges is invariant 3, run periodically: any exchange still
// open past the relay's own escrow timeout plus slack should have been aborted
// by the relay itself, so one still sitting here means a terminal state was
// never delivered.
func (cp *controlPlane) checkStalledExchanges() {
	cutoff := time.Now().Add(-(protocol.DefaultEscrowTimeout + 15*time.Second))
	cp.mu.Lock()
	defer cp.mu.Unlock()
	for id, started := range cp.openExchanges {
		if started.Before(cutoff) {
			reportViolation("client %d has exchange %s still open after %s "+
				"-- the relay's own timeout should have aborted it and said so",
				cp.index, id, time.Since(started).Truncate(time.Second))
			delete(cp.openExchanges, id)
		}
	}
}

// partner picks a deterministic counterparty from the peers this client has
// heard from: the lowest player_id above its own, wrapping to the lowest
// overall. Deterministic so exactly one side of each pair opens, which avoids
// two clients opening mirror-image exchanges with each other and both failing
// on the duplicate id.
func (cp *controlPlane) partner() (string, bool) {
	cp.mu.Lock()
	ids := make([]string, 0, len(cp.peers)+1)
	ids = append(ids, cp.selfID)
	for id := range cp.peers {
		ids = append(ids, id)
	}
	cp.mu.Unlock()
	if len(ids) < 2 {
		return "", false
	}
	sort.Strings(ids)
	for i, id := range ids {
		if id == cp.selfID {
			// Only the even-indexed side opens, so each pair has one opener.
			if i%2 != 0 || i+1 >= len(ids) {
				return "", false
			}
			return ids[i+1], true
		}
	}
	return "", false
}

// run drives this client's control-plane traffic until stop closes.
func (cp *controlPlane) run(stop <-chan struct{}, wg *sync.WaitGroup, cfg controlPlaneConfig) {
	defer wg.Done()

	// Staggered per client so N of them do not all fire on the same tick,
	// which would test one thundering herd repeatedly instead of a realistic
	// spread — and would hide exactly the interleavings this is looking for.
	stagger := time.Duration(int64(cfg.eventEvery) * int64(cp.index) / int64(cfg.clients+1))
	timers := newPlaneTickers(cfg, stagger)
	defer timers.stop()

	for {
		select {
		case <-stop:
			return
		case <-timers.event:
			payload, err := json.Marshal(map[string]any{"tick": time.Now().UnixMilli(), "who": cp.selfID})
			if err == nil {
				if err := cp.core.SendEvent(protocol.Event{Payload: payload}); err != nil {
					log.Printf("meshghost-fakeadapter: client %d could not send an event: %v", cp.index, err)
				}
			}
		case <-timers.lease:
			// Claim, hold briefly, release. Contention is the point: every
			// client goes for the same key, so most claims are denied and the
			// exclusivity check has something to check.
			if err := cp.core.ClaimLease(cfg.leaseKey, cfg.leaseHold); err != nil {
				log.Printf("meshghost-fakeadapter: client %d could not claim: %v", cp.index, err)
				break
			}
			go func() {
				select {
				case <-time.After(cfg.leaseHold / 2):
				case <-stop:
					return
				}
				cp.mu.Lock()
				mine := cp.leaseHolder[cfg.leaseKey] == cp.selfID
				cp.mu.Unlock()
				if mine {
					_ = cp.core.ReleaseLease(cfg.leaseKey)
				}
			}()
		case <-timers.trade:
			with, ok := cp.partner()
			if !ok {
				break
			}
			id := fmt.Sprintf("%s-t%d", cp.selfID, cp.nextTradeNo.Add(1))
			if err := cp.core.SendEscrow(protocol.Escrow{
				Op: protocol.EscrowOpen, ID: id, With: with,
			}); err != nil {
				log.Printf("meshghost-fakeadapter: client %d could not open an exchange: %v", cp.index, err)
			}
		case <-timers.audit:
			cp.checkStalledExchanges()
		}
	}
}

// controlPlaneConfig is the flag-derived configuration for the whole rig.
type controlPlaneConfig struct {
	clients     int
	eventEvery  time.Duration
	leaseEvery  time.Duration
	leaseKey    string
	world       worldConfig
	leaseHold   time.Duration
	tradeEvery  time.Duration
	statsEvery  time.Duration
	anyPlaneOn  bool
	featureList []string
}

// planeTickers holds one ticker per plane, with a disabled plane wired to a
// nil channel — a nil channel blocks forever in a select, which is exactly the
// "this plane is off" behaviour wanted, and avoids a branch per case.
type planeTickers struct {
	event, lease, trade, audit <-chan time.Time
	all                        []*time.Ticker
}

func newPlaneTickers(cfg controlPlaneConfig, stagger time.Duration) *planeTickers {
	pt := &planeTickers{}
	add := func(d time.Duration) <-chan time.Time {
		if d <= 0 {
			return nil
		}
		t := time.NewTicker(d)
		pt.all = append(pt.all, t)
		return t.C
	}
	if stagger > 0 {
		time.Sleep(stagger)
	}
	pt.event = add(cfg.eventEvery)
	pt.lease = add(cfg.leaseEvery)
	pt.trade = add(cfg.tradeEvery)
	pt.audit = add(15 * time.Second)
	return pt
}

func (pt *planeTickers) stop() {
	for _, t := range pt.all {
		t.Stop()
	}
}

// summarize prints what the run actually exercised. Worth printing even when
// nothing failed: a run where every claim was denied, or no trade ever
// completed, is a green result that tested nothing, and the counts are the only
// way to tell that from a real pass.
func summarize(planes []*controlPlane, elapsed time.Duration) {
	var events, won, lost, done, gone uint64
	for _, cp := range planes {
		events += cp.eventsSeen.Load()
		won += cp.claimsWon.Load()
		lost += cp.claimsLost.Load()
		done += cp.tradesDone.Load()
		gone += cp.tradesGone.Load()
	}
	log.Printf("meshghost-fakeadapter: control-plane summary after %s: "+
		"%d events received, %d claims won / %d denied, %d exchanges committed / %d aborted",
		elapsed.Truncate(time.Second), events, won, lost, done, gone)
	var writes, adoptions uint64
	worldOn := false
	for _, cp := range planes {
		if cp.world == nil {
			continue
		}
		worldOn = true
		cp.world.mu.Lock()
		writes += cp.world.writes
		adoptions += cp.world.adopted
		cp.world.mu.Unlock()
	}
	if worldOn {
		// Printed for the same reason the counts above are: a run with zero
		// adoptions exercised custody's happy path and none of its point, and
		// that is indistinguishable from a real pass without saying so.
		log.Printf("meshghost-fakeadapter: world summary: %d entity writes sent, %d world(s) adopted "+
			"across handovers", writes, adoptions)
		if adoptions == 0 {
			log.Printf("meshghost-fakeadapter: warning: no handover ever happened -- pass -migrate-every " +
				"to make a holder give the authority up, or this tested custody without testing migration")
		}
	}
	if v := violations.Load(); v > 0 {
		log.Printf("meshghost-fakeadapter: %d INVARIANT VIOLATION(S) -- see the lines above", v)
		return
	}
	log.Printf("meshghost-fakeadapter: no invariant violations")
}
