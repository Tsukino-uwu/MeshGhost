package core

// Choosing which transport this core actually talks to the relay over.
//
// Split out of core.go on 2026-08-25. The handshake is ALWAYS tcp and nothing here
// changes that -- these functions decide only what the session MOVES to once
// connected, by asking the relay what it serves (a query-only hello) and picking
// from the answer. Any failure falls back to tcp at the configured address, so
// discovery can only improve a connection, never prevent one.

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// resolveTransport decides what this Core actually dials.
//
// **The handshake is always tcp, and no config setting can change that.**
// Core.Transport is not "how to connect" but "what to move to once
// connected": tcp means stay put, and udp or quic mean upgrade if the relay
// offers them. That inversion buys three things at once — a client never
// needs to be told which port a transport lives on (quic's differs, and
// guessing is impossible), the one leg that must work is always the
// transport that works everywhere and is readable while debugging, and a
// misconfigured preference degrades to a working tcp session instead of a
// timeout.
//
// A tcp preference short-circuits: there is nothing to upgrade to, so the
// single connection made is already the tcp one, and asking would cost a
// round trip to learn nothing.
//
// The returned error is non-nil only when the relay could not be reached
// over tcp at all — which is exactly the error the caller would have
// produced itself, so it is passed up rather than papered over. Every other
// failure (old relay, refused room code, malformed answer) returns tcp at
// the configured address, letting the real connect attempt surface the real
// problem.
func (c *Core) resolveTransport(addr, gameID, room, displayName, roomCode, gameVersion string) (netx.Kind, string, netx.TLSOptions, error) {
	opts := c.tlsOptions()
	if c.Transport == netx.TCP {
		return netx.TCP, addr, opts, nil
	}

	offers, secure, err := c.queryTransports(addr, gameID, room, displayName, roomCode, gameVersion)
	if err != nil {
		return netx.TCP, addr, opts, err
	}
	// No downgrade after a successful TLS leg. The discovery connection
	// just proved this relay speaks TLS, so a plaintext session connection
	// to the same relay could only be someone interfering — which is
	// precisely the fallback tlsx.Auto otherwise allows for the benefit of
	// relays built before this feature existed. Once TLS is known to work,
	// that allowance has no reason to apply and is withdrawn.
	kind, dialAddr := c.chooseTransport(addr, offers)
	if secure && opts.Mode == tlsx.Auto {
		if kind == netx.UDP {
			// EXCEPT ON A TRANSPORT THAT CANNOT CARRY TLS AT ALL. udp has no DTLS in Go, so
			// escalating here would not secure the session -- it would refuse to make one, and
			// silently kill a supported transport for anybody whose relay speaks TLS. Found by
			// internal/e2e's transport matrix the moment `auto` became the default (2026-08-19):
			// every udp round trip stopped, because discovery succeeded over TLS every time.
			//
			// Saying so is the whole obligation here. `auto` means "encrypt where that is
			// possible, and never quietly do less than you could" -- on udp it is not possible,
			// and the log has to be the thing that says it rather than the connection just
			// working and looking encrypted.
			log.Printf("core: this relay speaks TLS, but -transport udp cannot be encrypted " +
				"(Go has no DTLS) -- this session is PLAINTEXT. Use quic for the same loss " +
				"behaviour with encryption, or tcp.")
		} else {
			opts.Mode = tlsx.Required
		}
	}
	return kind, dialAddr, opts, nil
}

// tlsOptions is this Core's TLS configuration as netx wants it. Kept in one
// place so the discovery leg and the session leg can never disagree about
// what was asked for.
func (c *Core) tlsOptions() netx.TLSOptions {
	mode := c.TLS
	// A PIN IMPLIES REQUIRED. Under tlsx.Auto a failed pin and "this relay is
	// too old to speak TLS" are the same event -- tlsx.Client returns an error
	// either way -- and Auto's whole job is to fall back to plaintext on that
	// error. So setting a fingerprint under Auto turned MITM DETECTION INTO AN
	// AUTOMATIC DOWNGRADE: an attacker who refuses the handshake, or presents
	// any certificate at all, gets a plaintext session, and the room code
	// crosses the discovery leg in the clear. docs/security.md's "a relay
	// presenting anything else is then refused rather than trusted" was false
	// for exactly the configuration that bothered to set a pin.
	//
	// Escalating here rather than at the flag covers embedders too, and keeps
	// the discovery leg and the session leg agreeing -- which is what this
	// function exists for. cmd/meshghost refuses a pin with -transport udp up
	// front so the user gets that error at startup instead of a dial failure.
	// Found by the 2026-09-07 review; the user's call to force it (D2).
	if mode == tlsx.Auto && c.TLSFingerprint != "" {
		mode = tlsx.Required
	}
	return netx.TLSOptions{Mode: mode, Fingerprint: c.TLSFingerprint}
}

// queryTransports performs the tcp handshake leg: connect, ask what the
// relay serves, hang up without joining.
//
// Not joining is the whole point. Joining first and upgrading afterwards
// would make every other player in the room watch this one leave and
// rejoin, because the relay assigns a fresh player_id per connection and a
// discovery query is never issued a resume token, so there is nothing for
// the upgraded connection to reclaim.
//
// An error is returned only for an unreachable relay. Anything else yields
// a nil list, meaning "nothing to upgrade to".
func (c *Core) queryTransports(addr, gameID, room, displayName, roomCode, gameVersion string) ([]protocol.TransportOffer, bool, error) {
	netConn, err := netx.DialWithTLS(netx.TCP, addr, discoverTransportTimeout, c.tlsOptions())
	if err != nil {
		return nil, false, err
	}
	// Whether THIS leg ended up encrypted, which is what the caller uses to
	// refuse a downgrade on the session leg. The room code rides this
	// connection, so it is also the answer to "was the room code protected".
	secure := tlsx.IsTLS(netConn)
	conn := transport.FromConnWithLimits(netConn, protocol.MaxLineBytes, 0, 0)
	defer conn.Close()

	replies := make(chan protocol.Envelope, 1)
	conn.OnReceive(func(payload []byte) {
		var env protocol.Envelope
		if err := json.Unmarshal(payload, &env); err != nil {
			return
		}
		select {
		case replies <- env:
		default:
		}
	})

	hello, err := json.Marshal(protocol.Hello{
		ProtocolVersion: protocol.Version,
		GameID:          gameID,
		Room:            room,
		DisplayName:     displayName,
		RoomCode:        roomCode,
		GameVersion:     gameVersion,
		QueryOnly:       true,
	})
	if err != nil {
		return nil, secure, nil
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err != nil {
		return nil, secure, nil
	}
	if err := conn.Send(env); err != nil {
		return nil, secure, nil
	}

	select {
	case reply := <-replies:
		switch reply.Type {
		case protocol.TypeTransports:
			var t protocol.Transports
			if err := json.Unmarshal(reply.Payload, &t); err != nil {
				return nil, secure, nil
			}
			return t.Offers, secure, nil
		case protocol.TypeWelcome:
			// An older relay: it does not know query_only, so it treated
			// this as a real hello and joined us. Nothing to upgrade to, so
			// use tcp. The connection is closed on return, which such a
			// relay reports to the room as a leave — one spurious
			// join/leave against pre-2026-08-16 relays only, and the price
			// of the field being additive rather than a version bump.
			log.Printf("core: relay at %s does not support transport discovery (older build) — using tcp", addr)
			return nil, secure, nil
		default:
			// A reject (wrong room code, wrong version, ...). Let the real
			// connect attempt surface it, with its reason, rather than
			// duplicating that logic here.
			return nil, secure, nil
		}
	case <-time.After(discoverTransportTimeout): // wall-clock: waiting on a real dial
		return nil, secure, nil
	}
}

// udpPossible answers "can this machine create a udp socket at all", through
// udpProbe so a test can say no without needing a machine that actually
// cannot. Production leaves udpProbe nil and gets netx.UDPUsable.
func (c *Core) udpPossible() bool {
	if c.udpProbe != nil {
		return c.udpProbe()
	}
	return netx.UDPUsable()
}

// logUDPImpossibleOnce explains the downgrade the first time it is applied.
// Once per process: chooseTransport runs on every connect attempt, and the
// answer cannot change while the process lives.
func (c *Core) logUDPImpossibleOnce() {
	c.udpImpossibleLogged.Do(func() {
		reason := "unknown"
		if c.udpProbe == nil {
			reason = netx.UDPUnusableReason()
		}
		log.Printf("core: this machine cannot open a udp socket (%s), so quic and plain udp "+
			"are both impossible here and neither will be tried -- using tcp, which is what "+
			"the handshake already proved works. Under Wine/Proton this is expected and is "+
			"not a fault of the relay or your network; a client running natively on Linux "+
			"is not affected and still gets quic.", reason)
	})
}

// chooseTransport picks the best offered transport and rebuilds the address
// to dial.
//
// Only the port comes from the relay; the host is always the one the user
// configured. That is what lets discovery work through NAT and port
// forwarding — a relay bound to 0.0.0.0 has no idea which address reaches
// it, but the client just connected to one, so it already knows.
func (c *Core) chooseTransport(addr string, offers []protocol.TransportOffer) (netx.Kind, string) {
	if len(offers) == 0 {
		return netx.TCP, addr
	}
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		return netx.TCP, addr
	}

	byKind := map[string]protocol.TransportOffer{}
	for _, o := range offers {
		if o.Port > 0 && o.Port < 65536 {
			byKind[o.Kind] = o
		}
	}

	// An explicit preference is honoured exactly, and only that one is
	// considered — a client asking for quic must not silently land on udp,
	// which would swap an encrypted session for one that cannot be
	// encrypted at all. netx.Auto is the only value that ranks.
	wants := []netx.Kind{c.Transport}
	if c.Transport == netx.Auto {
		wants = netx.AutoPreference
	}

	// A transport that already failed to DIAL on this machine is skipped in automatic mode.
	// See Core.unusableTransports: without this, a platform that cannot do quic at all --
	// Wine being the case that found it -- re-picks quic on every retry and never connects,
	// while tcp was sitting there the whole time.
	c.mu.Lock()
	unusable := make(map[string]bool, len(c.unusableTransports))
	for k := range c.unusableTransports {
		unusable[k] = true
	}
	c.mu.Unlock()

	// A machine that cannot open a udp socket has neither quic nor plain udp, and
	// dialling them to find that out is pure cost: quic.DialAddr and udpconn both
	// begin with net.ListenUDP, so the failure is local and identical every time.
	// Skipping them here is what stops a Proton client paying two doomed dials and
	// several seconds of connect delay on EVERY launch -- Core.unusableTransports
	// is per-process, and the core exits with the game, so it otherwise relearns
	// the same impossibility from scratch each time.
	//
	// AUTOMATIC MODE ONLY, like every other entry in unusable: somebody who wrote
	// transport "quic" still gets told, repeatedly and clearly, that it is failing
	// rather than being moved without being asked.
	//
	// netx.UDPUsable probes rather than detecting Wine, and that is deliberate --
	// it makes this right for a native Linux client sharing the same config.json
	// (its socket opens, so it keeps quic) and for a future Wine that implements
	// the ioctls. See its doc comment.
	// Only when the relay actually offers one of them. A relay serving tcp alone
	// leaves nothing to downgrade FROM, and announcing a downgrade there would be a
	// false alarm in the log of a player whose setup is entirely fine.
	offersUDPBased := false
	for _, k := range []netx.Kind{netx.QUIC, netx.UDP} {
		if _, ok := byKind[k.String()]; ok {
			offersUDPBased = true
		}
	}
	if c.Transport == netx.Auto && offersUDPBased && !c.udpPossible() {
		c.logUDPImpossibleOnce()
		unusable[netx.QUIC.String()] = true
		unusable[netx.UDP.String()] = true
	}

	for _, want := range wants {
		if want == netx.TCP {
			// SAY SO. This return used to be silent, and the log below ran only
			// for a non-tcp choice, so a session that ended up on tcp -- whether
			// because tcp was asked for or because everything above it was
			// condemned -- never once named the transport it was actually using.
			// A Proton tester's log showed sixteen "using quic" lines and no
			// record of the tcp the session actually ran on; the only trace was
			// the "read tcp ..." in a later DISCONNECT message, which means the
			// transport could be learned only from a failure.
			log.Printf("core: relay offers %s — using tcp at %s", offerList(offers), addr)
			return netx.TCP, addr
		}
		if c.Transport == netx.Auto && unusable[want.String()] {
			continue
		}
		o, ok := byKind[want.String()]
		if !ok {
			continue
		}
		chosen := net.JoinHostPort(host, strconv.Itoa(o.Port))
		log.Printf("core: relay offers %s — using %s at %s", offerList(offers), want, chosen)
		return want, chosen
	}

	// Asked for something this relay does not serve. Staying on tcp is
	// right — the session works, which a timeout would not — but say so,
	// because otherwise a user who deliberately chose quic for encryption
	// would silently get an unencrypted session with nothing to indicate it.
	log.Printf("core: this relay does not offer %s (it offers %s) — staying on tcp",
		c.Transport, offerList(offers))
	return netx.TCP, addr
}

func offerList(offers []protocol.TransportOffer) string {
	parts := make([]string, 0, len(offers))
	for _, o := range offers {
		parts = append(parts, fmt.Sprintf("%s:%d", o.Kind, o.Port))
	}
	return strings.Join(parts, ", ")
}
