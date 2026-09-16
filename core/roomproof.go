package core

// The client's half of the room-code proof (package pake, ADR 0067): the
// code never leaves this process. A hello carries KE1; the relay's KE2 is
// checked against the code AND against the fingerprint of the certificate
// this connection verified, so a relay that is not the one this client
// meant fails here, before anything else is sent; KE3 goes back; the relay
// then welcomes (or answers the transport query) exactly as a right code
// used to make it.

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net"
	"sync"

	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/pake"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// roomProof is one connection's proof in progress. Nil when this Core has no
// room code: then the hello carries nothing and the relay either has no code
// either (and welcomes) or refuses.
type roomProof struct {
	client   *pake.Client
	serverID string
	ke1      string // base64, for the hello

	mu       sync.Mutex
	answered bool // KE2 arrived and was judged
}

// newRoomProof prepares the proof for a connection, or returns nil when
// there is no code to prove. serverID is the fingerprint of the certificate
// netConn verified -- every shipped dial is TLS, so it is set; the dev-only
// udp transport has none and proves the code unbound.
func newRoomProof(roomCode string, netConn net.Conn) (*roomProof, error) {
	if roomCode == "" {
		return nil, nil
	}
	pc, err := pake.NewClient(roomCode)
	if err != nil {
		return nil, err
	}
	ke1, err := pc.Start()
	if err != nil {
		return nil, err
	}
	serverID := tlsx.PeerFingerprint(netConn)
	if serverID == "" {
		serverID = pake.UnboundIdentity
	}
	return &roomProof{client: pc, serverID: serverID, ke1: base64.StdEncoding.EncodeToString(ke1)}, nil
}

// KE1 is what the hello carries; "" for a nil proof.
func (p *roomProof) KE1() string {
	if p == nil {
		return ""
	}
	return p.ke1
}

// errProofFailed is the local refusal: the relay's KE2 did not check out
// against this client's code and the certificate it verified. Reported as a
// Reject with the room-code CODE so every caller classifies it as permanent
// (a retry cannot fix a wrong code), with prose that names the other cause.
var errProofFailed = protocol.Reject{
	Reason: "the room code did not match what the server knows -- or the server is not the one this " +
		"client verified (its certificate fingerprint is bound into the proof)",
	Code:      protocol.CodeInvalidRoomCode,
	Retryable: false,
}

// errServerHasNoCode is the refusal when this client has a room code and the
// server welcomed it without asking for one. A code on one side only is a
// mismatch, the same as two different codes (the user, 2026-09-16: "either you
// have a code or you don't ... both should either have no code or both have
// the same code"). Until then the client joined and logged one line, so a
// server pretending to be the player's could take the session simply by never
// asking for the proof (pass 5 of the adversarial review, P1b-client-1; ADR 0070).
var errServerHasNoCode = protocol.Reject{
	Reason: "this client has a room code set, and the server asked for none -- either the server has " +
		"no code (clear room_code in config.json to join it) or it is not the server this client meant",
	Code:      protocol.CodeInvalidRoomCode,
	Retryable: false,
}

// intercept handles one line from the relay if it is the proof's business.
// It returns true when the line was consumed: a KE2, answered with KE3 or
// refused, or a welcome (or transports answer) from a relay that never asked
// for the proof, which is refused as a mismatched code (errServerHasNoCode).
// Any other line returns false so the ordinary handler sees it.
func (p *roomProof) intercept(conn transport.Transport, payload []byte, refuse func(protocol.Reject)) bool {
	if p == nil {
		return false
	}
	var env protocol.Envelope
	if err := json.Unmarshal(payload, &env); err != nil {
		return false
	}
	switch env.Type {
	case protocol.TypePake:
		var pk protocol.Pake
		if err := json.Unmarshal(env.Payload, &pk); err != nil || len(pk.KE2) > protocol.MaxPakeFieldLen {
			refuse(errProofFailed)
			_ = conn.Close()
			return true
		}
		p.mu.Lock()
		already := p.answered
		p.answered = true
		p.mu.Unlock()
		if already {
			return true // a second KE2 is not a step of any proof
		}
		ke2, derr := base64.StdEncoding.DecodeString(pk.KE2)
		ke3, err := p.client.Finish(ke2, p.serverID)
		if derr != nil || err != nil {
			if err == nil {
				err = derr
			}
			if errors.Is(err, pake.ErrRefused) || derr != nil {
				refuse(errProofFailed)
			} else {
				refuse(protocol.Reject{Reason: fmt.Sprintf("room code proof: %v", err), Code: protocol.CodeInvalidRoomCode})
			}
			_ = conn.Close()
			return true
		}
		reply, err := json.Marshal(protocol.Pake{KE3: base64.StdEncoding.EncodeToString(ke3)})
		if err != nil {
			return true
		}
		line, err := json.Marshal(protocol.Envelope{Type: protocol.TypePake, Payload: reply})
		if err != nil {
			return true
		}
		if err := conn.Send(line); err != nil {
			log.Printf("core: could not send the room-code proof: %v", err)
		}
		return true
	case protocol.TypeWelcome, protocol.TypeTransports:
		p.mu.Lock()
		asked := p.answered
		p.mu.Unlock()
		if !asked {
			refuse(errServerHasNoCode)
			_ = conn.Close()
			return true
		}
		return false
	default:
		return false
	}
}
