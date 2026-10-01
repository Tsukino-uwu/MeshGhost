package relay

import (
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/netx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// TestSendBudgetReportsTheWireLimitNotTheProtocolLimit: protocol.MaxPayloadBytes is what a receiver accepts, but a
// udp payload carries what one datagram takes, and a Welcome Send refuses never leaves the process. udpconn reports
// what one Write carries, transport subtracts its newline, and this package takes the smaller of that and the bound.
func TestSendBudgetReportsTheWireLimitNotTheProtocolLimit(t *testing.T) {
	// udpconn's framing spelled out, since this package asks structurally and imports no transport package:
	// 1200 - 2 control - 8 token - 8 seq - 1 newline.
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

	// A Transport that says nothing about its limit reads as none, never zero, which would trim every Welcome to
	// nothing. net.Pipe-backed conns and this package's test fakes are this case.
	if got := sendBudget(&transport.NDJSONConn{}); got != protocol.MaxPayloadBytes {
		t.Fatalf("sendBudget of a conn with no wire limit = %d, want %d", got, protocol.MaxPayloadBytes)
	}
	if got := sendBudget(nopTransport{}); got != protocol.MaxPayloadBytes {
		t.Fatalf("sendBudget of a Transport that is not an NDJSONConn = %d, want %d",
			got, protocol.MaxPayloadBytes)
	}
}

// nopTransport implements nothing beyond the interface, so the structural question has something to answer no for.
type nopTransport struct{}

func (nopTransport) Send([]byte) error           { return nil }
func (nopTransport) SendUnreliable([]byte) error { return nil }
func (nopTransport) OnReceive(func([]byte))      {}
func (nopTransport) OnDisconnect(func(error))    {}
func (nopTransport) OnError(func(error))         {}
func (nopTransport) Close() error                { return nil }
