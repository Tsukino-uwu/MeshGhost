package main

// THE REAL-BRIDGE MODE: a synthetic peer that talks to its core the way a GAME does.
//
// **WHY THIS EXISTS (review H14).** The default path calls `core.RunAdapter`, which invokes
// `adapter.RenderRemote` as a direct Go method call. No marshal, no queue, no coalescing, no
// backpressure, no line framing -- so the rig was STRUCTURALLY incapable of finding a bridge
// ceiling, and that is why the ~350-ghost one stayed hidden until a real game hit it. A rig that
// cannot fail the way the thing it models fails is not measuring that thing.
//
// **WHY THE DIRECT PATH STAYS.** It is the only way to get hundreds of peers into one process:
// every client here would otherwise cost a socket, a reader goroutine and an NDJSON stream of its
// own. That mode exists to load the RELAY and the core's interpolation, and it is good at it.
// This mode exists to load the BRIDGE. They answer different questions, so the tool keeps both and
// says which one produced a number -- the user's call, 2026-09-11: keep both, one tool, one flag.
//
// **NUMBERS FROM THE TWO MODES ARE NOT COMPARABLE**, which is why every summary line names the
// mode. Past measurements are all direct-mode and stay valid as relay-side numbers.

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

// bridgePeer is one synthetic client's adapter half, on the far side of a real socket.
type bridgePeer struct {
	adapter *circleAdapter
	gameID  string
	conn    net.Conn

	// linesIn counts lines actually READ off the socket, which is the number the direct path
	// could never produce -- see rendersArrived.
	linesIn  atomic.Uint64
	rendered atomic.Uint64
	despawns atomic.Uint64
	// sendFails counts frames whose local_state could not be written. On the direct path this
	// cannot happen at all, which is exactly the blind spot.
	sendFails atomic.Uint64
}

// runBridgePeer serves the core's bridge on its own loopback port, dials it, and drives one
// synthetic peer over it for real.
//
// The core's OWN listener is used rather than a fake one: everything under test -- the admission
// slot, the writer queue, coalescing, the marshal, the framing -- is on the core's side of this
// socket, and a stub would model it rather than exercise it.
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

	// The hello, exactly as a shipped adapter sends it -- including the protocol floor, so this
	// mode exercises the check a real adapter's hello goes through (ADR 0059).
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

// readLoop is the half the direct path never had: real bytes, real framing, real parsing.
func (p *bridgePeer) readLoop(stop <-chan struct{}) {
	sc := bufio.NewScanner(p.conn)
	// The same bound the core writes under, so an over-long line is a failure here rather than a
	// silent truncation -- matching what a real adapter would see.
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
			// Into the SAME bookkeeping the direct path feeds, so the peer-attrition check and
			// the live count work identically in both modes.
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

// sendLoop is the frame path: one local_state per tick, over the socket.
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
			// A real write deadline, so a core that stops reading shows up as a FAILURE here
			// rather than as this goroutine parking forever -- which is the shape the direct
			// path cannot produce and the reason this mode exists.
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
		// Every payload here is a fixed struct of plain fields; a failure is a programming
		// error in this file, not something a run should carry on past.
		panic("fakeadapter: payload failed to marshal: " + err.Error())
	}
	return b
}
