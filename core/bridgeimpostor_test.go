package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
)

// sendReplayControl sends a replay_control on this connection, bypassing the
// helpers so it can be sent from a connection that has no business sending one.
func (fa *fakeAdapter) sendReplayControl(action ReplayAction) {
	fa.t.Helper()
	payload, err := json.Marshal(bridge.ReplayControl{Action: string(action)})
	if err != nil {
		fa.t.Fatalf("marshal replay_control: %v", err)
	}
	env, err := json.Marshal(bridge.Envelope{Type: bridge.TypeReplayControl, Payload: payload})
	if err != nil {
		fa.t.Fatalf("marshal envelope: %v", err)
	}
	if err := fa.conn.Send(env); err != nil {
		fa.t.Fatalf("send replay_control: %v", err)
	}
}

// A second bridge connection must not be able to act while a real adapter holds
// the slot.
//
// Admission was checked in the hello case ONLY, so every other bridge message
// was dispatched off any connection that reached the socket -- including one
// whose hello had just been answered "busy". The bridge binds loopback with no
// authentication (deliberately, and documented), so "any connection" means any
// process on the machine, and on a shared Windows box any other user.
//
// replay_control is the assertion here because its effect is unambiguous and
// observable in-process: before this fix, a second connection could start and
// stop the player's recording. The same gate covers local_state (speaking to
// the room as the player, under their player_id and seq), the render_remote
// stream that came back on that unauthenticated connection, and the relayOwner
// claim in onAdapterFrame that let such a connection's close send the real
// player's Goodbye.
func TestASecondBridgeConnectionCannotActWhileAnAdapterIsAttached(t *testing.T) {
	dir := t.TempDir()
	c, bridgeAddr := startCoreLazyWith(t, "", "room", "p1", func(c *Core) {
		c.ReplayDir = dir
		c.Offline = true
	})

	real := dialFakeAdapter(t, bridgeAddr)
	real.hello("emerald")
	real.awaitReady()

	// NO HELLO. Sending one would be answered "busy" and rejectBridge closes the
	// socket, so nothing after it could arrive -- an earlier draft of this test
	// did exactly that and passed with the gate removed, which is the
	// can't-fail shape this whole review pass exists to find. A process that
	// wants to act as the adapter has no reason to announce itself first: the
	// bridge never required a hello to accept a frame, which is the gap.
	impostor := dialFakeAdapter(t, bridgeAddr)

	if c.Recording() {
		t.Fatal("precondition: a recording was already running")
	}
	impostor.sendReplayControl(ReplayRecordStart)

	// Give the core longer than it needs: the assertion is that nothing happens,
	// so a short wait would pass for the wrong reason on a slow machine.
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if c.Recording() {
			t.Fatal("a second bridge connection started the player's recording: " +
				"admission is checked on hello only, so every other message was " +
				"accepted from any process that could reach the loopback socket")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// And the real adapter is unaffected -- the gate must refuse the impostor,
	// not wedge the bridge.
	real.sendReplayControl(ReplayRecordStart)
	started := false
	deadline = time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		if c.Recording() {
			started = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !started {
		t.Fatal("the attached adapter's own replay_control stopped working -- the " +
			"admission gate is refusing the connection it should admit")
	}
	if _, _, err := c.StopRecording(); err != nil {
		t.Logf("stop recording: %v", err)
	}
}

// sendInputSample sends an input_sample on this connection, bypassing the
// helpers for the same reason sendReplayControl does.
func (fa *fakeAdapter) sendInputSample(s bridge.InputSample) {
	fa.t.Helper()
	payload, err := json.Marshal(s)
	if err != nil {
		fa.t.Fatalf("marshal input_sample: %v", err)
	}
	env, err := json.Marshal(bridge.Envelope{Type: bridge.TypeInputSample, Payload: payload})
	if err != nil {
		fa.t.Fatalf("marshal envelope: %v", err)
	}
	if err := fa.conn.Send(env); err != nil {
		fa.t.Fatalf("send input_sample: %v", err)
	}
}

// The input track inherits the admission gate, and this is the test that says
// so rather than assuming it. It matters more here than for most messages: the
// track records what the player pressed, so a second process able to write into
// it can put input in a player's own record that the player never performed.
//
// The gate is inherited by CONSTRUCTION -- the case sits inside the same switch,
// below the impostor check -- which is exactly the kind of thing that survives
// until a refactor moves a case out of the switch. So it is pinned.
func TestASecondBridgeConnectionCannotWriteTheInputTrack(t *testing.T) {
	dir := t.TempDir()
	c, bridgeAddr := startCoreLazyWith(t, "", "room", "p1", func(c *Core) {
		c.ReplayDir = dir
		c.Offline = true
		c.ReplayInputs = true
	})

	real := dialFakeAdapter(t, bridgeAddr)
	real.hello("emerald")
	real.awaitReady()

	if _, err := c.StartInputRecording("rec-impostor"); err != nil {
		t.Fatalf("StartInputRecording: %v", err)
	}

	// No hello, for the reason the test above spells out.
	impostor := dialFakeAdapter(t, bridgeAddr)
	impostor.sendInputSample(bridge.InputSample{
		Labels: []string{"impostor"},
		Edges:  []bridge.InputEdge{{F: 1, T: 1, M: 1}},
	})

	// Nothing should happen, so wait longer than it would need.
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		c.inputRec.mu.Lock()
		written := c.inputRec.written
		c.inputRec.mu.Unlock()
		if written > 0 {
			t.Fatal("a second bridge connection wrote into the player's input track")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// And the real adapter still works -- the gate must refuse the impostor,
	// not wedge the track.
	real.sendInputSample(bridge.InputSample{
		Labels: []string{"jump"},
		Edges:  []bridge.InputEdge{{F: 10, T: 160, M: 1}},
	})
	wrote := false
	deadline = time.Now().Add(testTimeout)
	for time.Now().Before(deadline) {
		c.inputRec.mu.Lock()
		written := c.inputRec.written
		c.inputRec.mu.Unlock()
		if written > 0 {
			wrote = true
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !wrote {
		t.Fatal("the attached adapter's own input_sample stopped working -- the " +
			"admission gate is refusing the connection it should admit")
	}
	if _, _, err := c.StopInputRecording(); err != nil {
		t.Logf("stop input track: %v", err)
	}
}
