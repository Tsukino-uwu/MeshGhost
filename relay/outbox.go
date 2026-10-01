package relay

// Each client has its own bounded queue and writer goroutine, so a peer whose socket stopped draining delays only
// itself, not every peer behind it in a fan-out nor the sender's next inbound message.
//
// Writes are not coalesced: no profile has shown the syscall matters, and merged udp/quic datagrams may not fit.

import (
	"errors"
	"log"
	"sync"

	"github.com/Tsukino-uwu/MeshGhost/internal/throttle"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// maxOutboxLines bounds one client's queue: generous against a legitimate burst, small enough that a peer that
// stopped reading is recognised quickly rather than holding memory.
const maxOutboxLines = 256

// outMsg is one queued line and whether it may be dropped: the state plane is lossy and latest-wins, the rest is not.
type outMsg struct {
	line       []byte
	unreliable bool
}

// outbox is a client's bounded FIFO and the goroutine that drains it.
type outbox struct {
	mu     sync.Mutex
	queue  []outMsg
	signal chan struct{} // buffered(1); a nudge, never a carrier
	closed bool

	conn transport.Transport
	id   string

	done chan struct{}

	// refusedLine throttles the skipped-line report: a path that refuses a class of line refuses every one.
	refusedLine throttle.Line
}

func newOutbox(id string, conn transport.Transport) *outbox {
	o := &outbox{
		signal: make(chan struct{}, 1),
		conn:   conn,
		id:     id,
		done:   make(chan struct{}),
	}
	go o.run()
	return o
}

// enqueue adds a line, returning false if the client should be disconnected: a reliable line at a full queue. A full
// queue drops the oldest unreliable (state) line, since state is latest-wins; a reliable line is never dropped,
// because a lost leave strands a ghost and a lost escrow step wedges a trade, while a disconnected client recovers.
func (o *outbox) enqueue(m outMsg) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.closed {
		// A client removed while a fan-out was in flight is ordinary; reporting it would disconnect something gone.
		return true
	}
	if len(o.queue) >= maxOutboxLines {
		if !m.unreliable {
			return false
		}
		if i := o.oldestUnreliableLocked(); i >= 0 {
			o.queue = append(o.queue[:i], o.queue[i+1:]...)
		} else {
			// Every queued line is reliable, so this sample yields instead; latest-wins makes that harmless.
			return true
		}
	}
	o.queue = append(o.queue, m)
	select {
	case o.signal <- struct{}{}:
	default: // already signalled; the writer will see the whole queue
	}
	return true
}

func (o *outbox) oldestUnreliableLocked() int {
	for i, m := range o.queue {
		if m.unreliable {
			return i
		}
	}
	return -1
}

// run is the single writer: a stalled socket blocks only this client's goroutine.
func (o *outbox) run() {
	defer close(o.done)
	for {
		o.mu.Lock()
		for len(o.queue) == 0 && !o.closed {
			o.mu.Unlock()
			<-o.signal
			o.mu.Lock()
		}
		if len(o.queue) == 0 && o.closed {
			o.mu.Unlock()
			return
		}
		m := o.queue[0]
		o.queue = o.queue[1:]
		conn := o.conn
		o.mu.Unlock()

		// Outside the lock: this can block for the whole write timeout, and the sender's enqueue must not wait on it.
		var err error
		if m.unreliable {
			err = conn.SendUnreliable(m.line)
		} else {
			err = conn.Send(m.line)
		}
		if err != nil && refusedBeforeWriting(err) {
			// The connection refused this line before any byte left (a datagram too large for the path, say) and the
			// next may go through; ending the writer would silence a member its pongs keep looking alive.
			if n, ok := o.refusedLine.Allow(); ok {
				log.Printf("relay: a message to %s was refused before sending and skipped: %v (%d so far)", o.id, err, n)
			}
			continue
		}
		if err != nil {
			// The first failed send ends this writer: a connection that refused one write refuses the rest, and
			// trying each queued line would flood the log. Nothing here must survive a dead socket.
			o.mu.Lock()
			dropped := len(o.queue)
			o.queue = nil
			o.closed = true
			o.mu.Unlock()
			log.Printf("relay: send to %s failed: %v -- dropping its %d queued message(s) and closing its writer",
				o.id, err, dropped)
			return
		}
	}
}

// close stops the writer once the queue has drained, so a member removed cleanly still gets its last lifecycle lines.
// A Reject is written inline, not through this queue, and a socket that failed a write is discarded in run.
func (o *outbox) close() {
	o.mu.Lock()
	if o.closed {
		o.mu.Unlock()
		return
	}
	o.closed = true
	o.mu.Unlock()
	select {
	case o.signal <- struct{}{}:
	default:
	}
}

// refusedBeforeWriting reports whether err says the connection refused the message before any of it reached the wire;
// it mirrors transport's writeNeverHappened.
func refusedBeforeWriting(err error) bool {
	var nw interface{ NotWritten() bool }
	return errors.As(err, &nw) && nw.NotWritten()
}
