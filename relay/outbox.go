package relay

// One outbound queue per client, and why the fan-out could not stay serial.
//
// Room.forward wrote to every recipient in a loop, on the sending client's own
// read goroutine, while holding transport.deliverMu. So one peer whose socket
// had stopped draining blocked delivery to every peer behind it in that loop --
// for up to transport.DefaultWriteTimeout, ten seconds -- and blocked the
// SENDER's next inbound message for the same duration. Demonstrated 2026-08-28
// with a stalled transport and a healthy one in the same room: the healthy peer
// received nothing until the stalled one was released.
//
// That is a correctness defect rather than an inefficiency, which is why it is
// worth a concurrency change to fix. A room is meant to degrade one peer at a
// time.
//
// WHAT THIS DELIBERATELY DOES NOT DO: coalesce. Several lines waiting for the
// same peer could be written in one syscall, and NDJSON makes that exact. It is
// not built because nothing has shown it would pay: the 2026-08-28 profile puts
// ~58% of the relay's per-state path in encoding/json and the syscall nowhere
// near the top, and a coalescing writer would have to be careful never to merge
// datagrams on udp/quic (netx/udpconn's MaxDatagramBytes is 1200, and
// Pseudoregalia's state lines are 597+, so two do not reliably fit -- and a
// merged datagram doubles the blast radius of a single loss on the plane that
// is deliberately lossy). Left as an idea with the measurement it would need.

import (
	"errors"
	"log"
	"sync"

	"github.com/Tsukino-uwu/MeshGhost/internal/throttle"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// maxOutboxLines bounds one client's queue. Generous against any legitimate
// burst -- a 32-seat room at 20Hz offers each member ~620 lines a second, so
// this is a fraction of a second of backlog -- and small enough that a peer
// which has genuinely stopped reading is recognised quickly rather than
// consuming memory on its behalf.
const maxOutboxLines = 256

// outMsg is one queued line plus the only thing the writer needs to know about
// it: whether it may be dropped. That maps exactly onto the plane it came from
// (agent_docs/contract.md) -- the state plane is lossy and latest-wins,
// everything else is not.
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

	// refusedLine throttles the skipped-line report: a member whose path
	// refuses a class of line refuses every one of them.
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

// enqueue adds a line, returning false if the client should be disconnected --
// which happens only when a message that may NOT be dropped arrives at a full
// queue.
//
// The two-class overflow policy is the contract's, not an invention:
//
//   - An unreliable line (state) displaces the OLDEST queued unreliable line.
//     The state plane is latest-wins, so when there is a choice about which
//     position sample to lose, the stale one is always the right answer. This
//     is the same reasoning as the relay's receive gate dropping excess samples
//     rather than queueing them.
//   - A reliable line (join, leave, welcome, event, lease, escrow, world) is
//     never dropped. A lost leave strands a ghost permanently, and a lost
//     escrow step wedges a trade. A full queue means the peer is not draining
//     at all, so the honest response is to disconnect it -- which the client
//     retries and recovers from -- rather than to silently lose the one message
//     that would have kept everyone consistent.
func (o *outbox) enqueue(m outMsg) bool {
	o.mu.Lock()
	defer o.mu.Unlock()
	if o.closed {
		// Not a failure: a client removed from the room while a fan-out was
		// already in flight is ordinary, and reporting it would disconnect
		// something already gone.
		return true
	}
	if len(o.queue) >= maxOutboxLines {
		if !m.unreliable {
			return false
		}
		if i := o.oldestUnreliableLocked(); i >= 0 {
			o.queue = append(o.queue[:i], o.queue[i+1:]...)
		} else {
			// Every queued line is reliable and none may be dropped, so this
			// sample yields instead. Latest-wins makes that harmless.
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

// run is the single writer. One goroutine per client is what makes a stalled
// socket that client's own problem: it blocks here, in its own goroutine,
// while every other member's writer carries on.
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

		// Outside the lock, always: this is the call that can block for the
		// whole write timeout, and holding the queue lock across it would
		// reintroduce the head-of-line stall one level down -- the sender's
		// enqueue would wait on the recipient's socket, which is the exact
		// shape this file exists to remove.
		var err error
		if m.unreliable {
			err = conn.SendUnreliable(m.line)
		} else {
			err = conn.Send(m.line)
		}
		if err != nil && refusedBeforeWriting(err) {
			// Not a dead socket: the connection refused THIS line before any
			// byte left (a datagram too large for the path, say), and the next
			// line may go through. Ending the writer on it discarded every
			// join, leave and state owed to that member for the rest of its
			// connection while its pongs kept it looking alive (pass 5 of the
			// adversarial review, 2026-09-16, PM-1). Drop the one line and go on.
			if n, ok := o.refusedLine.Allow(); ok {
				log.Printf("relay: a message to %s was refused before sending and skipped: %v (%d so far)", o.id, err, n)
			}
			continue
		}
		if err != nil {
			// The FIRST failed send ends this writer. A connection that
			// refused one write refuses the rest, and until 2026-09-15 the
			// loop kept trying every queued line and logging each failure:
			// a member that stopped reading cost ~256 lines per cycle of
			// its queue, on a log that holds 1 MiB (fourth review, A4/C4).
			// Nothing owed is lost -- see close for why the queue no longer
			// carries anything that must survive a dead socket.
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

// close stops the writer once the queue has drained.
//
// Draining rather than discarding used to be justified by the Reject a
// leaving client is owed; that Reject is written inline (relay.go's
// rate-limit path and rejectAndClose call sendEnvelope directly), not
// through this queue, so what draining protects today is the ordinary
// tail of a session: the last lifecycle lines a member that is being
// removed cleanly was already going to get. A socket that has failed a
// write is a different case and run handles it by discarding.
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

// refusedBeforeWriting reports whether err says the connection refused the
// message outright, putting none of it on the wire -- transport's
// writeNeverHappened, whose structural interface this mirrors.
func refusedBeforeWriting(err error) bool {
	var nw interface{ NotWritten() bool }
	return errors.As(err, &nw) && nw.NotWritten()
}
