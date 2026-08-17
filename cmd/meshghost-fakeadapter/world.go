package main

// The world-custody half of the synthetic-peer rig: every client contends for
// one authority lease, whoever wins drives N synthetic entities, and the
// holder periodically hands off so migration happens under real traffic rather
// than only in a unit test.
//
// **The point is the handover, not the writes.** relay's tests already
// prove a snapshot is built inside the grant and that a stale host is refused.
// What they cannot reach is a handover that happens while lossy writes are in
// flight, over a real transport, through cmd/meshghost-netsim's loss and
// jitter — which is where an ordering mistake actually shows up, and where it
// shows up as two clients quietly looking at different worlds rather than as a
// crash.
//
// Five invariants are checked here, continuing controlplane.go's three:
//
//  4. **No rollback** — never a lower gen for a key than one already applied
//     to it. This is the whole promise of custody: a successor adopts what the
//     relay holds, so the world never goes backwards when the host changes.
//  5. **No stale-host clobber** — a written WorldState never carries a Holder
//     other than whoever held the authority at that message's own stamp.
//  6. **No loss across handover** — every key this client knew about before it
//     took the lease is in the world it adopts.
//  7. **No resurrect** — a drop is never followed by a set at or below the
//     dropped gen.
//  8. **Grant/snapshot contiguity** — between the grant and the adoption
//     snapshot, no other WorldState for that authority arrives. This is the
//     wire-visible form of "the snapshot is built inside the grant", and the
//     cheapest regression catch of the lot.
//
// checkSeq covers this plane for free, because every world message is stamped
// out of the same room counter as events, leases and escrows.

import (
	"encoding/json"
	"fmt"
	"log"
	"math"
	"sync"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// worldBlob is what this rig stores per entity. Entirely made up, and entirely
// opaque to the core and relay — the shape exists so the checks below have a
// version number to compare and a position to watch move.
type worldBlob struct {
	// Gen only ever increases, and only on a discrete transition, which is
	// what makes "the world went backwards" a decidable question. Written
	// reliably; the position alone rides the lossy plane.
	Gen uint64  `json:"gen"`
	X   float64 `json:"x"`
	Y   float64 `json:"y"`
}

// leaseAt is one observed change of the authority's holder, at the stamp the
// relay gave it.
type leaseAt struct {
	seq    uint64
	holder string
}

// pendingHolder is a world message whose Holder could not be judged yet
// because this client has not seen the lease transition that brackets its
// stamp. Kept rather than discarded: on a lossy transport a write can arrive
// before the grant that authorized it, and treating that as a violation would
// make the checker report the transport rather than the relay.
type pendingHolder struct {
	seq    uint64
	holder string
}

// worldChecker is one client's view of the world plane. Its own lock, separate
// from controlPlane.mu, because it is driven from both the receive callback and
// the writer goroutine and has nothing to say to the lease/escrow state.
type worldChecker struct {
	cfg    worldConfig
	self   string
	report func(format string, args ...any)

	mu sync.Mutex
	// gen is the highest generation seen per key, and appliedSeq the stamp it
	// came from.
	//
	// **appliedSeq is not bookkeeping, it is the receiver-side ordering rule
	// the contract requires.** The relay guarantees a total order, but the
	// reliable and lossy planes are independent on a datagram transport, so a
	// lossy write can land ahead of the reliable snapshot meant to seed it. A
	// receiver that did not discard the older stamp would revert itself — and
	// then invariant 4 would fire against the transport rather than against a
	// real defect.
	gen        map[string]uint64
	appliedSeq map[string]uint64
	// issued is the highest generation this client has SENT for a key, kept
	// strictly apart from gen above.
	//
	// **Mixing the two makes invariant 4 report itself.** A write can be
	// refused — this client lost the authority between deciding to write and
	// the relay seeing it — so an optimistic local bump is not evidence the
	// world ever reached that generation. Folding it into gen would leave the
	// client with a high-water mark the relay never agreed to, and the next
	// snapshot it adopts would look like the world going backwards. Found by
	// this rig's own soak, 2026-08-17: the only "rollbacks" it ever reported
	// were this.
	issued map[string]uint64
	// droppedAt is the gen a key was dropped at, for invariant 7. Kept after
	// the drop precisely so a resurrection is detectable.
	droppedAt map[string]uint64
	// holder is the authority's current holder as this client understands it,
	// and leases is the stamped history invariant 5 judges against.
	holder string
	leases []leaseAt
	// pending are holder checks awaiting a bracketing lease transition.
	pending []pendingHolder
	// awaitingAdoption is invariant 8: set when this client is granted the
	// authority, cleared by the snapshot that should immediately follow.
	awaitingAdoption bool
	// adopting accumulates the adoption snapshot, which may arrive as several
	// batched messages with no end marker. mustAdopt is what invariant 6
	// requires to be in it: every key this client knew about at grant time.
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

// entityKey and posKey are the TWO keys each synthetic entity uses, and the
// split is the single most important thing this rig demonstrates.
//
// **A lossy write replaces the whole blob, so a blob may not mix a
// continuously-superseded field with one that must never go backwards.** The
// lossy and reliable planes are independent on a datagram transport, so a lossy
// write dispatched before a reliable one can reach the relay after it — and
// since the lossy write carries the entire blob, it drags every other field in
// that blob back to its own older value. Nothing corrects it: the relay's copy
// is now the stale one, so the next snapshot propagates the regression rather
// than repairing it.
//
// The fix is not a smarter relay, which has no client-side stamp to judge with.
// It is to keep the two kinds of state in separate keys: the discrete state on
// its own key, written reliably, and the continuous position on another,
// written lossily. Found by this rig's own soak through cmd/meshghost-netsim at
// 5% loss, 2026-08-17 — the single-blob version passed cleanly on tcp and on
// lossless udp, which is exactly the shape of bug that ships.
func entityKey(i int) string { return fmt.Sprintf("e%d", i) }
func posKey(i int) string    { return fmt.Sprintf("e%d.pos", i) }

// onLeaseState records a change of authority. Only the world authority's key
// matters here; controlplane.go's own contended key is a different question.
func (w *worldChecker) onLeaseState(st protocol.LeaseState) {
	if st.Key != w.cfg.authority {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()

	switch st.Reason {
	case protocol.LeaseGranted:
		// **Only an actual CHANGE of holder adopts anything**, which mirrors the
		// relay's own rule exactly. A renew broadcasts "granted" too, and it
		// correctly produces no snapshot — arming on one would make invariant 8
		// fire on the next legitimate write from whoever took over later. Found
		// by this checker's own first soak run, against a relay that was
		// behaving correctly.
		changed := w.holder != st.Holder
		w.holder = st.Holder
		w.leases = append(w.leases, leaseAt{seq: st.Seq, holder: st.Holder})
		if changed && st.Holder == w.self {
			// Invariant 8 arms here. Everything this client currently knows
			// about becomes what invariant 6 demands the adoption carry.
			w.awaitingAdoption = true
			w.mustAdopt = make(map[string]bool, len(w.gen))
			for key := range w.gen {
				if _, dropped := w.droppedAt[key]; !dropped {
					w.mustAdopt[key] = true
				}
			}
		} else if changed {
			// Somebody else took over before the adoption this client was
			// waiting for could arrive. Nothing is owed to it any more.
			w.awaitingAdoption = false
		}
	case protocol.LeaseReleased, protocol.LeaseExpired, protocol.LeaseHolderLeft:
		w.holder = ""
		w.awaitingAdoption = false
		w.leases = append(w.leases, leaseAt{seq: st.Seq, holder: ""})
	default:
		return
	}
	// Bounded: a long soak would otherwise accumulate one entry per handover
	// forever. The tail is all invariant 5 can use, since anything older has
	// already judged every message it could bracket.
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
		// Expected and correct whenever this client is not the holder — a
		// migration run produces these by design, and they say nothing about
		// the world's contents.
		return
	case protocol.WorldTooMany:
		w.report("client world plane hit the per-room key cap with %d entities configured "+
			"-- the rig is asking for more than protocol.MaxWorldKeysPerRoom", w.cfg.entities)
		return
	case protocol.WorldWritten:
		// Invariant 8: while waiting for an adoption snapshot, a live write is
		// exactly the message that must not arrive first. It would mean the
		// snapshot was dispatched after the grant rather than inside it, and
		// this client could already have overwritten what it was about to be
		// told to adopt.
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
	// The receiver-side ordering rule. A message older than what has already
	// been applied to this key is discarded here rather than reported: the
	// relay's stamp order is authoritative and its delivery order across two
	// planes is not, so this is the contract working, not failing.
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
		// A position-only key. It carries no generation by design, because it
		// rides the lossy plane and has nothing that must not go backwards —
		// see entityKey. Invariants 4 and 7 have nothing to say about it.
		return
	}
	// Invariant 7: a set at or below the gen a key was dropped at is a stale
	// write that outlived its own deletion.
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

// checkHolderLocked is invariant 5: the Holder on a written message must be
// whoever held the authority at that message's own stamp. Judged by stamp
// rather than by arrival, so a write that overtook its own grant on a lossy
// transport is not mistaken for a stale host. Caller holds w.mu.
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

// judgeHolderLocked decides whether holder was the authority at seq, or says it
// cannot tell yet. It can only tell once it has seen a lease transition on each
// side of seq — before that, the transition that would explain the message may
// simply not have arrived. Caller holds w.mu.
func (w *worldChecker) judgeHolderLocked(seq uint64, holder string) holderVerdict {
	at, bracketed := "", false
	for _, l := range w.leases {
		if l.seq < seq {
			at = l.holder
			continue
		}
		// A transition at or after seq closes the window, so what came before
		// it is now known to be the last one before seq.
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

// drainPendingLocked re-judges everything that was undecidable, now that a new
// lease transition may have closed its window. Caller holds w.mu.
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

// closeAdoption is invariant 6, run on the audit tick rather than on a message.
// An adoption snapshot has no end marker — it is one or more batched messages,
// each independently complete — so "did it carry everything" is a question that
// can only be asked once the batch has had time to land.
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

// isHolder reports whether this client may write: it holds the authority AND
// its adoption has landed.
//
// **Both halves are required, and the second is the one an adapter gets wrong.**
// The grant arrives fractionally before the world it grants, so a host that
// starts writing the moment it is told it is the host is writing over a world
// it has not seen — it renumbers from its own stale view and rolls the world
// back for everyone. The relay makes this checkable by always sending exactly
// one adoption snapshot, empty world included, so "nothing to adopt" and
// "adoption still in flight" are different observable states.
func (w *worldChecker) isHolder() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.holder == w.self && !w.awaitingAdoption
}

// currentGen is the generation this client believes key is at: the higher of
// what the relay last told it and what it last sent. Caller holds w.mu.
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

// nextGen returns the generation to write for key: one above the highest this
// client knows of.
//
// **Seeded from what was ADOPTED, never from a counter of this client's own.**
// A successor that started its own numbering at zero would roll the world back
// on every handover, which is exactly the failure custody exists to prevent —
// and the rig would then be unable to detect it, since every client would agree
// on a world that kept restarting.
func (w *worldChecker) nextGen(key string) uint64 {
	w.mu.Lock()
	defer w.mu.Unlock()
	next := w.currentGenLocked(key) + 1
	w.issued[key] = next
	return next
}

// ---------------------------------------------------------------------------
// Driving
// ---------------------------------------------------------------------------

// runWorld drives this client's world traffic until stop closes: contend for
// the authority, and while holding it, populate and move N entities and
// periodically hand off.
func (cp *controlPlane) runWorld(stop <-chan struct{}, wg *sync.WaitGroup, cfg worldConfig) {
	defer wg.Done()

	w := cp.world
	claim := time.NewTicker(2 * time.Second)
	defer claim.Stop()
	entity := time.NewTicker(time.Second / time.Duration(max1(cfg.entityHz)))
	defer entity.Stop()
	// A discrete transition every few entity ticks: the reliable half of the
	// workload, and what gives invariant 4 something that must never go
	// backwards. Deliberately much rarer than motion, which is the real ratio
	// an adapter would produce.
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
				// Contended by everyone, so a handover always has a successor
				// waiting rather than being tested against an empty room.
				if err := cp.core.ClaimLease(cfg.authority, 30*time.Second); err != nil {
					log.Printf("meshghost-fakeadapter: client %d could not claim the world authority: %v",
						cp.index, err)
				}
				populated = false
				break
			}
			// Holding: keep it, so the lease does not expire under us between
			// migrations and turn every run into a churn test.
			_ = cp.core.RenewLease(cfg.authority, 30*time.Second)

		case <-entity.C:
			if !w.isHolder() {
				break
			}
			if !populated {
				// **Every key is created reliably.** A lossy create is ignored
				// by the relay, because creation and deletion must travel the
				// same ordered plane or a create can overtake a drop and
				// resurrect an entity. Done once on taking the authority; after
				// that the keys exist and motion can ride the lossy plane.
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
			// A deliberate handoff, which is the case a crash cannot test: the
			// world must survive an ORDERLY release just as much as a
			// disconnect, and freeing it here would be the obvious wrong turn.
			if err := cp.core.ReleaseLease(cfg.authority); err != nil {
				log.Printf("meshghost-fakeadapter: client %d could not release the world authority: %v",
					cp.index, err)
			}

		case <-audit.C:
			w.closeAdoption()
		}
	}
}

// populateWorld writes every entity reliably, which is both how a key is
// legally created and how a successor's adopted world is brought up to date
// with its own numbering.
func (cp *controlPlane) populateWorld(cfg worldConfig, phase float64) {
	for i := 0; i < cfg.entities; i++ {
		key := entityKey(i)
		cp.writeEntity(cfg, key, cp.world.nextGen(key), phase, true)
		// The position key is created reliably too — every create must be, or it
		// can be overtaken by a drop — and only then updated lossily.
		cp.writeEntity(cfg, posKey(i), 0, phase, true)
	}
}

// moveWorld writes every entity's position lossily, on its own key — the
// continuous half, superseded by the next tick, and the reason this plane has an
// unreliable variant at all. It carries no generation, so a stale one arriving
// late can only make a position briefly old, never drag a discrete state back.
func (cp *controlPlane) moveWorld(cfg worldConfig, phase float64) {
	for i := 0; i < cfg.entities; i++ {
		cp.writeEntity(cfg, posKey(i), 0, phase+float64(i), false)
	}
}

// transitionWorld is one discrete change: entity 0 is dropped and immediately
// re-created at a higher generation. Both halves reliable, which is what makes
// invariant 7 a real test rather than a tautology — a lossy re-create would be
// refused by the relay outright.
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

// stopTicker exists only so the deferred cleanup above reads the same as every
// other ticker's. A nil channel has nothing to stop.
func stopTicker(<-chan time.Time) {}
