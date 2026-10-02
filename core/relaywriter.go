package core

// The core's outbound queue to the relay, so a relay that stops reading cannot block the bridge read goroutine, and
// through it the game's main thread. A state line at a full queue displaces the oldest queued state, whose sample the
// newer state's prev carries; a reliable line is never dropped, and a full queue of them closes the connection for
// the ordinary reconnect.

import (
	"log"
	"sync"

	"github.com/Tsukino-uwu/MeshGhost/internal/throttle"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// maxRelayOutboxLines matches the relay's own per-client queue: both ends of one connection should agree where behind
// becomes gone, and a core sends one player's traffic where the relay sends a room's.
const maxRelayOutboxLines = 256

// relayWriter is one relay connection's bounded FIFO and the goroutine that drains it.
type relayWriter struct {
	mu sync.Mutex
	// idle is broadcast when the queue is empty and nothing is mid-write, for tests that assert on what a transport
	// received; nothing in production waits on it.
	idle    *sync.Cond
	writing bool

	queue  []outRelayMsg
	signal chan struct{} // buffered(1); a nudge, never a carrier
	closed bool

	conn transport.Transport

	// onStuck runs once, off the writer's goroutine, when a line that may not be dropped meets a full queue; the core
	// closes the connection so its reconnect path runs.
	onStuck func()
	stuck   bool

	// failLine throttles the send-failure report: a dead connection fails every queued line.
	failLine throttle.Line
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

// enqueue never blocks. It reports false only when the connection should be given up on: a reliable line at a full
// queue.
func (w *relayWriter) enqueue(m outRelayMsg) bool {
	w.mu.Lock()
	if w.closed {
		// Replaced or torn down mid-send: ordinary, and not this send's to report.
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
			// Every queued line is reliable, so this sample yields; latest-wins makes that harmless.
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

// run is the single writer: this goroutine waits out a stalled relay socket, and nothing that produces a frame joins
// it.
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

		// Outside the lock: this can block for the whole write timeout, which would stall every enqueue.
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
			// Only the report: the read loop ending on a dead socket is what drives the teardown.
			if n, ok := w.failLine.Allow(); ok {
				log.Printf("core: send to relay failed: %v (%d so far)", err, n)
			}
		}
	}
}

// waitDrained blocks until everything enqueued so far has been written or failed. Test-only.
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

// waitRelayDrained is waitDrained for whatever connection this Core holds now. Test-only.
func (c *Core) waitRelayDrained() {
	if c == nil {
		return
	}
	c.mu.Lock()
	w := c.relayOut
	c.mu.Unlock()
	w.waitDrained()
}

// close stops the writer once the queue has drained: the last line a session writes is often the one that matters
// most to everyone else.
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

// sendToRelay hands one envelope to the current connection's writer, the only path a frame takes to the relay. False
// means there is no connection, or it was given up on.
func (c *Core) sendToRelay(conn transport.Transport, env []byte, unreliable bool) bool {
	c.mu.Lock()
	if c.relay != conn {
		// Replaced since the caller read it: this frame would go to a socket nobody reads.
		c.mu.Unlock()
		return false
	}
	if c.relayOut == nil {
		// Lazily, so a Core whose relay was set directly (an embedder, most tests) gets the queue too.
		c.relayOut = newRelayWriter(conn, func() { c.relayStuck(conn) })
	}
	w := c.relayOut
	c.mu.Unlock()
	return w.enqueue(outRelayMsg{line: env, unreliable: unreliable})
}

// relayStuck closes a connection the relay stopped reading: the read loop ends, the reconnect runs, and the resume
// token keeps the player's seat.
func (c *Core) relayStuck(conn transport.Transport) {
	log.Printf("core: the relay has not read %d queued messages -- treating the connection as "+
		"dead and reconnecting; a resume keeps this player's seat and nobody else sees a leave",
		maxRelayOutboxLines)
	_ = conn.Close()
}
