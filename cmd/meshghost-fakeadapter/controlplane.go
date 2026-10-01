package main

import (
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// violations counts invariant failures across every synthetic client in this process: a violation belongs to the
// run, as the exit code does.
var violations atomic.Uint64

func reportViolation(format string, args ...any) {
	violations.Add(1)
	log.Printf("meshghost-fakeadapter: INVARIANT VIOLATION: "+format, args...)
}

// controlPlane drives and checks one synthetic client's control-plane traffic for the whole run, because a long run
// at real client counts over a real transport finds what the relay's short loopback tests cannot:
//  1. ordering: every control message carries a strictly larger sequencer stamp than the last;
//  2. exclusivity: a key goes to a second holder only after the first gave it up;
//  3. termination: every exchange reaches committed or aborted, or both deposits stay pinned with nothing said.
//
// A violation is logged when it happens and makes the run exit non-zero.
type controlPlane struct {
	core  *core.Core
	index int
	// selfID is this client's relay-assigned player_id: it tells its own echoed events from everyone else's.
	selfID string

	mu sync.Mutex
	// lastSeq is the highest sequencer stamp seen. Events, lease states and escrow states share one room counter, so
	// it rises strictly across all three even though a client sees only a subset.
	lastSeq uint64
	// leaseHolder is who this client believes holds each key; per key, since the world authority is a second key
	// whose grants interleave with the contended one.
	leaseHolder map[string]string
	// peers is every other player_id this client has heard from, learned from event senders: the core exposes no
	// roster.
	peers map[string]bool
	// openExchanges maps an exchange id to when it started, so invariant 3 can notice one that never finished.
	openExchanges map[string]time.Time

	// credit is the kill-credit checker, or nil when that plane is off.
	credit *creditChecker

	// world is the world-custody checker, or nil when that plane is off.
	world *worldChecker

	eventsSeen  atomic.Uint64
	claimsWon   atomic.Uint64
	claimsLost  atomic.Uint64
	tradesDone  atomic.Uint64
	tradesGone  atomic.Uint64
	nextTradeNo atomic.Uint64
}

// newControlPlane builds a checker; attach wires it to a Core separately, so the checkers can be tested without one.
func newControlPlane(index int) *controlPlane {
	return &controlPlane{
		index:         index,
		peers:         make(map[string]bool),
		leaseHolder:   make(map[string]string),
		openExchanges: make(map[string]time.Time),
	}
}

// attach wires this checker to a connected Core and captures its player_id, so it is called after the handshake.
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
	if cp.credit != nil {
		cp.credit.self = cp.selfID
	}
}

// checkSeq is invariant 1. Caller must not hold cp.mu.
func (cp *controlPlane) checkSeq(kind string, seq uint64) {
	if seq == 0 {
		// Only a relay older than the sequencer sends this, which no run of this rig sets up.
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
	if cp.credit != nil {
		// Every event, own echo included: the echo is how a dealer learns where its own hit landed in the order.
		cp.credit.onEvent(ev)
	}
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
		// The world authority is another key; its grants are what invariants 5, 6 and 8 are judged against.
		cp.world.onLeaseState(st)
	}

	cp.mu.Lock()
	defer cp.mu.Unlock()
	switch st.Reason {
	case protocol.LeaseGranted:
		// Invariant 2: a release arrives as its own message and clears leaseHolder first, so a grant to another holder
		// while one is still recorded means the key was handed out twice.
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
		// A denial goes to the asker alone and is not a state change. Counted, as an all-denied run tests nothing.
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
		// Both sides deposit as soon as they know the exchange exists, the opener included.
		cp.deposit(st.ID)
	case protocol.EscrowPhaseDeposited:
		// Committing only once both deposited exercises the real two-step; an early commit is legal but tests nothing.
		if err := cp.core.SendEscrow(protocol.Escrow{Op: protocol.EscrowCommit, ID: st.ID}); err != nil {
			log.Printf("meshghost-fakeadapter: client %d could not commit %s: %v", cp.index, st.ID, err)
		}
	case protocol.EscrowPhaseCommitted:
		cp.finish(st.ID)
		cp.tradesDone.Add(1)
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

// checkStalledExchanges is invariant 3: an exchange still open past the relay's own escrow timeout plus slack was
// never given its terminal state.
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

// partner pairs the sorted player_ids, this client's included, two by two and returns this client's partner if it
// opens for its pair. Deterministic, so no two clients open mirror-image exchanges that fail on the duplicate id.
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

	// Staggered so the clients do not all fire on one tick, which would hide the interleavings this looks for.
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
			// Every client claims the same key, so most claims are denied and exclusivity has something to check.
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
	credit      creditConfig
	leaseHold   time.Duration
	tradeEvery  time.Duration
	statsEvery  time.Duration
	anyPlaneOn  bool
	featureList []string
}

// planeTickers holds one ticker per plane; a plane that is off gets a nil channel, which blocks forever in a select.
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

// summarize prints what the run exercised even when nothing failed: a run where every claim was denied, or no trade
// completed, is a green result that tested nothing.
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
		log.Printf("meshghost-fakeadapter: world summary: %d entity writes sent, %d world(s) adopted "+
			"across handovers", writes, adoptions)
		// Zero writes is a violation: a holder waits for its adoption snapshot before writing (isHolder), so a relay
		// that never sends one for an empty world would otherwise pass with nothing written.
		if writes == 0 {
			reportViolation("the world plane was on and not one entity write was sent -- " +
				"nothing was exercised, so this run proves nothing. The usual cause is a holder " +
				"never being cleared to write, which happens if an adoption snapshot never arrives")
		}
		if adoptions == 0 {
			// Only a warning: a run with no -migrate-every never hands off, by configuration.
			log.Printf("meshghost-fakeadapter: warning: no handover ever happened -- pass -migrate-every " +
				"to make a holder give the authority up, or this tested custody without testing migration")
		}
	}

	var hits, kills, rewards, agreed, resets uint64
	creditOn := false
	for _, cp := range planes {
		if cp.credit == nil {
			continue
		}
		creditOn = true
		hits += cp.credit.hits.Load()
		kills += cp.credit.kills.Load()
		rewards += cp.credit.rewards.Load()
		agreed += cp.credit.agreedOn.Load()
		resets += cp.credit.resets.Load()
	}
	if creditOn {
		log.Printf("meshghost-fakeadapter: credit summary: %d hits applied, %d kills, %d rewards taken, "+
			"%d death(s) agreed with a peer, %d generation(s) reset", hits, kills, rewards, agreed, resets)
		// Zero kills is a violation for the same reason: nothing died, so only an empty ledger was checked.
		if kills == 0 {
			reportViolation("the credit plane was on and nothing ever died -- nothing was " +
				"exercised, so this run proves nothing. The usual cause is -hit-every being too " +
				"slow for -duration, or every peer sitting in a death window")
		}
		// Invariant 13 only covers generations from a reset this client watched, so resets with no agreement never
		// ran it.
		if len(planes) > 1 && resets > 0 && agreed == 0 {
			reportViolation("the credit plane saw %d reset(s) across %d clients and not one death "+
				"was ever agreed with a peer -- invariant 13 never ran, so the run says nothing "+
				"about whether participants die together", resets, len(planes))
		}
	}
	if v := violations.Load(); v > 0 {
		log.Printf("meshghost-fakeadapter: %d INVARIANT VIOLATION(S) -- see the lines above", v)
		return
	}
	log.Printf("meshghost-fakeadapter: no invariant violations")
}
