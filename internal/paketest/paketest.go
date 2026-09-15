// Package paketest is the room-code proof for a test that speaks the relay's
// wire by hand: a Prover holds the client half of the proof and answers the
// relay's KE2 line when a test's own receive loop hands it over. Production
// code uses core's roomproof.go; this exists so relay, core and cmd tests do
// not each carry a copy of the same twenty lines.
package paketest

import (
	"encoding/base64"
	"encoding/json"
	"testing"

	"github.com/Tsukino-uwu/MeshGhost/pake"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
)

// Prover is one hand-driven client's proof. A nil Prover (no code) has an
// empty KE1 and handles nothing, so a test without a code can hold one.
type Prover struct {
	t        testing.TB
	client   *pake.Client
	identity string
	ke1      string
	failed   bool
}

// New prepares a proof of code against serverIdentity (the relay's
// Server.PakeIdentity, or pake.UnboundIdentity for a relay that set none).
// An empty code returns nil.
func New(t testing.TB, code, serverIdentity string) *Prover {
	t.Helper()
	if code == "" {
		return nil
	}
	c, err := pake.NewClient(code)
	if err != nil {
		t.Fatalf("paketest: %v", err)
	}
	ke1, err := c.Start()
	if err != nil {
		t.Fatalf("paketest: %v", err)
	}
	if serverIdentity == "" {
		serverIdentity = pake.UnboundIdentity
	}
	return &Prover{t: t, client: c, identity: serverIdentity, ke1: base64.StdEncoding.EncodeToString(ke1)}
}

// KE1 is what the hello carries.
func (p *Prover) KE1() string {
	if p == nil {
		return ""
	}
	return p.ke1
}

// Failed reports whether the relay's KE2 did not check out on this side --
// what a client with the wrong code sees before it sends anything.
func (p *Prover) Failed() bool { return p != nil && p.failed }

// Handle answers one line from the relay if it is the proof's KE2, sending
// KE3 back through send, and reports whether the line was consumed.
//
// When the code is wrong the real client sends nothing and hangs up; this
// one sends an unusable KE3 instead, on purpose, so the relay's own refusal
// -- the Reject with the room-code CODE, and the budget charge behind it --
// is what a test reads. That is the relay's behaviour under test; the
// client's is core's.
func (p *Prover) Handle(line []byte, send func([]byte) error) bool {
	if p == nil {
		return false
	}
	var env protocol.Envelope
	if err := json.Unmarshal(line, &env); err != nil || env.Type != protocol.TypePake {
		return false
	}
	var pk protocol.Pake
	if err := json.Unmarshal(env.Payload, &pk); err != nil {
		return true
	}
	ke2, err := base64.StdEncoding.DecodeString(pk.KE2)
	var ke3 []byte
	if err == nil {
		ke3, err = p.client.Finish(ke2, p.identity)
	}
	if err != nil {
		p.failed = true
		ke3 = []byte("not a ke3")
	}
	payload, _ := json.Marshal(protocol.Pake{KE3: base64.StdEncoding.EncodeToString(ke3)})
	out, _ := json.Marshal(protocol.Envelope{Type: protocol.TypePake, Payload: payload})
	if err := send(out); err != nil {
		p.t.Logf("paketest: sending KE3: %v", err)
	}
	return true
}
