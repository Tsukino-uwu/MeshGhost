package core

// The bridge's outbound queue: what keeps a SLOW adapter from becoming a DEAD
// one (ADR pending; the defect is recorded in agent_docs/pitfalls.md).
//
// THE DEFECT. The core answered every adapter frame by writing one
// render_remote line per remote, synchronously, on the frame goroutine. That
// cost is N x the game's frame rate: a tester's 512-chaser pack at
// Pseudoregalia's ~180Hz is 92,160 messages and 35 MB/s down one loopback
// NDJSON socket, against an adapter that can parse a fraction of it. Twice --
// at 343 ghosts on 2026-09-06 and ~350 on 2026-09-07 -- the socket buffer
// filled, the write deadline expired with a line HALF-WRITTEN, and the core
// tore down a session whose game was perfectly healthy and merely busy.
//
// The user's rule, 2026-09-07: "I never want the server/client to be the
// limiting factor for anything ... if you set 512, you should be able to
// eventually reach there if the game itself don't crash."
//
// SO: THE FRAME PATH NO LONGER WRITES. It enqueues, never blocking and never
// failing, and one writer goroutine per connection drains the queue at
// whatever rate the adapter manages. What a slow adapter costs is now
// intermediate ghost positions it would never have drawn -- not the session.
//
// COALESCING IS WHAT MAKES THE QUEUE BOUNDED, and it is only sound because of
// what a render_remote MEANS: "this peer is here now". It is a statement of
// current position, not an event, so an unsent one is worthless the moment a
// newer one exists for the same peer. A newer render REPLACES an older unsent
// render for that player IN PLACE, keeping its position in the queue, so the
// queue can never hold more renders than there are peers however far behind
// the adapter falls. Everything else -- despawns, nametags, policy,
// bridge_ready, recording state -- is an EVENT, is never coalesced, and keeps
// its order relative to everything around it.
//
// This is the same shape as the relay's per-writer queues and as
// chaser.offer's non-blocking hand-off: nothing on a frame path may wait for
// something slower than the frame.

import (
	"encoding/json"
	"errors"
	"log"
	"sync"
	"sync/atomic"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// The two ways a send can fail now that slowness is not one of them.
var (
	// errBridgeGone: the connection is closed, or so far past the queue cap
	// that the adapter is stuck rather than behind.
	errBridgeGone = errors.New("the adapter's bridge connection is gone")
	// errBridgeMarshal is a bug in this process, never a peer's doing.
	errBridgeMarshal = errors.New("bridge payload failed to marshal")
)

// adapterQueueCap bounds the queue in ENTRIES. Renders coalesce, so the
// render side is already bounded by the peer count (at most
// protocol.MaxRosterSize + the local ghosts); this cap exists for the event
// lane, which cannot coalesce. Reaching it means the adapter has taken
// nothing for long enough to accumulate thousands of despawns and nametags,
// which is a stuck adapter rather than a slow one -- and that is a real
// disconnect, handled as one.
//
// Deliberately generous: a pack restart at 512 chasers legitimately queues
// 512 despawns and 512 nametags back to back, and that must not be mistaken
// for a stuck game.
const adapterQueueCap = 8192

// adapterBehindThreshold is how many renders must be superseded WITHIN ONE
// drain pass before the log says the adapter is not keeping up.
//
// IT EXISTS BECAUSE THE FIRST VERSION HAD NO THRESHOLD AT ALL, and the user's
// first live run with 512 chasers showed what that costs: 31 "not keeping up"
// / "keeping up again" pairs in four minutes, and 23 of them reported a single
// superseded position. A one-frame overrun is normal and is exactly what the
// queue is for -- saying so is noise, and a log that cries wolf 31 times is
// worse than one that says nothing.
//
// 256 is read off that same run: the real episodes superseded 2012, 284, 275,
// 211, 180 and 75, while the noise was 1. Deliberately coarse -- this is a
// legibility threshold for a human reading a log, not a control input, and the
// exact number matters to nobody. The COUNT is still exact in Stats
// (RendersSuperseded) whether or not a line was printed.
const adapterBehindThreshold = 256

// queuedMsg is one already-marshalled line plus what it is about, so a
// replacement can find it without re-parsing anything.
type queuedMsg struct {
	env []byte
	// renderOf is the player a render_remote is for, "" for everything else.
	// Only a render carries one, which is exactly the set that may coalesce.
	renderOf string
}

// adapterWriter owns the outbound half of one bridge connection.
type adapterWriter struct {
	nd transport.Transport
	// onDead runs once, on the writer goroutine, when a write actually fails.
	// It frees the core's admission slot immediately rather than waiting for
	// the read loop to notice -- the 2026-09-06 lockout, where a game
	// reconnected within 150 ms and was refused "busy" by the core whose
	// adapter had just died.
	onDead func()

	mu sync.Mutex
	q  []queuedMsg
	// pending maps a player id to its unsent render's index in q. An entry
	// exists only while that render is still queued: it is removed when the
	// message is written, and when a despawn for the same player is queued
	// (so a later render appends AFTER the despawn instead of replacing a
	// message that now sits before it -- the respawn ordering bug this map
	// would otherwise cause).
	pending map[string]int
	wake    chan struct{}
	closed  bool
	// dropped counts renders superseded before they were ever written --
	// the visible measure of how far behind the adapter is running, and the
	// number to read when someone asks whether the bridge is the limit.
	dropped uint64
	// stalls counts how many times the queue was non-empty when the writer
	// came back for more, i.e. the adapter did not keep up with a whole tick.
	stalls uint64
	// behind is whether the adapter is CURRENTLY not keeping up, so the log
	// gets one line when that starts and one when it ends rather than a line
	// per superseded render -- which at 512 ghosts would be tens of thousands
	// a second and would itself become the bottleneck. droppedAtBehind is the
	// count when it started, so the recovery line can say what it cost.
	behind bool
	// droppedAtBehind is the count just BEFORE the first supersede of the
	// current behind-period, so the recovery line reports what that period
	// actually cost. droppedAtLastPass is the count at the end of the previous
	// drain pass, which is what "nothing was superseded while the last batch
	// was in flight" is measured against.
	droppedAtBehind   uint64
	droppedAtLastPass uint64
	// superseded is the Core's cumulative counter, added to as renders are
	// coalesced. A pointer rather than a call back into the Core because
	// this runs under w.mu on the frame path: an atomic add is the whole
	// cost, and counters here are cumulative for the life of the process
	// (core/stats.go) rather than per connection.
	superseded *uint64
}

func newAdapterWriter(nd transport.Transport, superseded *uint64, onDead func()) *adapterWriter {
	w := &adapterWriter{
		nd:         nd,
		onDead:     onDead,
		superseded: superseded,
		pending:    make(map[string]int),
		wake:       make(chan struct{}, 1),
	}
	go w.run()
	return w
}

// enqueue adds one message, coalescing a render onto an unsent one for the
// same player. It never blocks and never returns an error, because it is
// called from the frame path and from chaser goroutines, and neither may be
// made to wait for a game that is busy drawing.
//
// It reports false only when the connection is finished -- closed, or so far
// past adapterQueueCap that the adapter is stuck rather than slow.
func (w *adapterWriter) enqueue(m queuedMsg) bool {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return false
	}
	if m.renderOf != "" {
		if i, ok := w.pending[m.renderOf]; ok {
			// THE COALESCE. In place, so this peer keeps the queue position
			// its first unsent render had: a peer cannot overtake another by
			// moving more often, and the adapter still sees peers in a
			// stable order rather than sorted by who moved last.
			w.q[i] = m
			w.dropped++
			if w.superseded != nil {
				atomic.AddUint64(w.superseded, 1)
			}
			// ONE LINE WHEN IT STARTS, not one per superseded render: at 512
			// ghosts that would be tens of thousands a second and the logging
			// would become the bottleneck it is reporting on. And not until
			// the adapter is meaningfully behind rather than one frame behind
			// -- see adapterBehindThreshold, and the 31 flapping pairs that
			// put it there.
			first := !w.behind && w.dropped-w.droppedAtLastPass >= adapterBehindThreshold
			if first {
				w.behind = true
				w.droppedAtBehind = w.droppedAtLastPass
			}
			w.mu.Unlock()
			if first {
				log.Printf("core: the adapter is not keeping up -- superseding stale ghost positions " +
					"rather than queueing them (the session is fine; this is the bridge shedding load)")
			}
			return true
		}
	}
	if len(w.q) >= adapterQueueCap {
		w.closed = true
		w.mu.Unlock()
		log.Printf("core: the adapter has taken nothing for %d queued messages -- treating it as stuck, not slow", adapterQueueCap)
		if w.onDead != nil {
			w.onDead()
		}
		return false
	}
	w.q = append(w.q, m)
	if m.renderOf != "" {
		w.pending[m.renderOf] = len(w.q) - 1
	}
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
	return true
}

// forgetPending stops a queued render for this player from being coalesced
// onto, so anything queued afterwards lands after it in order. Called when a
// despawn is queued for the same id.
func (w *adapterWriter) forgetPending(playerID string) {
	w.mu.Lock()
	delete(w.pending, playerID)
	w.mu.Unlock()
}

// run drains the queue for as long as the connection lives. One goroutine per
// bridge connection, and the ONLY thing that ever writes to the adapter.
func (w *adapterWriter) run() {
	for {
		w.mu.Lock()
		if w.closed && len(w.q) == 0 {
			w.mu.Unlock()
			return
		}
		if len(w.q) == 0 {
			w.mu.Unlock()
			<-w.wake
			continue
		}
		// Take the WHOLE batch and reset the index map: everything in `batch`
		// is committed to the wire in this order and can no longer be
		// coalesced onto. Renders arriving while this batch is being written
		// queue fresh behind it, which is what makes the next batch the
		// newest positions rather than a backlog of old ones.
		batch := w.q
		w.q = nil
		w.pending = make(map[string]int)
		w.stalls++
		// CAUGHT UP means nothing was superseded while the previous batch was
		// in flight: the adapter drank the whole last batch before the frame
		// path could outrun it again. Compared against the count at the END of
		// the previous pass, not against the count when `behind` began -- that
		// only ever grows, so comparing to it could never become true.
		recovered := uint64(0)
		if w.behind && w.dropped == w.droppedAtLastPass {
			w.behind = false
			recovered = w.dropped - w.droppedAtBehind
		}
		w.droppedAtLastPass = w.dropped
		w.mu.Unlock()
		if recovered > 0 {
			log.Printf("core: the adapter is keeping up again (%d stale ghost position(s) superseded while it was behind)", recovered)
		}

		for _, m := range batch {
			if err := w.nd.Send(m.env); err != nil {
				// A write that fails here is the real thing: the deadline
				// expired with nobody reading at all, or the socket is gone.
				// transport.Send has already closed it.
				log.Printf("core: the adapter's socket failed a write (%v) -- it is gone, not merely behind", err)
				w.mu.Lock()
				w.closed = true
				w.q = nil
				w.mu.Unlock()
				if w.onDead != nil {
					w.onDead()
				}
				return
			}
		}
	}
}

// close stops the writer. Idempotent; anything still queued is abandoned,
// because a connection being torn down has nowhere to put it.
func (w *adapterWriter) close() {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.closed = true
	w.q = nil
	w.mu.Unlock()
	select {
	case w.wake <- struct{}{}:
	default:
	}
}

// stats reports how far behind the adapter has been running: renders
// superseded before they could be written, and how many drain passes found
// work already waiting.
func (w *adapterWriter) stats() (dropped, stalls uint64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.dropped, w.stalls
}

// marshalBridge builds one envelope line. Split from the send so the queue
// holds bytes rather than an interface: marshalling happens once, on the
// goroutine that had the value, and the writer goroutine only writes.
func marshalBridge(t bridge.MessageType, payload any) ([]byte, bool) {
	b, err := json.Marshal(payload)
	if err != nil {
		log.Printf("core: BUG: %s payload failed to marshal: %v", t, err)
		return nil, false
	}
	env, err := json.Marshal(bridge.Envelope{Type: t, Payload: b})
	if err != nil {
		log.Printf("core: BUG: %s envelope failed to marshal: %v", t, err)
		return nil, false
	}
	return env, true
}
