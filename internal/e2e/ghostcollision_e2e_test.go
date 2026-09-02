package e2e

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/transport"
)

// awaitPolicy dials the bridge as an adapter would, says hello, and returns
// the ghost_collision the REAL client binary pushes down.
func awaitPolicy(t *testing.T, bridgeAddr string) string {
	t.Helper()
	conn, err := transport.Dial(bridgeAddr)
	if err != nil {
		t.Fatalf("dial bridge: %v", err)
	}
	t.Cleanup(func() { conn.Close() })

	got := make(chan string, 1)
	conn.OnReceive(func(payload []byte) {
		var env bridge.Envelope
		if json.Unmarshal(payload, &env) != nil || env.Type != bridge.TypeSessionPolicy {
			return
		}
		var sp bridge.SessionPolicy
		if json.Unmarshal(env.Payload, &sp) == nil {
			select {
			case got <- sp.GhostCollision:
			default:
			}
		}
	})
	if !sendBridge(conn, bridge.TypeHello, bridge.Hello{GameID: "e2egame"}) {
		t.Fatal("send hello")
	}
	select {
	case v := <-got:
		return v
	case <-time.After(15 * time.Second):
		t.Fatal("no session_policy from the real client binary")
		return ""
	}
}

// The whole feature, through the actual shipped executables: a host types one
// value into the relay's config, and an adapter in a different process is told.
// The in-package core tests prove the resolution rule; this proves the two
// binaries really carry it between them, which is the part a wire-format or
// flag-plumbing mistake would break while every unit test still passed.
func TestGhostCollisionPolicyCrossesTheRealBinaries(t *testing.T) {
	for _, tc := range []struct {
		name       string
		relayArgs  []string
		clientArgs []string
		want       string
	}{
		{"host disables it room-wide", []string{"-ghost-collision", "disabled"}, nil, protocol.GhostCollisionDisabled},
		{"host leaves it alone", []string{"-ghost-collision", "enabled"}, nil, protocol.GhostCollisionEnabled},
		// The relay ships disabled since 2026-09-02 (the user's call), so silence on both sides is off.
		{"neither side says anything", nil, nil, protocol.GhostCollisionDisabled},
		{
			"a player opts out under a permissive host",
			[]string{"-ghost-collision", "enabled"},
			[]string{"-ghost-collision", "disabled"},
			protocol.GhostCollisionDisabled,
		},
		{
			"a player cannot opt back in under a strict host",
			[]string{"-ghost-collision", "disabled"},
			[]string{"-ghost-collision", "enabled"},
			protocol.GhostCollisionDisabled,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := newRig(t)

			relayArgs := append([]string{"-addr", r.relayAddr, "-loopback"}, tc.relayArgs...)
			start(t, r.dir, r.relayBin, relayArgs...)
			waitForListener(t, r.relayAddr)

			clientArgs := append([]string{
				"-relay", r.relayAddr,
				"-bridge", r.bridgeAddr,
				"-game", "e2egame",
				"-room", "e2eroom",
				"-interp", "0ms",
				"-min-send", "10ms",
			}, tc.clientArgs...)
			start(t, r.dir, r.clientBin, clientArgs...)
			waitForListener(t, r.bridgeAddr)

			if got := awaitPolicy(t, r.bridgeAddr); got != tc.want {
				t.Errorf("adapter was told %q, want %q (relay %v, client %v)",
					got, tc.want, tc.relayArgs, tc.clientArgs)
			}
		})
	}
}
