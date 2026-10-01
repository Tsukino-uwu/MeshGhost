package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"sync/atomic"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/core"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// bridgePeer is one synthetic client's adapter half, on the far side of a real socket to its core's bridge, as a
// game's adapter is. The default direct path calls RenderRemote as a Go method, with no marshal, queue, coalescing,
// backpressure or framing, so it cannot find a bridge ceiling; it stays because it fits hundreds of peers in one
// process and loads the relay. Numbers from the two modes are not comparable, so every summary line names the mode.
type bridgePeer struct {
	adapter *circleAdapter
	gameID  string
	conn    net.Conn

	// linesIn counts lines actually read off the socket, a number the direct path cannot produce.
	linesIn  atomic.Uint64
	rendered atomic.Uint64
	despawns atomic.Uint64
	// sendFails counts frames whose local_state could not be written, which the direct path cannot fail at.
	sendFails atomic.Uint64
}

// runBridgePeer serves the core's bridge on its own loopback port, dials it, and drives one synthetic peer over it.
// It uses the core's own listener because everything under test (admission, the writer queue, coalescing, the
// marshal, the framing) is on the core's side of the socket.
func runBridgePeer(c *core.Core, a *circleAdapter, gameID string, tick time.Duration, stop <-chan struct{}) (*bridgePeer, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("bridge listen: %w", err)
	}
	go func() {
		if serr := c.ServeBridge(ln); serr != nil {
			select {
			case <-stop:
			default:
				log.Printf("meshghost-fakeadapter: bridge serve ended: %v", serr)
			}
		}
	}()

	conn, err := net.DialTimeout("tcp", ln.Addr().String(), 5*time.Second)
	if err != nil {
		_ = ln.Close()
		return nil, fmt.Errorf("bridge dial: %w", err)
	}

	p := &bridgePeer{adapter: a, gameID: gameID, conn: conn}

	// The hello as a shipped adapter sends it, protocol floor included, so the floor check runs too.
	hello, err := json.Marshal(bridge.Envelope{
		Type: bridge.TypeHello,
		Payload: mustJSON(bridge.Hello{
			GameID:             gameID,
			GameVersion:        "fakeadapter",
			MinProtocolVersion: protocol.Version,
		}),
	})
	if err != nil {
		return nil, fmt.Errorf("marshal hello: %w", err)
	}
	if _, err := fmt.Fprintf(conn, "%s\n", hello); err != nil {
		return nil, fmt.Errorf("send hello: %w", err)
	}

	go p.readLoop(stop)
	go p.sendLoop(tick, stop)
	go func() {
		<-stop
		_ = conn.Close()
		_ = ln.Close()
	}()
	return p, nil
}

// readLoop reads the core's frames off the socket: real bytes, real framing, real parsing.
func (p *bridgePeer) readLoop(stop <-chan struct{}) {
	sc := bufio.NewScanner(p.conn)
	// The core's own line bound, so an over-long line fails here as it would for a real adapter.
	sc.Buffer(make([]byte, 0, 64*1024), protocol.MaxLineBytes)
	for sc.Scan() {
		line := sc.Bytes()
		if len(line) == 0 {
			continue
		}
		p.linesIn.Add(1)
		var env struct {
			Type    string          `json:"type"`
			Payload json.RawMessage `json:"payload"`
		}
		if err := json.Unmarshal(line, &env); err != nil {
			continue
		}
		switch env.Type {
		case string(bridge.TypeRenderRemote):
			var rr bridge.RenderRemote
			if err := json.Unmarshal(env.Payload, &rr); err != nil {
				continue
			}
			p.rendered.Add(1)
			// The same bookkeeping the direct path feeds, so attrition and the live count match in both modes.
			p.adapter.RenderRemote(rr.PlayerID, rr.State)
		case string(bridge.TypeDespawnRemote):
			var dr bridge.DespawnRemote
			if err := json.Unmarshal(env.Payload, &dr); err != nil {
				continue
			}
			p.despawns.Add(1)
			p.adapter.DespawnRemote(dr.PlayerID)
		}
	}
	select {
	case <-stop:
	default:
		if err := sc.Err(); err != nil {
			log.Printf("meshghost-fakeadapter: bridge read ended: %v", err)
		}
	}
}

// sendLoop sends one local_state per tick over the socket.
func (p *bridgePeer) sendLoop(tick time.Duration, stop <-chan struct{}) {
	t := time.NewTicker(tick)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			st, ok := p.adapter.GetLocalState()
			if !ok {
				continue
			}
			line, err := json.Marshal(bridge.Envelope{
				Type:    bridge.TypeLocalState,
				Payload: mustJSON(bridge.LocalState{State: &st}),
			})
			if err != nil {
				continue
			}
			// A core that stops reading shows up as a send failure rather than this goroutine parking forever.
			_ = p.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
			if _, err := fmt.Fprintf(p.conn, "%s\n", line); err != nil {
				p.sendFails.Add(1)
			}
		}
	}
}

func mustJSON(v any) json.RawMessage {
	b, err := json.Marshal(v)
	if err != nil {
		// Every payload here is a fixed struct of plain fields, so a failure is a bug in this file.
		panic("fakeadapter: payload failed to marshal: " + err.Error())
	}
	return b
}
