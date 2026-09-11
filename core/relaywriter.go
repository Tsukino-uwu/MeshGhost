package core

// The core's OUTBOUND queue to the relay, and why the frame path could not keep
// writing the socket itself.
//
// THE DEFECT (found in the 2026-09-07 adversarial review, fixed 2026-09-11).
// sendState wrote the relay socket synchronously, and its caller chain starts at
// onAdapterFrame -- which runs on the BRIDGE connection's read goroutine. So a
// relay that stopped reading (a stalled host, a saturated uplink, a peer's box
// swapping) blocked that read loop for the whole write deadline, ten seconds by
// default. The bridge socket's buffer then fills, and the adapter's next write
// blocks ON THE GAME'S MAIN THREAD: a frozen game, on a machine where nothing is
// wrong, because something on the far side of the internet stopped reading.
//
// The core->adapter direction was made non-blocking on 2026-09-07 for the same
// reason and with the same shape (core/adapterwriter.go, and the user's rule in
// its header: the client may never be the limiting factor). This is that fix
// applied to the other direction, and the last frame-path write in the process.
//
// THE OVERFLOW POLICY IS THE CONTRACT'S, not an invention, and it is the relay's
// own (relay/outbox.go's enqueue says it in full): an unreliable line -- state,
// the plane agent_docs/contract.md defines as lossy and latest-wins -- displaces
// the OLDEST queued unreliable line, because when a position sample must be lost
// the stale one is always the right one to lose. A reliable line (an event, a
// world write, a lease or escrow step) is never dropped; a full queue means the
// relay is not draining at all, and the honest answer is to drop the CONNECTION,
// which this core already knows how to recover from by reconnecting with its
// resume token.
//
// WHY DROPPING A QUEUED STATE IS SOUND WITH ADR 0045's prev. A state carries the
// sample before it as loss cover, and a newer state's prev is exactly the sample
// this queue would discard -- so a receiver that gets only the newer line still
// reconstructs both. Coalescing here complements the redundancy rather than
// fighting it.

import (
	"log"
	"sync"

	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// maxRelayOutboxLines bounds what this core will hold for a relay that has
// stopped reading. Deliberately the same 256 as the relay's own per-client
// queue: the two ends of one connection have no reason to disagree about how
// far behind is "behind" rather than "gone", and a core sends ONE player's
// traffic where the relay sends a whole room's, so this is the more generous
// side of that number already -- ~17 seconds of backlog at the shipped 15Hz.
const maxRelayOutboxLines = 256

// relayWriter is one relay connection's bounded FIFO and the goroutine that
// drains it. One per connection, replaced with the connection.
type relayWriter struct {
	mu sync.Mutex
	// idle is broadcast when the queue is empty AND nothing is mid-write. It
	// exists for the tests, which assert on what a fake transport received: a
	// send that used to return when the bytes were handed over now returns when
	// they are handed to this goroutine, and "did it arrive" is a question only
	// the writer can answer. Nothing in production waits on it.
	idle    *sync.Cond
	writing bool

	queue  []outRelayMsg
	signal chan struct{} // buffered(1); a nudge, never a carrier
	closed bool

	conn transport.Transport

	// onStuck is called once, off the writer's own goroutine, when a line that
	// may NOT be dropped arrives at a full queue. The core uses it to close the
	// connection so its ordinary reconnect path runs.
	onStuck func()
	stuck   bool
}

type outRelayMsg struct {
	line       []byte
	unreliable bool
}

func newRelayWriter(conn transport.Transport, onStuck func()) *relayWriter {
	w := &relayWriter{
		signal:  make(chan struct{}, 1),
		conn:    conn,
		onStuck: onStuck,
	}
	w.idle = sync.NewCond(&w.mu)
	go w.run()
	return w
}

// enqueue never blocks and never waits for the socket. It reports false only
// when the connection should be given up on -- a reliable line at a full queue.
func (w *relayWriter) enqueue(m outRelayMsg) bool {
	w.mu.Lock()
	if w.closed {
		// A connection already replaced or torn down while a send was in
		// flight. Ordinary, and not this send's business to report.
		w.mu.Unlock()
		return true
	}
	if len(w.queue) >= maxRelayOutboxLines {
		if !m.unreliable {
			first := !w.stuck
			w.stuck = true
			onStuck := w.onStuck
			w.mu.Unlock()
			if first && onStuck != nil {
				onStuck()
			}
			return false
		}
		if i := w.oldestUnreliableLocked(); i >= 0 {
			w.queue = append(w.queue[:i], w.queue[i+1:]...)
		} else {
			// Every queued line is reliable, so this sample yields instead.
			// Latest-wins is what makes that harmless.
			w.mu.Unlock()
			return true
		}
	}
	w.queue = append(w.queue, m)
	w.mu.Unlock()
	select {
	case w.signal <- struct{}{}:
	default: // already signalled; the writer will see the whole queue
	}
	return true
}

func (w *relayWriter) oldestUnreliableLocked() int {
	for i, m := range w.queue {
		if m.unreliable {
			return i
		}
	}
	return -1
}

// run is the single writer. Blocking here is the whole point: it is this
// goroutine that waits out a stalled relay socket, and nothing that produces a
// frame ever joins it.
func (w *relayWriter) run() {
	for {
		w.mu.Lock()
		for len(w.queue) == 0 && !w.closed {
			w.mu.Unlock()
			<-w.signal
			w.mu.Lock()
		}
		if len(w.queue) == 0 && w.closed {
			w.mu.Unlock()
			return
		}
		m := w.queue[0]
		w.queue = w.queue[1:]
		conn := w.conn
		w.writing = true
		w.mu.Unlock()

		// Outside the lock, always: this is the call that can block for the
		// whole write timeout, and holding the queue lock across it would move
		// the stall one level down onto every enqueue -- which is the shape
		// this file exists to remove.
		var err error
		if m.unreliable {
			err = conn.SendUnreliable(m.line)
		} else {
			err = conn.Send(m.line)
		}
		w.mu.Lock()
		w.writing = false
		if len(w.queue) == 0 {
			w.idle.Broadcast()
		}
		w.mu.Unlock()
		if err != nil {
			// One line per failure, as the synchronous path logged. A dead
			// socket also ends the read loop, which is what actually drives
			// the teardown; this is the report, not the mechanism.
			log.Printf("core: send to relay failed: %v", err)
		}
	}
}

// waitDrained blocks until everything enqueued so far has been written (or
// failed). Test-only -- see relayWriter.idle.
func (w *relayWriter) waitDrained() {
	if w == nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	for len(w.queue) > 0 || w.writing {
		w.idle.Wait()
	}
}

// waitRelayDrained is waitDrained for whatever connection this Core holds now.
// Test-only: production code never needs to know when a queued line landed,
// which is the whole point of queueing it.
func (c *Core) waitRelayDrained() {
	if c == nil {
		return
	}
	c.mu.Lock()
	w := c.relayOut
	c.mu.Unlock()
	w.waitDrained()
}

// close stops the writer once the queue has drained. Draining rather than
// discarding, for the same reason the relay's outbox drains: the last line a
// session writes is often the one that matters most to everyone else.
func (w *relayWriter) close() {
	if w == nil {
		return
	}
	w.mu.Lock()
	if w.closed {
		w.mu.Unlock()
		return
	}
	w.closed = true
	w.mu.Unlock()
	select {
	case w.signal <- struct{}{}:
	default:
	}
}

// sendToRelay hands one envelope to the current connection's writer. It is the
// only path a FRAME may take to the relay.
//
// Returns false when there is no connection, or when the connection has been
// given up on -- both of which the caller treats as "not sent", exactly as a
// failed synchronous write was treated.
func (c *Core) sendToRelay(conn transport.Transport, env []byte, unreliable bool) bool {
	c.mu.Lock()
	if c.relay != conn {
		// The connection was replaced between the caller reading it and here.
		// Writing it anyway would put this frame on a socket nobody reads.
		c.mu.Unlock()
		return false
	}
	if c.relayOut == nil {
		// ATTACHED LAZILY, so that a Core whose relay was set directly -- an
		// embedder, and most of this package's own tests -- gets the queue
		// too. ConnectRelay creates it eagerly because it also has to close
		// the previous connection's; this is the same writer, made on first
		// use of a connection that arrived some other way.
		c.relayOut = newRelayWriter(conn, func() { c.relayStuck(conn) })
	}
	w := c.relayOut
	c.mu.Unlock()
	return w.enqueue(outRelayMsg{line: env, unreliable: unreliable})
}

// relayStuck is what a full queue of undroppable lines means: the relay has
// stopped reading this connection entirely. Closing it is the honest response
// and the recoverable one -- the read loop ends, the ordinary reconnect path
// runs, and the resume token keeps the player's seat.
func (c *Core) relayStuck(conn transport.Transport) {
	log.Printf("core: the relay has not read %d queued messages -- treating the connection as "+
		"dead and reconnecting; a resume keeps this player's seat and nobody else sees a leave",
		maxRelayOutboxLines)
	_ = conn.Close()
}
