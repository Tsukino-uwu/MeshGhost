// Command meshghost-netsim is a fault-injecting proxy that sits between
// clients and a relay, so a real session can be run against a network worth
// being afraid of: loss, latency, jitter, reordering, duplication, and
// partitions.
//
// Why this exists. Every automated check in this repo runs over a perfect
// loopback. agent_docs/testing.md names the consequence directly -- "real
// latency and jitter -- loopback has ~none", and interpolation degrades
// *silently* under wall-clock skew -- and dev-scripts/README.md says the
// same of the launchers. The only fault injection that existed before this
// was a package-private drop counter inside netx/udpconn's own
// tests, which cannot touch a running session. That injector found a real
// ordering bug on 2026-08-16 (a leave overtaking its own join, stranding a
// ghost permanently); this is the same idea at session scope.
//
// How to point a client at it. The proxy mirrors the relay's port NUMBERS
// on a different loopback address, and that is load-bearing rather than a
// convenience: agent_docs/contract.md's transport discovery sends the port
// but deliberately not the host, so a client that upgrades to udp or quic
// reuses whatever host it first connected to. Mirroring 127.0.0.1:7777 as
// 127.0.0.2:7777 therefore keeps the whole handshake-then-upgrade path
// inside the proxy. Giving it a different port number would silently route
// the upgrade around it, and the session would look fine while testing
// nothing.
//
// What it deliberately does NOT do: drop or reorder bytes on tcp. A tcp
// connection proxied at the application layer is a byte stream, so
// "dropping" part of it corrupts the stream rather than simulating loss --
// the kernel's own retransmission is what a real drop would hit, and that
// is below where this sits. On tcp the honest faults are delay, jitter and
// partition (a stall), which is what is offered; loss, reorder and
// duplicate apply to udp/quic only. Asking for them on tcp is refused
// rather than quietly ignored.
//
// Nothing here knows anything about MeshGhost's protocol -- it moves bytes.
// That is on purpose: it stays useful if the wire format changes.
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

// faults is the shared, seeded fault model. One instance is shared by every
// flow so a single -seed describes the whole run.
//
// Seeded rather than freely random for the same reason netx/udpconn's
// own proxy arms loss explicitly: a failure nobody can reproduce is barely a
// failure report. The seed is logged at startup and can be fed back in. Note
// the honest limit -- with several concurrent flows the *interleaving* is
// still down to the scheduler, so a seed reproduces the fault distribution,
// not a bit-identical run.
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

	// burstMean is the average length of a BAD period when correlated loss is
	// on, and zero when it is off (the memoryless default). inBad and
	// burstUntil are the current state; both are guarded by mu.
	burstMean  time.Duration
	inBad      bool
	burstUntil time.Time
	goodUntil  time.Time

	mu  sync.Mutex
	rng *rand.Rand
}

// losing reports whether this datagram is lost, and is the whole difference
// between the default fault model and the opt-in one.
//
// MEMORYLESS (-loss-burst unset): an independent coin flip per datagram, which
// is what this tool has always done. It is right for background loss and wrong
// for the thing that actually breaks an interpolation buffer -- a run of
// consecutive samples missing -- because independent flips almost never produce
// one. That is the gap the 2026-09-07 review measured (D5): nothing in the
// no-arg profile reaches the 150-500ms correlated-gap regime ADR 0046's ladder
// was judged against, so the shipped 450ms rests on a milder network than its
// own description claims, and the error direction is that 450 may be UNDER-sized.
//
// CORRELATED (-loss-burst set): a two-state Gilbert model. The link is GOOD and
// loses nothing, or BAD and loses everything, and each period's length is drawn
// from an exponential with the given mean -- so losses arrive in runs, the way
// a wifi link with a competing transmitter or a moving obstacle actually fails.
// -loss keeps its meaning as the long-run FRACTION of time spent BAD, so the
// same -loss loses the same share of datagrams either way: what changes is the
// arrangement, which is the only thing an interpolation buffer cares about.
//
// Opt-in, and deliberately not the default: every interp verdict on record was
// made against the memoryless profile, and silently changing what the no-arg
// rig means would invalidate those comparisons without anyone noticing. The
// user's call, 2026-09-11.
func (f *faults) losing(now time.Time) bool {
	if f.loss <= 0 {
		return false
	}
	if f.burstMean <= 0 {
		return f.chance(f.loss)
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	// Mean GOOD length follows from the two knobs: the fraction of time spent
	// BAD is mean(bad) / (mean(good) + mean(bad)), so mean(good) is
	// mean(bad) * (1-loss)/loss. At the no-arg 5% that is nineteen times as
	// long good as bad.
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

// expDurationLocked draws from an exponential distribution with the given mean,
// which is what makes the state lengths memoryless WITHIN a state while the
// state itself carries the correlation. Caller holds mu.
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
		// Symmetric around the base latency, clamped at zero -- a negative
		// total delay is not a thing a network does.
		d += time.Duration(f.rng.Int63n(int64(2*f.jitter))) - f.jitter
		f.mu.Unlock()
	}
	if d < 0 {
		d = 0
	}
	return d
}

// partitioned reports whether the link is currently blacked out. Driven by
// wall-clock rather than a random draw so the windows are predictable enough
// to line up against a log.
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

	// Said loudly rather than refused. An earlier version made this fatal, on
	// the reasoning that silently discarding a -loss the caller asked for
	// would let a clean run be reported as evidence the stack survives loss.
	// Running it proved that wrong: the handshake is ALWAYS tcp
	// (agent_docs/contract.md), so every real session needs tcp mirrored, and
	// refusing made -loss unusable in exactly the case it exists for. The
	// honest fix is to allow the combination, apply these faults only where
	// they mean something, and print which flows they reached.
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
		// Said at startup, because the whole point of the flag is that a
		// verdict reached under it is not comparable with one reached without
		// it -- and a log nobody has to ask for is what makes that visible in
		// a pasted transcript.
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

// ------------------------------------------------------------------- udp

// serveUDP mirrors one udp port. Each distinct client address gets its own
// upstream socket, the way a NAT would: the relay's reply then arrives on
// that socket and can be routed back to exactly the client it belongs to.
// One shared upstream socket could not tell two clients' replies apart.
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
				// Pump this client's replies back. Faults apply here too, so
				// -direction=down can black out only the relay's side.
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

// sendUDP applies the fault model to one datagram and hands whatever
// survives to write. Delays run in their own goroutine, which is exactly
// what lets a delayed datagram be overtaken -- reordering on udp is a
// consequence of delay, not a separate mechanism.
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

// ------------------------------------------------------------------- tcp

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

// pumpTCP copies src to dst, delaying in place.
//
// Delay is applied inline, in this one goroutine per direction, which keeps
// the stream ORDERED -- a later chunk cannot overtake an earlier one. That
// is the correct model: tcp reordering is invisible above the kernel, so a
// proxy that reordered here would be simulating something that cannot
// happen rather than something that can.
//
// A partition stalls the stream rather than discarding it, for the same
// reason: a real partition makes tcp retransmit until it gives up, so the
// bytes are late, not gone.
func pumpTCP(f *faults, st *stats, d direction, src, dst net.Conn) {
	buf := make([]byte, 32*1024)
	for {
		n, err := src.Read(buf)
		if n > 0 {
			if f.applies(d) {
				for f.partitioned() {
					st.partitions.Add(1)
					time.Sleep(50 * time.Millisecond)
				}
				if delay := f.delayFor(); delay > 0 {
					time.Sleep(delay)
				}
			}
			st.forwarded.Add(1)
			if _, werr := dst.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			// A closed peer is the ordinary way a session ends, so EOF is
			// not worth a line. Anything else is, because a rig that is
			// quietly dropping connections looks identical to a stack that
			// is quietly dropping them.
			if err != io.EOF {
				log.Printf("netsim: tcp %s flow ended: %v", d, err)
			}
			return
		}
	}
}
