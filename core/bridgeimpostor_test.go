package core

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/bridge"
)

// sendReplayControl sends a replay_control on this connection, bypassing the helpers so a connection with no
// business sending one can.
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

// TestASecondBridgeConnectionCannotActWhileAnAdapterIsAttached: the bridge binds loopback with no authentication, so
// any local process can connect, and none may act while a real adapter holds the slot. replay_control is the probe
// because its effect is observable in-process; the same gate covers local_state, the render_remote stream and the
// relayOwner claim whose close would send the player's Goodbye.
func TestASecondBridgeConnectionCannotActWhileAnAdapterIsAttached(t *testing.T) {
	dir := t.TempDir()
	c, bridgeAddr := startCoreLazyWith(t, "", "room", "p1", func(c *Core) {
		c.ReplayDir = dir
		c.Offline = true
	})

	real := dialFakeAdapter(t, bridgeAddr)
	real.hello("emerald")
	real.awaitReady()

	// No hello: one would be answered "busy" and rejectBridge closes the socket, so nothing after it could arrive.
	impostor := dialFakeAdapter(t, bridgeAddr)

	if c.Recording() {
		t.Fatal("precondition: a recording was already running")
	}
	impostor.sendReplayControl(ReplayRecordStart)

	// Longer than the core needs: nothing should happen, and a short wait would pass on a slow machine.
	deadline := time.Now().Add(500 * time.Millisecond)
	for time.Now().Before(deadline) {
		if c.Recording() {
			t.Fatal("a second bridge connection started the player's recording: " +
				"admission is checked on hello only, so every other message was " +
				"accepted from any process that could reach the loopback socket")
		}
		time.Sleep(10 * time.Millisecond)
	}

	// The gate must refuse the impostor, not wedge the bridge.
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

// sendInputSample sends an input_sample on this connection, bypassing the helpers as sendReplayControl does.
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

// TestASecondBridgeConnectionCannotWriteTheInputTrack: the track records what the player pressed, so a second process
// could put input in it the player never performed. The gate holds only because the case sits inside the same switch,
// which a refactor could undo.
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

	// No hello, as in the test above.
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

	// The gate must refuse the impostor, not wedge the track.
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
