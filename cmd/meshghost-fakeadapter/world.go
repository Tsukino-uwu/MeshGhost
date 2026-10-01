package main

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"sync"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// worldBlob is what this rig stores per entity, made up and opaque to the core and relay.
type worldBlob struct {
	// Gen only increases, and only on a discrete transition, so "the world went backwards" is decidable.
	Gen uint64  `json:"gen"`
	X   float64 `json:"x"`
	Y   float64 `json:"y"`
}

// leaseAt is one observed change of the authority's holder, at the stamp the relay gave it.
type leaseAt struct {
	seq    uint64
	holder string
}

// pendingHolder is a world message whose Holder cannot be judged until this client sees the lease transition that
// brackets its stamp: on a lossy transport a write can arrive before the grant that authorized it.
type pendingHolder struct {
	seq    uint64
	holder string
}

// worldChecker is one client's view of the world plane: every client contends for one authority lease, the winner
// drives synthetic entities, and the holder hands off periodically, so a handover happens while lossy writes are in
// flight over a real transport. That is where an ordering mistake shows, as two clients quietly looking at different
// worlds. It checks:
//  4. no rollback: never a lower gen for a key than one already applied to it;
//  5. no stale-host clobber: a written WorldState carries the Holder that held the authority at its own stamp;
//  6. no loss across handover: every key this client knew before it took the lease is in the world it adopts;
//  7. no resurrect: a drop is never followed by a set at or below the dropped gen;
//  8. grant/snapshot contiguity: no other WorldState for the authority arrives between the grant and the adoption
//     snapshot, the wire-visible form of "the snapshot is built inside the grant".
//
// It has its own lock because the receive callback and the writer goroutine both drive it.
type worldChecker struct {
	cfg    worldConfig
	self   string
	report func(format string, args ...any)

	mu sync.Mutex
	// gen is the highest generation seen per key and appliedSeq the stamp it came from. appliedSeq is the
	// receiver-side ordering rule: the reliable and lossy planes are independent on a datagram transport, so a lossy
	// write can land ahead of the reliable snapshot meant to seed it.
	gen        map[string]uint64
	appliedSeq map[string]uint64
	// issued is the highest generation this client has sent per key, kept apart from gen: a write can be refused,
	// and a local bump the relay never agreed to would make the next adopted snapshot look like a rollback.
	issued map[string]uint64
	// droppedAt is the gen a key was dropped at, kept after the drop so invariant 7 can see a resurrection.
	droppedAt map[string]uint64
	// holder is the authority's current holder as this client understands it, and leases is the stamped history
	// invariant 5 judges against.
	holder string
	leases []leaseAt
	// pending are holder checks awaiting a bracketing lease transition.
	pending []pendingHolder
	// awaitingAdoption is invariant 8: set when this client is granted the authority, cleared by the snapshot that
	// should immediately follow.
	awaitingAdoption bool
	// adopting accumulates the adoption snapshot, which may arrive as several batched messages with no end marker;
	// mustAdopt is every key this client knew at grant time, which invariant 6 requires in it.
	adopting   map[string]bool
	mustAdopt  map[string]bool
	inAdoption bool

	writes  uint64
	adopted uint64
}

// worldConfig is the flag-derived configuration for this plane.
type worldConfig struct {
	on        bool
	authority string
	entities  int
	entityHz  int
	migrate   time.Duration
}

func newWorldChecker(cfg worldConfig, self string, report func(string, ...any)) *worldChecker {
	return &worldChecker{
		cfg:        cfg,
		self:       self,
		report:     report,
		gen:        make(map[string]uint64),
		appliedSeq: make(map[string]uint64),
		issued:     make(map[string]uint64),
		droppedAt:  make(map[string]uint64),
	}
}

// entityKey and posKey are the two keys each entity uses. A lossy write replaces the whole blob, and on a datagram
// transport one sent before a reliable write can reach the relay after it, dragging every field in the blob back; the
// next snapshot then spreads the regression. So discrete state has its own reliable key and position a lossy one.
func entityKey(i int) string { return fmt.Sprintf("e%d", i) }
func posKey(i int) string    { return fmt.Sprintf("e%d.pos", i) }

// onLeaseState records a change of the world authority's holder; other keys are ignored.
func (w *worldChecker) onLeaseState(st protocol.LeaseState) {
	if st.Key != w.cfg.authority {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()

	switch st.Reason {
	case protocol.LeaseGranted:
		// Only a change of holder adopts anything, as on the relay: a renew broadcasts granted too, with no snapshot.
		changed := w.holder != st.Holder
		w.holder = st.Holder
		w.leases = append(w.leases, leaseAt{seq: st.Seq, holder: st.Holder})
		if changed && st.Holder == w.self {
			// Invariant 8 arms here, and every key this client knows becomes what invariant 6 demands.
			w.awaitingAdoption = true
			w.mustAdopt = make(map[string]bool, len(w.gen))
			for key := range w.gen {
				if _, dropped := w.droppedAt[key]; !dropped {
					w.mustAdopt[key] = true
				}
			}
		} else if changed {
			// Another client took over before this one's adoption arrived, so none is owed.
			w.awaitingAdoption = false
		}
	case protocol.LeaseReleased, protocol.LeaseExpired, protocol.LeaseHolderLeft:
		w.holder = ""
		w.awaitingAdoption = false
		w.leases = append(w.leases, leaseAt{seq: st.Seq, holder: ""})
	default:
		return
	}
	// Bounded for long soaks: older entries have already judged every message they could bracket.
	if len(w.leases) > 512 {
		w.leases = append([]leaseAt(nil), w.leases[len(w.leases)-256:]...)
	}
	w.drainPendingLocked()
}

// onWorldState applies one world message and runs invariants 4-8 against it.
func (w *worldChecker) onWorldState(st protocol.WorldState) {
	if st.Authority != w.cfg.authority {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()

	switch st.Reason {
	case protocol.WorldSnapshot:
		if w.awaitingAdoption {
			w.awaitingAdoption = false
			w.inAdoption = true
			w.adopting = make(map[string]bool, len(st.Entries))
			w.adopted++
		}
	case protocol.WorldDenied:
		// Expected whenever this client is not the holder; a migration run produces these by design.
		return
	case protocol.WorldTooMany:
		w.report("client world plane hit the per-room key cap with %d entities configured "+
			"-- the rig is asking for more than protocol.MaxWorldKeysPerRoom", w.cfg.entities)
		return
	case protocol.WorldWritten:
		// Invariant 8: a live write before the adoption snapshot means the snapshot was sent after the grant.
		if w.awaitingAdoption {
			w.report("%s was granted authority %q and then received a live world write (seq %d) "+
				"before its adoption snapshot -- the snapshot was not built inside the grant",
				w.self, w.cfg.authority, st.Seq)
			w.awaitingAdoption = false
		}
		w.checkHolderLocked(st.Seq, st.Holder)
	}

	for _, e := range st.Entries {
		w.applyEntryLocked(st, e)
	}
}

// applyEntryLocked runs invariants 4 and 7 for one entry. Caller holds w.mu.
func (w *worldChecker) applyEntryLocked(st protocol.WorldState, e protocol.WorldEntry) {
	if w.inAdoption {
		w.adopting[e.Key] = true
	}
	// The receiver-side ordering rule: stamp order is authoritative and delivery across two planes is not, so an
	// older message is discarded, not reported.
	if st.Seq <= w.appliedSeq[e.Key] {
		return
	}
	w.appliedSeq[e.Key] = st.Seq

	if e.Dropped {
		w.droppedAt[e.Key] = w.gen[e.Key]
		return
	}
	var blob worldBlob
	if err := json.Unmarshal(e.Blob, &blob); err != nil {
		w.report("%s could not read the blob for key %q: %v -- the relay altered an opaque payload",
			w.self, e.Key, err)
		return
	}
	if blob.Gen == 0 {
		// A position-only key rides the lossy plane with no generation, so invariants 4 and 7 skip it.
		return
	}
	// Invariant 7: a set at or below the dropped gen is a stale write that outlived its own deletion.
	if at, dropped := w.droppedAt[e.Key]; dropped && blob.Gen <= at {
		w.report("%s saw key %q resurrected at gen %d after being dropped at gen %d "+
			"-- a stale write overtook the drop that removed it",
			w.self, e.Key, blob.Gen, at)
	}
	// Invariant 4.
	if have, seen := w.gen[e.Key]; seen && blob.Gen < have {
		w.report("%s saw key %q roll back from gen %d to gen %d at seq %d (reason %q, holder %s) "+
			"-- the world went backwards", w.self, e.Key, have, blob.Gen, st.Seq, st.Reason, st.Holder)
		return
	}
	delete(w.droppedAt, e.Key)
	w.gen[e.Key] = blob.Gen
}

// checkHolderLocked is invariant 5, judged by stamp rather than arrival, so a write that overtook its own grant on a
// lossy transport is not mistaken for a stale host. Caller holds w.mu.
func (w *worldChecker) checkHolderLocked(seq uint64, holder string) {
	switch w.judgeHolderLocked(seq, holder) {
	case holderWrong:
		w.report("%s received a world write stamped %d claiming holder %s, but %s held authority %q "+
			"at that point in the order -- a stale host's write was accepted after handover",
			w.self, seq, holder, w.holderAtLocked(seq), w.cfg.authority)
	case holderUndecided:
		w.pending = append(w.pending, pendingHolder{seq: seq, holder: holder})
		if len(w.pending) > 1024 {
			w.pending = w.pending[len(w.pending)-512:]
		}
	}
}

type holderVerdict int

const (
	holderOK holderVerdict = iota
	holderWrong
	holderUndecided
)

// judgeHolderLocked decides whether holder was the authority at seq. A mismatch is undecided until a lease transition
// at or after seq has been seen, since the one that explains it may not have arrived. Caller holds w.mu.
func (w *worldChecker) judgeHolderLocked(seq uint64, holder string) holderVerdict {
	at, bracketed := "", false
	for _, l := range w.leases {
		if l.seq < seq {
			at = l.holder
			continue
		}
		// A transition at or after seq closes the window: the one before it is the last before seq.
		bracketed = true
		break
	}
	if at == holder {
		return holderOK
	}
	if !bracketed {
		return holderUndecided
	}
	return holderWrong
}

func (w *worldChecker) holderAtLocked(seq uint64) string {
	at := "nobody"
	for _, l := range w.leases {
		if l.seq >= seq {
			break
		}
		if l.holder == "" {
			at = "nobody"
		} else {
			at = l.holder
		}
	}
	return at
}

// drainPendingLocked re-judges everything undecided, now that a new lease transition may have closed its window.
// Caller holds w.mu.
func (w *worldChecker) drainPendingLocked() {
	keep := w.pending[:0]
	for _, p := range w.pending {
		switch w.judgeHolderLocked(p.seq, p.holder) {
		case holderOK:
		case holderWrong:
			w.report("%s received a world write stamped %d claiming holder %s, but %s held authority %q "+
				"at that point in the order -- a stale host's write was accepted after handover",
				w.self, p.seq, p.holder, w.holderAtLocked(p.seq), w.cfg.authority)
		default:
			keep = append(keep, p)
		}
	}
	w.pending = keep
}

// closeAdoption is invariant 6, run on the audit tick: an adoption snapshot is one or more batched messages with no
// end marker, so whether it carried everything can be asked only once the batch has had time to land.
func (w *worldChecker) closeAdoption() {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.inAdoption {
		return
	}
	w.inAdoption = false
	for key := range w.mustAdopt {
		if !w.adopting[key] {
			w.report("%s adopted authority %q without key %q, which it had already seen "+
				"-- the world lost an entity across the handover", w.self, w.cfg.authority, key)
		}
	}
	w.adopting, w.mustAdopt = nil, nil
}

// isHolder reports whether this client may write: it holds the authority and its adoption has landed. The grant
// arrives just before the world it grants, and a host writing at once would renumber from a stale view and roll the
// world back; the relay always sends one adoption snapshot, empty world included, so the two states are told apart.
func (w *worldChecker) isHolder() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.holder == w.self && !w.awaitingAdoption
}

// currentGenLocked is the generation this client believes key is at: the higher of what the relay last told it and
// what it last sent. Caller holds w.mu.
func (w *worldChecker) currentGenLocked(key string) uint64 {
	if w.issued[key] > w.gen[key] {
		return w.issued[key]
	}
	return w.gen[key]
}

func (w *worldChecker) currentGen(key string) uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.currentGenLocked(key)
}

// nextGen returns the generation to write for key: one above the highest this client knows of, adopted included. A
// successor numbering from zero would roll the world back on every handover, and every client would agree on it.
func (w *worldChecker) nextGen(key string) uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	next := w.currentGenLocked(key) + 1
	w.issued[key] = next
	return next
}

// runWorld drives this client's world traffic until stop closes: contend for the authority, and while holding it,
// populate and move the entities and hand off periodically.
func (cp *controlPlane) runWorld(stop <-chan struct{}, wg *sync.WaitGroup, cfg worldConfig) {
	defer wg.Done()

	w := cp.world
	claim := time.NewTicker(2 * time.Second)
	defer claim.Stop()
	entity := time.NewTicker(time.Second / time.Duration(max1(cfg.entityHz)))
	defer entity.Stop()
	// Discrete transitions, much rarer than motion as an adapter's are, give invariant 4 something to guard.
	transition := time.NewTicker(3 * time.Second)
	defer transition.Stop()
	migrate := tickerOrNil(cfg.migrate)
	defer stopTicker(migrate)
	audit := time.NewTicker(5 * time.Second)
	defer audit.Stop()

	populated := false
	phase := 0.0

	for {
		select {
		case <-stop:
			return

		case <-claim.C:
			if !w.isHolder() {
				// Everyone contends, so a handover always has a successor waiting.
				if err := cp.core.ClaimLease(cfg.authority, 30*time.Second); err != nil {
					log.Printf("meshghost-fakeadapter: client %d could not claim the world authority: %v",
						cp.index, err)
				}
				populated = false
				break
			}
			// Renewed so the lease does not expire between migrations and turn every run into a churn test.
			_ = cp.core.RenewLease(cfg.authority, 30*time.Second)

		case <-entity.C:
			if !w.isHolder() {
				break
			}
			if !populated {
				// Every key is created reliably: the relay ignores a lossy create, which could overtake a drop and
				// resurrect an entity.
				cp.populateWorld(cfg, phase)
				populated = true
				break
			}
			phase += 0.05
			cp.moveWorld(cfg, phase)

		case <-transition.C:
			if !w.isHolder() || !populated {
				break
			}
			cp.transitionWorld(cfg)

		case <-migrate:
			if !w.isHolder() {
				break
			}
			// An orderly release, which a crash cannot test: the world must survive it as it does a disconnect.
			if err := cp.core.ReleaseLease(cfg.authority); err != nil {
				log.Printf("meshghost-fakeadapter: client %d could not release the world authority: %v",
					cp.index, err)
			}

		case <-audit.C:
			w.closeAdoption()
		}
	}
}

// populateWorld writes every entity reliably: how a key is legally created, and how a successor's adopted world
// takes its numbering.
func (cp *controlPlane) populateWorld(cfg worldConfig, phase float64) {
	for i := 0; i < cfg.entities; i++ {
		key := entityKey(i)
		cp.writeEntity(cfg, key, cp.world.nextGen(key), phase, true)
		// The position key is created reliably too, and only then updated lossily.
		cp.writeEntity(cfg, posKey(i), 0, phase, true)
	}
}

// moveWorld writes every entity's position lossily on its own key: with no generation in it, a late one can only make
// a position briefly old.
func (cp *controlPlane) moveWorld(cfg worldConfig, phase float64) {
	for i := 0; i < cfg.entities; i++ {
		cp.writeEntity(cfg, posKey(i), 0, phase+float64(i), false)
	}
}

// transitionWorld drops entity 0 and re-creates it at a higher generation, both reliably, since the relay refuses a
// lossy re-create.
func (cp *controlPlane) transitionWorld(cfg worldConfig) {
	key := entityKey(0)
	if err := cp.core.DropWorld(cfg.authority, key); err != nil {
		log.Printf("meshghost-fakeadapter: client %d could not drop %q: %v", cp.index, key, err)
		return
	}
	cp.writeEntity(cfg, key, cp.world.nextGen(key), 0, true)
}

func (cp *controlPlane) writeEntity(cfg worldConfig, key string, gen uint64, phase float64, reliable bool) {
	blob, err := json.Marshal(worldBlob{
		Gen: gen,
		X:   10 * math.Cos(phase),
		Y:   10 * math.Sin(phase),
	})
	if err != nil {
		return
	}
	if err := cp.core.SetWorld(cfg.authority, key, blob, reliable); err != nil {
		log.Printf("meshghost-fakeadapter: client %d could not write %q: %v", cp.index, key, err)
		return
	}
	cp.world.mu.Lock()
	cp.world.writes++
	cp.world.mu.Unlock()
}

func max1(n int) int {
	if n < 1 {
		return 1
	}
	return n
}

func tickerOrNil(d time.Duration) <-chan time.Time {
	if d <= 0 {
		return nil
	}
	return time.NewTicker(d).C
}

// stopTicker does nothing: tickerOrNil keeps no *time.Ticker, so a non-nil one runs until the process exits.
func stopTicker(<-chan time.Time) {}
