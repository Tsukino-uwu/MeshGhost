// Command meshghost-netsim is a fault-injecting proxy between clients and a relay, so a real session can run under
// loss, latency, jitter, reordering, duplication and partitions.
//
// It mirrors the relay's port numbers on a different loopback address (127.0.0.1:7777 as 127.0.0.2:7777). Transport
// discovery sends the port but not the host, so a client upgrading to udp or quic reuses the host it first connected
// to; a different port number would route the upgrade around the proxy, and the session would test nothing.
//
// On tcp it only delays, jitters and partitions: dropping part of a proxied byte stream corrupts it rather than
// simulating loss, because the kernel's retransmission sits below the proxy. Loss, reordering and duplication apply
// to udp and quic only.
//
// It knows nothing of MeshGhost's protocol and only moves bytes, so it stays useful if the wire format changes.
package main

import (
	"flag"
	"fmt"
	"io"
	"log"
	"math/rand"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// direction of one flow, for per-direction fault targeting.
type direction int

const (
	up   direction = iota // client -> relay
	down                  // relay -> client
)

func (d direction) String() string {
	if d == up {
		return "up"
	}
	return "down"
}

// faults is the seeded fault model, shared by every flow so one -seed describes the whole run and a bad run can be
// replayed. A seed reproduces the fault distribution, not a bit-identical run: concurrent flows interleave as the
// scheduler decides.
type faults struct {
	loss         float64
	dup          float64
	reorder      float64
	reorderDelay time.Duration
	latency      time.Duration
	jitter       time.Duration
	directions   map[direction]bool

	partitionEvery time.Duration
	partitionFor   time.Duration
	start          time.Time

	// burstMean is the mean length of a bad period, 0 for memoryless loss; the state below it is guarded by mu.
	burstMean  time.Duration
	inBad      bool
	burstUntil time.Time
	goodUntil  time.Time

	mu  sync.Mutex
	rng *rand.Rand
}

// losing reports whether this datagram is lost. Without -loss-burst it flips an independent coin per datagram, which
// almost never loses a run of consecutive samples, the thing that breaks an interpolation buffer. With it, a
// two-state Gilbert model: good loses nothing, bad loses everything, periods are exponential with bad ones averaging
// -loss-burst, and -loss stays the long-run share of time spent bad, so only the arrangement changes. Opt-in,
// because every interp verdict on record was made against the memoryless profile.
func (f *faults) losing(now time.Time) bool {
	if f.loss <= 0 {
		return false
	}
	if f.burstMean <= 0 {
		return f.chance(f.loss)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	// The share of time spent bad is mean(bad)/(mean(good)+mean(bad)), so mean(good) is mean(bad)*(1-loss)/loss.
	goodMean := time.Duration(float64(f.burstMean) * (1 - f.loss) / f.loss)
	for {
		if f.inBad {
			if now.Before(f.burstUntil) {
				return true
			}
			f.inBad = false
			f.goodUntil = now.Add(f.expDurationLocked(goodMean))
			continue
		}
		if now.Before(f.goodUntil) {
			return false
		}
		f.inBad = true
		f.burstUntil = now.Add(f.expDurationLocked(f.burstMean))
	}
}

// expDurationLocked draws from an exponential distribution with the given mean. Caller holds mu.
func (f *faults) expDurationLocked(mean time.Duration) time.Duration {
	if mean <= 0 {
		return 0
	}
	return time.Duration(f.rng.ExpFloat64() * float64(mean))
}

func (f *faults) chance(p float64) bool {
	if p <= 0 {
		return false
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.rng.Float64() < p
}

// delayFor is the latency this packet should experience, jitter included.
func (f *faults) delayFor() time.Duration {
	d := f.latency
	if f.jitter > 0 {
		f.mu.Lock()
		d += time.Duration(f.rng.Int63n(int64(2*f.jitter))) - f.jitter
		f.mu.Unlock()
	}
	if d < 0 {
		d = 0
	}
	return d
}

// partitioned reports whether the link is blacked out, by wall clock rather than a draw so the windows line up
// against a log.
func (f *faults) partitioned() bool {
	if f.partitionEvery <= 0 || f.partitionFor <= 0 {
		return false
	}
	return time.Since(f.start)%f.partitionEvery < f.partitionFor
}

func (f *faults) applies(d direction) bool { return f.directions[d] }

type stats struct {
	forwarded  atomic.Uint64
	dropped    atomic.Uint64
	duplicated atomic.Uint64
	reordered  atomic.Uint64
	partitions atomic.Uint64
}

func (s *stats) line(kind string) string {
	return fmt.Sprintf("netsim %s: forwarded=%d dropped=%d duplicated=%d reordered=%d partition-drops=%d",
		kind, s.forwarded.Load(), s.dropped.Load(), s.duplicated.Load(),
		s.reordered.Load(), s.partitions.Load())
}

func main() {
	listenHost := flag.String("listen", "127.0.0.2",
		"local address to bind the mirrored ports on. Must differ from -target's host, and the "+
			"port NUMBERS are mirrored exactly -- see this file's doc comment for why that matters "+
			"for the udp/quic upgrade")
	targetHost := flag.String("target", "127.0.0.1", "host the real relay is listening on")
	tcpPorts := flag.String("tcp", "7777", "comma-separated tcp ports to mirror, or empty for none")
	udpPorts := flag.String("udp", "7777,7780",
		"comma-separated udp ports to mirror, or empty for none. 7777 is the relay's udp transport "+
			"and 7780 its quic transport (both are udp on the wire)")

	loss := flag.Float64("loss", 0, "probability 0..1 that a udp datagram is dropped (udp only)")
	dup := flag.Float64("duplicate", 0, "probability 0..1 that a udp datagram is delivered twice (udp only)")
	reorder := flag.Float64("reorder", 0,
		"probability 0..1 that a udp datagram is held back by -reorder-delay, so later ones overtake it (udp only)")
	reorderDelay := flag.Duration("reorder-delay", 60*time.Millisecond, "how long a reordered datagram is held")
	latency := flag.Duration("latency", 0, "one-way delay added to every packet")
	jitter := flag.Duration("jitter", 0, "random variation applied around -latency, plus or minus")
	dirs := flag.String("direction", "both", "which directions faults apply to: both, up (client->relay), or down")
	partitionEvery := flag.Duration("partition-every", 0, "if set, black out the link this often")
	partitionFor := flag.Duration("partition-for", 2*time.Second, "how long each -partition-every blackout lasts")
	burstMean := flag.Duration("loss-burst", 0,
		"OPT-IN correlated loss: when set, -loss stops being a coin flip per datagram and becomes "+
			"a two-state model -- the link is either GOOD (nothing lost) or BAD (everything lost), "+
			"and a bad period lasts about this long. Real bad wifi loses 150-500ms in a run, which "+
			"memoryless loss never produces: at 5% and 15Hz a 200ms triple-gap comes round about "+
			"every nine minutes and a 267ms quad about every three hours, so nothing in the default "+
			"profile exercises the regime an interpolation buffer is sized for (ADR 0046). -loss "+
			"still sets the long-run fraction of time spent in BAD, so the same -loss means the same "+
			"total datagrams lost, arriving in runs instead of singly")
	seed := flag.Int64("seed", 0, "PRNG seed; 0 picks one and logs it, so a bad run can be replayed")
	statsEvery := flag.Duration("stats-every", 10*time.Second, "how often to print counters; 0 disables")
	flag.Parse()

	if *listenHost == *targetHost {
		log.Fatalf("netsim: -listen and -target must be different hosts (got %q for both) -- "+
			"mirroring the same port on the same address would just collide with the relay", *listenHost)
	}
	for _, p := range []*float64{loss, dup, reorder} {
		if *p < 0 || *p > 1 {
			log.Fatalf("netsim: probabilities must be between 0 and 1, got %v", *p)
		}
	}

	// The udp-only faults are allowed beside mirrored tcp, since the handshake is always tcp and every real session
	// mirrors it; they are refused only when no udp port would receive them.
	udpOnly := *loss > 0 || *dup > 0 || *reorder > 0
	if *tcpPorts != "" && udpOnly && *udpPorts == "" {
		log.Fatalf("netsim: -loss/-duplicate/-reorder are udp-only, and no udp ports are mirrored, " +
			"so they would do nothing at all. Add -udp=7777,7780 or drop those flags")
	}

	if *seed == 0 {
		*seed = time.Now().UnixNano()
	}

	f := &faults{
		loss: *loss, dup: *dup, reorder: *reorder, reorderDelay: *reorderDelay,
		burstMean: *burstMean,
		latency:   *latency, jitter: *jitter,
		partitionEvery: *partitionEvery, partitionFor: *partitionFor,
		start:      time.Now(),
		directions: map[direction]bool{},
		rng:        rand.New(rand.NewSource(*seed)),
	}
	switch *dirs {
	case "both":
		f.directions[up], f.directions[down] = true, true
	case "up":
		f.directions[up] = true
	case "down":
		f.directions[down] = true
	default:
		log.Fatalf("netsim: -direction must be both, up, or down (got %q)", *dirs)
	}

	udpStats, tcpStats := &stats{}, &stats{}
	started := 0

	for _, p := range parsePorts(*udpPorts) {
		if err := serveUDP(*listenHost, *targetHost, p, f, udpStats); err != nil {
			log.Fatalf("netsim: udp %d: %v", p, err)
		}
		log.Printf("netsim: udp %s:%d -> %s:%d", *listenHost, p, *targetHost, p)
		started++
	}
	for _, p := range parsePorts(*tcpPorts) {
		if err := serveTCP(*listenHost, *targetHost, p, f, tcpStats); err != nil {
			log.Fatalf("netsim: tcp %d: %v", p, err)
		}
		log.Printf("netsim: tcp %s:%d -> %s:%d", *listenHost, p, *targetHost, p)
		started++
	}
	if started == 0 {
		log.Fatalf("netsim: nothing to do -- both -tcp and -udp are empty")
	}

	log.Printf("netsim: seed=%d loss=%.3f duplicate=%.3f reorder=%.3f latency=%s jitter=%s direction=%s",
		*seed, *loss, *dup, *reorder, *latency, *jitter, *dirs)
	if udpOnly && *tcpPorts != "" {
		log.Printf("netsim: NOTE -loss/-duplicate/-reorder reach the udp flows ONLY. The mirrored tcp " +
			"ports carry the handshake and get -latency/-jitter/-partition only, because dropping " +
			"bytes out of a proxied tcp stream corrupts it rather than simulating loss")
	}
	if *burstMean > 0 {
		// Logged unasked, so a pasted transcript shows its verdict was reached on a different network.
		goodMean := time.Duration(float64(*burstMean) * (1 - *loss) / *loss)
		log.Printf("netsim: CORRELATED loss on: the link alternates BAD for ~%s (everything lost) "+
			"and GOOD for ~%s (nothing lost), which keeps -loss=%.3f as the long-run share of "+
			"datagrams lost but delivers them in RUNS. This is a different network from the no-arg "+
			"profile every interp verdict on record was judged against -- say which one a result "+
			"came from", burstMean.Truncate(time.Millisecond), goodMean.Truncate(time.Millisecond), *loss)
	}
	if *partitionEvery > 0 {
		log.Printf("netsim: partition %s every %s", *partitionFor, *partitionEvery)
	}
	log.Printf("netsim: point your client at %s -- e.g. meshghost.exe -relay %s:7777", *listenHost, *listenHost)

	if *statsEvery > 0 {
		go func() {
			for range time.Tick(*statsEvery) {
				log.Print(udpStats.line("udp"))
				log.Print(tcpStats.line("tcp"))
			}
		}()
	}
	select {}
}

func parsePorts(spec string) []int {
	var out []int
	for _, s := range strings.Split(spec, ",") {
		s = strings.TrimSpace(s)
		if s == "" {
			continue
		}
		p, err := strconv.Atoi(s)
		if err != nil || p < 1 || p > 65535 {
			log.Fatalf("netsim: bad port %q", s)
		}
		out = append(out, p)
	}
	return out
}

// serveUDP mirrors one udp port. Each client address gets its own upstream socket, the way a NAT would, so the
// relay's reply can be routed back to the client it belongs to.
func serveUDP(listenHost, targetHost string, port int, f *faults, st *stats) error {
	front, err := net.ListenPacket("udp", net.JoinHostPort(listenHost, strconv.Itoa(port)))
	if err != nil {
		return err
	}
	target, err := net.ResolveUDPAddr("udp", net.JoinHostPort(targetHost, strconv.Itoa(port)))
	if err != nil {
		return err
	}

	go func() {
		type flow struct{ up net.PacketConn }
		flows := map[string]*flow{}
		var mu sync.Mutex
		buf := make([]byte, 64*1024)

		for {
			n, from, err := front.ReadFrom(buf)
			if err != nil {
				return
			}
			key := from.String()

			mu.Lock()
			fl, ok := flows[key]
			if !ok {
				upc, err := net.ListenPacket("udp", net.JoinHostPort(listenHost, "0"))
				if err != nil {
					mu.Unlock()
					continue
				}
				fl = &flow{up: upc}
				flows[key] = fl
				// Faults apply to replies too, so -direction=down can black out only the relay's side.
				go func(client net.Addr, upc net.PacketConn) {
					rbuf := make([]byte, 64*1024)
					for {
						rn, _, err := upc.ReadFrom(rbuf)
						if err != nil {
							return
						}
						pkt := append([]byte(nil), rbuf[:rn]...)
						sendUDP(f, st, down, pkt, func(b []byte) {
							_, _ = front.WriteTo(b, client)
						})
					}
				}(from, upc)
			}
			mu.Unlock()

			pkt := append([]byte(nil), buf[:n]...)
			sendUDP(f, st, up, pkt, func(b []byte) {
				_, _ = fl.up.WriteTo(b, target)
			})
		}
	}()
	return nil
}

// sendUDP applies the fault model to one datagram and hands whatever survives to write. A delayed datagram is sent
// from its own goroutine, which is what lets a later one overtake it.
func sendUDP(f *faults, st *stats, d direction, pkt []byte, write func([]byte)) {
	if !f.applies(d) {
		st.forwarded.Add(1)
		write(pkt)
		return
	}
	if f.partitioned() {
		st.partitions.Add(1)
		return
	}
	if f.losing(time.Now()) {
		st.dropped.Add(1)
		return
	}

	delay := f.delayFor()
	if f.chance(f.reorder) {
		delay += f.reorderDelay
		st.reordered.Add(1)
	}
	copies := 1
	if f.chance(f.dup) {
		copies = 2
		st.duplicated.Add(1)
	}

	emit := func() {
		for i := 0; i < copies; i++ {
			st.forwarded.Add(1)
			write(pkt)
		}
	}
	if delay <= 0 {
		emit()
		return
	}
	go func() {
		time.Sleep(delay)
		emit()
	}()
}

func serveTCP(listenHost, targetHost string, port int, f *faults, st *stats) error {
	ln, err := net.Listen("tcp", net.JoinHostPort(listenHost, strconv.Itoa(port)))
	if err != nil {
		return err
	}
	targetAddr := net.JoinHostPort(targetHost, strconv.Itoa(port))

	go func() {
		for {
			client, err := ln.Accept()
			if err != nil {
				return
			}
			go func() {
				defer client.Close()
				relay, err := net.Dial("tcp", targetAddr)
				if err != nil {
					log.Printf("netsim: tcp dial %s: %v", targetAddr, err)
					return
				}
				defer relay.Close()
				done := make(chan struct{}, 2)
				go func() { pumpTCP(f, st, up, client, relay); done <- struct{}{} }()
				go func() { pumpTCP(f, st, down, relay, client); done <- struct{}{} }()
				<-done
			}()
		}
	}()
	return nil
}

// tcpChunk is one read from the source and the instant it is due at the destination.
type tcpChunk struct {
	data []byte
	due  time.Time
}

// pumpTCP copies one direction of a tcp flow, applying the delay model. The reader does not sleep between read and
// write: each chunk is stamped with its due time and a second goroutine writes the chunks in order at those times.
// Sleeping inline would turn the latency into the stream's service interval and deliver it in clumps.
func pumpTCP(f *faults, st *stats, d direction, src, dst net.Conn) {
	// Bounded: a destination that stops reading ends up blocking the reader, as a congested link would.
	queue := make(chan tcpChunk, 1024)
	done := make(chan struct{})

	go func() {
		defer close(done)
		for chunk := range queue {
			if wait := time.Until(chunk.due); wait > 0 {
				time.Sleep(wait)
			}
			st.forwarded.Add(1)
			if _, werr := dst.Write(chunk.data); werr != nil {
				return
			}
		}
	}()

	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			// Copied: buf is reused by the next read.
			chunk := tcpChunk{data: append([]byte(nil), buf[:n]...), due: time.Now()}
			if f.applies(d) {
				// A partition stalls the stream rather than dropping it: tcp retransmits, so the bytes are late.
				for f.partitioned() {
					st.partitions.Add(1)
					chunk.due = chunk.due.Add(50 * time.Millisecond)
					time.Sleep(5 * time.Millisecond)
				}
				chunk.due = chunk.due.Add(f.delayFor())
			}
			select {
			case queue <- chunk:
			case <-done:
				return
			}
		}
		if err != nil {
			// EOF is how a session ends; anything else is logged, since a rig dropping connections looks like the stack
			// dropping them.
			if err != io.EOF {
				log.Printf("netsim: tcp %s flow ended: %v", d, err)
			}
			close(queue)
			<-done
			return
		}
	}
}
