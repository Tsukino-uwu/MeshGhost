package core

// The bridge's outbound queue: the frame path enqueues without blocking and one writer goroutine per connection
// drains at the adapter's pace, so a slow adapter loses stale ghost positions, never the session. A render_remote
// states current position, so a newer one replaces an unsent one for that peer in place, which bounds the queue by
// the peer count; every other message is an event and keeps its order.

import (
	"encoding/json"
	"errors"
	"log"
	"sync"
	"sync/atomic"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

var (
	// errBridgeGone: the connection is closed, or so far past the queue cap that the adapter is stuck, not behind.
	errBridgeGone = errors.New("the adapter's bridge connection is gone")
	// errBridgeMarshal is a bug in this process (a non-finite float, which encoding/json refuses); it fails that one
	// message and leaves the connection alone.
	errBridgeMarshal = errors.New("bridge payload failed to marshal")
)

// bridgeBugSeen keys logBridgeBugOnce: a NaN in a peer's extras fails to marshal on every render tick, so each bug
// logs once. The keys are one per bridge message type per envelope side, so the map cannot grow with traffic.
var bridgeBugSeen sync.Map

func logBridgeBugOnce(key, format string, args ...any) {
	if _, seen := bridgeBugSeen.LoadOrStore(key, struct{}{}); seen {
		return
	}
	log.Printf(format, args...)
}

// closedAdapterWriter is finished before it starts, for a connection whose socket has already gone. It is returned
// instead of nil because writerFor's callers dereference the result on the frame path.
func closedAdapterWriter(nd transport.Transport) *adapterWriter {
	return &adapterWriter{
		nd:      nd,
		pending: make(map[string]int),
		wake:    make(chan struct{}, 1),
		closed:  true,
	}
}

// adapterQueueCap bounds the event lane, which cannot coalesce; reaching it means a stuck adapter, handled as a
// disconnect. Generous because a pack restart at 512 chasers queues 512 despawns and 512 nametags back to back.
const adapterQueueCap = 8192

// adapterBehindThreshold is how many renders one drain pass must supersede before the log says the adapter is not
// keeping up: a one-frame overrun is normal. A threshold for a person reading the log; Stats counts every supersede.
const adapterBehindThreshold = 256

// queuedMsg is one marshalled line; renderOf lets a newer render replace it without re-parsing.
type queuedMsg struct {
	env []byte
	// renderOf is the player a render_remote is for, "" for every message that must not coalesce.
	renderOf string
}

type adapterWriter struct {
	nd transport.Transport
	// onDead runs when the connection is found dead, by a failed write or at the queue cap: it frees the core's
	// admission slot at once, so a game reconnecting within milliseconds is not refused "busy".
	onDead func()

	mu sync.Mutex
	q  []queuedMsg
	// pending maps a player id to its unsent render's index in q; a queued despawn removes the entry, so a later
	// render lands after the despawn.
	pending map[string]int
	wake    chan struct{}
	closed  bool
	// writing is true from taking a batch until its last Send returns; see idle.
	writing bool
	// dropped counts renders superseded before they were written; stalls counts drain passes that found work waiting.
	dropped uint64
	stalls  uint64
	// behind is whether the adapter is currently not keeping up, so the log gets one line when that starts and one
	// when it ends; a line per superseded render would itself become the bottleneck.
	behind bool
	// droppedAtBehind is the count just before the current behind-period, for the recovery line. droppedAtLastPass
	// is the count at the end of the previous drain pass, which "caught up" is measured against.
	droppedAtBehind   uint64
	droppedAtLastPass uint64
	// superseded is the Core's process-lifetime counter: a pointer, not a call into the Core, because this runs under
	// w.mu on the frame path.
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

// enqueue adds one message, coalescing a render onto an unsent one for the same player. It never blocks: it runs on
// the frame path and on chaser goroutines. It reports false only when the connection is finished.
func (w *adapterWriter) enqueue(m queuedMsg) bool {
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return false
	}
	if m.renderOf != "" {
		if i, ok := w.pending[m.renderOf]; ok {
			// In place, so a peer cannot overtake another by moving more often.
			w.q[i] = m
			w.dropped++
			if w.superseded != nil {
				atomic.AddUint64(w.superseded, 1)
			}
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
		// Close before the teardown: no write failed here to close it, and a mod's reconnect keys off the close.
		_ = w.nd.Close()
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

// forgetPending stops a queued render for this player from being coalesced onto, so a render queued after a despawn
// lands after it.
func (w *adapterWriter) forgetPending(playerID string) {
	w.mu.Lock()
	delete(w.pending, playerID)
	w.mu.Unlock()
}

// run drains the queue for as long as the connection lives; it is the only thing that writes to the adapter.
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
		// A taken batch is committed to the wire; renders arriving now queue behind it.
		batch := w.q
		w.q = nil
		w.pending = make(map[string]int)
		w.writing = true
		w.stalls++
		// Caught up means nothing was superseded while the previous batch was in flight. Compare against the count at
		// the end of that pass: the count when behind began only grows.
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
				w.mu.Lock()
				w.writing = false
				w.mu.Unlock()
				// The deadline expired with nobody reading, or the socket is gone; transport.Send has closed it.
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
		w.mu.Lock()
		w.writing = false
		w.mu.Unlock()
	}
}

// idle reports that nothing is queued and nothing is in flight. run clears w.q when it takes a batch, several
// syscalls before the writes, so a test that waits on the queue alone races the wire. Production never waits on it.
func (w *adapterWriter) idle() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.q) == 0 && !w.writing
}

// close stops the writer. Idempotent; anything still queued is abandoned.
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

// queueLen is how many messages are still waiting to be taken; a batch being written is not counted (see idle).
func (w *adapterWriter) queueLen() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.q)
}

func (w *adapterWriter) stats() (dropped, stalls uint64) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.dropped, w.stalls
}

// marshalBridge builds one envelope line, so the queue holds bytes and the writer goroutine only writes.
func marshalBridge(t bridge.MessageType, payload any) ([]byte, bool) {
	b, err := json.Marshal(payload)
	if err != nil {
		logBridgeBugOnce(string(t)+":payload", "core: BUG: %s payload failed to marshal: %v -- that message is dropped and the bridge connection is left alone; further %s marshal failures are silent", t, err, t)
		return nil, false
	}
	env, err := json.Marshal(bridge.Envelope{Type: t, Payload: b})
	if err != nil {
		logBridgeBugOnce(string(t)+":envelope", "core: BUG: %s envelope failed to marshal: %v -- that message is dropped and the bridge connection is left alone; further %s marshal failures are silent", t, err, t)
		return nil, false
	}
	return env, true
}
