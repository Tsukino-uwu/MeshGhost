package core

import (
	"sync"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// The chaser pack follows the settings a save brings: a bigger pack, a smaller
// one, and off. StartChasers stops the old pack first, so the count returned
// is the pack now running.
func TestSetChaserSettingsRestartsThePack(t *testing.T) {
	c := New()
	t.Cleanup(c.StopChasers)
	base := ChaserSettings{Enabled: true, Count: 2, Delay: time.Second, Spacing: 100 * time.Millisecond, SpawnDelay: time.Second}
	if n := c.SetChaserSettings(base); n != 2 {
		t.Fatalf("pack of 2: got %d", n)
	}
	base.Count = 3
	if n := c.SetChaserSettings(base); n != 3 {
		t.Fatalf("pack grown to 3: got %d", n)
	}
	base.Enabled = false
	if n := c.SetChaserSettings(base); n != 0 {
		t.Fatalf("pack off: got %d", n)
	}
	c.mu.Lock()
	enabled := c.ChaserEnabled
	c.mu.Unlock()
	if enabled {
		t.Error("ChaserEnabled still true after the pack was turned off")
	}
}

// A saved ghost_collision reaches the attached adapter as a fresh session
// policy, even though the room's policy did not change -- the de-dupe key is
// cleared on purpose so the player sees the resolution logged again.
func TestSetGhostCollisionPreferenceRepushesThePolicy(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	relayAddr := startRelayWith(t, s)

	c, bridgeAddr := startCoreLazy(t, relayAddr, "room", "p1")
	fa := dialFakeAdapter(t, bridgeAddr)
	fa.hello("emerald")
	fa.awaitReady()
	if got := waitPolicy(t, fa); got != protocol.GhostCollisionEnabled {
		t.Fatalf("initial policy %q, want enabled (the room's default)", got)
	}

	c.SetGhostCollisionPreference(protocol.GhostCollisionDisabled)
	if got := waitPolicy(t, fa); got != protocol.GhostCollisionDisabled {
		t.Fatalf("after the save the adapter heard %q, want disabled", got)
	}
	// And back: the room allows it, so the preference alone decides.
	c.SetGhostCollisionPreference(protocol.GhostCollisionEnabled)
	if got := waitPolicy(t, fa); got != protocol.GhostCollisionEnabled {
		t.Fatalf("after the second save the adapter heard %q, want enabled", got)
	}
}

// A saved name (or room, or relay) makes the core leave its relay session and
// rejoin with the new Hello, through the same auto-retry a dropped socket
// gets. Observed as a second OnRelayConnected, and the relay's roster then
// carries the new name.
func TestSetConnectionSettingsRejoinsTheRelay(t *testing.T) {
	s := relay.NewServer()
	s.SendHz = protocol.MaxSendHz
	relayAddr := startRelayWith(t, s)

	connected := make(chan struct{}, 8)
	c, bridgeAddr := startCoreLazyWith(t, relayAddr, "room", "before", func(c *Core) {
		c.OnRelayConnected = func(string) { connected <- struct{}{} }
	})
	fa := dialFakeAdapter(t, bridgeAddr)
	fa.hello("emerald")
	fa.awaitReady()
	select {
	case <-connected:
	case <-time.After(testTimeout):
		t.Fatal("never connected the first time")
	}

	settings := c.connectionSettings()
	settings.DisplayName = "after"
	if !c.SetConnectionSettings(settings) {
		t.Fatal("SetConnectionSettings reported no rejoin with a live session")
	}
	select {
	case <-connected:
	case <-time.After(5 * testTimeout):
		t.Fatal("no second connection after the name changed")
	}
	if got := c.displayName(); got != "after" {
		t.Errorf("display name after the rejoin: %q", got)
	}
	// An identical save does nothing: no session churn on a ctrl+s.
	if c.SetConnectionSettings(settings) {
		t.Error("an unchanged connection settings save left the session")
	}
}

// Replay settings land on the fields the recorder reads at its next use, and
// the ring follows save_last at once.
func TestSetReplaySettingsRearmsTheRing(t *testing.T) {
	c := New()
	c.SetReplaySettings(ReplaySettings{SaveLastSpan: 20 * time.Second, Inputs: true, Gzip: true, Seek: 7 * time.Second, Name: "n", Color: "#123456"})
	if !c.replayGzip() || !c.replayInputs() || c.saveLastSpan() != 20*time.Second {
		t.Errorf("replay fields not set: gzip=%v inputs=%v save_last=%s", c.replayGzip(), c.replayInputs(), c.saveLastSpan())
	}
	if name, color := c.replayNameColor(); name != "n" || color != "#123456" {
		t.Errorf("replay name/color not set: %q %q", name, color)
	}
	c.mu.Lock()
	seek := c.ReplaySeek
	c.mu.Unlock()
	if seek != 7*time.Second {
		t.Errorf("seek not set: %s", seek)
	}
	if got := ringSpanMs(&c.ring.mu, &c.ring.span); got != 20000 {
		t.Errorf("ring span after save_last 20s: %d ms", got)
	}
	if got := ringSpanMs(&c.inputRing.mu, &c.inputRing.span); got != 20000 {
		t.Errorf("input ring span after inputs on: %d ms", got)
	}
	c.SetReplaySettings(ReplaySettings{SaveLastSpan: 0})
	if got := ringSpanMs(&c.ring.mu, &c.ring.span); got != 0 {
		t.Errorf("ring still armed after save_last 0: %d ms", got)
	}
}

func ringSpanMs(mu *sync.Mutex, span *int64) int64 {
	mu.Lock()
	defer mu.Unlock()
	return *span
}
