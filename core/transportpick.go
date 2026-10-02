package core

// Choosing which transport this core talks to the relay over. The handshake is always tcp; these functions decide only
// what the session moves to once connected, by asking the relay what it serves (a query-only hello). Any failure falls
// back to tcp at the configured address, so discovery can only improve a connection, never prevent one.

import (
	"encoding/json"
	"fmt"
	"log"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// resolveTransport decides what this Core dials. Core.Transport is not how to connect but what to move to once
// connected: a client never needs to know which port a transport lives on, the leg that must work is the one that works
// everywhere, and a misconfigured preference degrades to a working tcp session instead of a timeout. A tcp preference
// short-circuits, having nothing to upgrade to.
//
// The error is non-nil only when the relay is unreachable over tcp; every other failure (old relay, refused room code,
// malformed answer) returns tcp at the configured address and lets the real connect attempt surface the problem.
func (c *Core) resolveTransport(addr, gameID, room, displayName, roomCode, gameVersion string) (netx.Kind, string, netx.TLSOptions, error) {
	opts := c.tlsOptions(addr)
	if c.Transport == netx.TCP {
		return netx.TCP, addr, opts, nil
	}

	offers, err := c.queryTransports(addr, gameID, room, displayName, roomCode, gameVersion, opts)
	if err != nil {
		return netx.TCP, addr, opts, err
	}
	kind, dialAddr := c.chooseTransport(addr, offers)
	if kind == netx.UDP {
		// udp has no DTLS in Go, so a session there is plaintext; it exists only in the meshghost_devudp build.
		log.Printf("core: -transport udp cannot be encrypted (Go has no DTLS) -- this session " +
			"is PLAINTEXT. Use quic for the same loss behaviour with encryption, or tcp.")
	}
	return kind, dialAddr, opts, nil
}

// tlsOptions is this Core's TLS configuration for every leg to the relay configured as addr, so the discovery and
// session legs verify against the same known-relays entry, keyed by the configured address whatever port is dialled.
func (c *Core) tlsOptions(addr string) netx.TLSOptions {
	return netx.TLSOptions{Verify: c.knownRelays().Verifier(addr)}
}

// knownRelays is Core.KnownRelays, or the in-memory store a Core without one gets on first use. Under c.mu so two legs
// racing to the first connect share one store.
func (c *Core) knownRelays() *KnownRelays {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.KnownRelays == nil {
		c.KnownRelays = NewKnownRelays("")
	}
	return c.KnownRelays
}

// queryTransports performs the tcp handshake leg: connect, ask what the relay serves, hang up without joining. Joining
// and then upgrading would show the room this player leave and rejoin: the relay assigns a fresh player_id per
// connection, and a query gets no resume token. An error means an unreachable relay; anything else yields a nil list.
func (c *Core) queryTransports(addr, gameID, room, displayName, roomCode, gameVersion string, opts netx.TLSOptions) ([]protocol.TransportOffer, error) {
	netConn, err := netx.DialWithTLS(netx.TCP, addr, discoverTransportTimeout, opts)
	if err != nil {
		return nil, err
	}
	// The discovery leg proves the room code too: a relay with a code answers the query only after KE3.
	proof, err := newRoomProof(roomCode, netConn)
	if err != nil {
		_ = netConn.Close()
		return nil, nil
	}
	conn := transport.FromConnWithLimits(netConn, protocol.MaxLineBytes, 0, 0)
	defer conn.Close()

	replies := make(chan protocol.Envelope, 1)
	conn.OnReceive(func(payload []byte) {
		// A refused proof closes this leg; the real connect attempt then surfaces the reason.
		if proof.intercept(conn, payload, func(protocol.Reject) {}) {
			return
		}
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
		PakeKE1:         proof.KE1(),
		GameVersion:     gameVersion,
		QueryOnly:       true,
	})
	if err != nil {
		return nil, nil
	}
	env, err := json.Marshal(protocol.Envelope{Type: protocol.TypeHello, Payload: hello})
	if err != nil {
		return nil, nil
	}
	if err := conn.Send(env); err != nil {
		return nil, nil
	}

	select {
	case reply := <-replies:
		switch reply.Type {
		case protocol.TypeTransports:
			var t protocol.Transports
			if err := json.Unmarshal(reply.Payload, &t); err != nil {
				return nil, nil
			}
			return t.Offers, nil
		case protocol.TypeWelcome:
			// An older relay that does not know query_only joined us; nothing to upgrade to, so tcp. Closing makes it
			// report one spurious leave, the price of the field being additive rather than a version bump.
			log.Printf("core: relay at %s does not support transport discovery (older build) — using tcp", addr)
			return nil, nil
		default:
			// A reject: the real connect attempt surfaces it with its reason.
			return nil, nil
		}
	case <-time.After(discoverTransportTimeout): // wall-clock: waiting on a real dial
		return nil, nil
	}
}

// udpPossible answers whether this machine can create a udp socket at all, through udpProbe so a test can say no.
func (c *Core) udpPossible() bool {
	if c.udpProbe != nil {
		return c.udpProbe()
	}
	return netx.UDPUsable()
}

// logUDPImpossibleOnce explains the downgrade once per process: the answer cannot change while the process lives.
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

// chooseTransport picks the best offered transport and rebuilds the address to dial. Only the port comes from the
// relay; the host is the one configured, which is what lets discovery work through NAT and port forwarding.
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

	// An explicit preference is honoured exactly: a client asking for quic must not land on udp, which cannot be
	// encrypted. Only netx.Auto ranks.
	wants := []netx.Kind{c.Transport}
	if c.Transport == netx.Auto {
		wants = netx.AutoPreference
	}

	// A transport that already failed to dial on this machine is skipped in automatic mode, or a platform that cannot
	// do quic re-picks it on every retry and never connects.
	c.mu.Lock()
	unusable := make(map[string]bool, len(c.unusableTransports))
	for k := range c.unusableTransports {
		unusable[k] = true
	}
	c.mu.Unlock()

	// A machine that cannot open a udp socket has neither quic nor udp, and both dials fail locally in net.ListenUDP,
	// so in automatic mode they are skipped rather than relearned on every launch; an explicit transport is never
	// moved. It probes the capability rather than detecting the platform, which keeps quic for a native client sharing
	// the same config.json. Only when the relay offers one of them, or the log would announce a downgrade from nothing.
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
			// Named in the log like any other choice, or a session on tcp never says which transport it runs on.
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

	// Asked for something this relay does not serve: tcp keeps the session working, which a timeout would not, and the
	// log tells the player why they did not get what they chose.
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
