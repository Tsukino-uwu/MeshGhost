package relay

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// The 2026-09-01 oversized-Welcome incident, reached through the third door
// (2026-09-12).
//
// The first two were both about the RECEIVER: a Welcome that grew past the line
// limit a joining core's scanner is configured with, killing that connection
// with "token too long". It was fixed by a member count (2026-09-01), then
// refixed by measuring the serialized line against protocol.MaxPayloadBytes
// after the count turned out to be sized on an arithmetic that ignored JSON
// escaping (2026-09-08; relayfix_test.go).
//
// Both fixes measured against the right number for the wrong machine.
// protocol.MaxPayloadBytes is 4095 because that is what a RECEIVER accepts. A
// udp reliable payload carries 1181 because that is what the WIRE takes -- and
// udp is the shipped default transport. A Welcome between those two numbers is
// built, handed to Send, and refused by the transport before a byte leaves the
// process: the joining player simply never receives a Welcome, sits through the
// handshake timeout, and reconnects into the same wall. Every other member of
// that room is unaffected and sees nothing, which is what makes it hard to
// report: the one person who cannot get in is the one who did nothing.
//
// Measured 2026-09-12: with ordinary 24-rune names the crossing is at 16
// members; with names that escape -- '&', '<' and '>' all survive sanitizing and
// all cost six bytes each in JSON -- it is at SIX, which is inside
// DefaultMaxClients (8). No operator has to configure anything for this to
// happen, which is why this fixture uses escaped names.
//
// Found by the transports cell of the third adversarial review, as the other
// half of P1d-3.

// TestSendBudgetReportsTheWireLimitNotTheProtocolLimit pins the plumbing the
// test above depends on, across all three transports at once.
//
// It is a separate assertion because the two can fail independently: a Welcome
// can fit by luck while sendBudget reports the wrong number, and a future
// transport can be added with no budget of its own and be silently sized to
// 4095. The layering is deliberate and easy to get wrong -- udpconn reports
// what one Write carries, transport subtracts the newline it adds itself, and
// this package takes the smaller of that and the protocol's own bound.
func TestSendBudgetReportsTheWireLimitNotTheProtocolLimit(t *testing.T) {
	// udpconn's own framing, spelled out rather than imported: this package
	// does not depend on any transport package, which is the whole point of
	// asking structurally. 1200 - 2 control - 8 token - 8 seq - 1 newline.
	const wantUDP = 1200 - 2 - 8 - 8 - 1

	want := map[netx.Kind]int{
		netx.TCP:  protocol.MaxPayloadBytes,
		netx.UDP:  wantUDP,
		netx.QUIC: protocol.MaxPayloadBytes,
	}
	type row struct {
		kind netx.Kind
		want int
	}
	var rows []row
	for _, k := range transportKindsUnderTest {
		rows = append(rows, row{k, want[k]})
	}
	for _, tc := range rows {
		t.Run(tc.kind.String(), func(t *testing.T) {
			addr := startServerOn(t, NewServer(), tc.kind)
			c := dialTestClientOn(t, tc.kind, addr, "emerald", "room1", "alice")
			defer c.conn.Close()
			c.expectWelcome(timeout)

			if got := sendBudget(c.conn); got != tc.want {
				t.Fatalf("sendBudget on %s = %d, want %d", tc.kind, got, tc.want)
			}
		})
	}

	// A Transport that says nothing about itself must read as "no transport
	// limit", never as zero -- a zero budget would trim every Welcome to
	// nothing. net.Pipe-backed conns and every test fake in this package are
	// this case.
	if got := sendBudget(&transport.NDJSONConn{}); got != protocol.MaxPayloadBytes {
		t.Fatalf("sendBudget of a conn with no wire limit = %d, want %d", got, protocol.MaxPayloadBytes)
	}
	if got := sendBudget(nopTransport{}); got != protocol.MaxPayloadBytes {
		t.Fatalf("sendBudget of a Transport that is not an NDJSONConn = %d, want %d",
			got, protocol.MaxPayloadBytes)
	}
}

// nopTransport is a Transport that implements nothing beyond the interface, so
// the structural question above has something to answer "no" for.
type nopTransport struct{}

func (nopTransport) Send([]byte) error           { return nil }
func (nopTransport) SendUnreliable([]byte) error { return nil }
func (nopTransport) OnReceive(func([]byte))      {}
func (nopTransport) OnDisconnect(func(error))    {}
func (nopTransport) OnError(func(error))         {}
func (nopTransport) Close() error                { return nil }
