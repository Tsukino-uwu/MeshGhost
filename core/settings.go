package core

import (
	"fmt"
	"log"
	"time"
)

// LIVE SETTINGS (2026-09-09). A tester's report: editing config.json while the
// game ran changed the input display (the Pseudoregalia mod polls the file for
// its own keys) and nothing else -- replay, chaser and hotkey settings were read
// once at start into plain fields on this struct and never looked at again.
// The user's call: "make everything refresh if edit/save is used". cmd/meshghost
// polls the file (reload.go) and calls the setters below; each one changes the
// fields it owns under the lock that guards them and re-runs whatever consumed
// the old value at start, so a save lands without a relaunch.
//
// Two locks, on purpose. c.mu guards the fields the render/frame path reads
// every tick (smoothing, chaser, ghost collision) and those are set under it.
// The replay and connection fields were read bare from the recorder, replay and
// dial paths, which was fine while nothing wrote them after start; now that
// something does, they go through settingsMu (an RWMutex: the reads are many
// and short, the writes are a human saving a file). Nothing here takes c.mu
// while holding settingsMu.

// ReplaySettings is the replay section as the live setters take it.
type ReplaySettings struct {
	RecordOnLaunch bool
	SaveLastSpan   time.Duration
	StartDelay     time.Duration
	Seek           time.Duration
	SplitTimes     bool
	Gzip           bool
	Delta          bool
	Inputs         bool
	Name           string
	Color          string
}

// ChaserSettings is the chaser section as the live setters take it.
type ChaserSettings struct {
	Enabled    bool
	Count      int
	Delay      time.Duration
	Spacing    time.Duration
	Name       string
	Color      string
	Contact    bool
	SpawnDelay time.Duration
}

// ConnectionSettings is what the relay Hello is built from. A change to any of
// them can only take effect on a fresh connection.
type ConnectionSettings struct {
	RelayAddr    string
	Room         string
	RoomCode     string
	DisplayName  string
	NameColor    string
	MaxReceiveHz int
	Offline      bool
}

// --- accessors: every read of a settingsMu-guarded field goes through one ---

func (c *Core) replayDir() string {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.ReplayDir
}

func (c *Core) recordOnLaunch() bool {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.RecordOnLaunch
}

func (c *Core) saveLastSpan() time.Duration {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.SaveLastSpan
}

func (c *Core) replayStartDelay() time.Duration {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.ReplayStartDelay
}

func (c *Core) splitTimes() bool {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.SplitTimes
}

func (c *Core) replayGzip() bool {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.ReplayGzip
}

func (c *Core) replayDelta() bool {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.ReplayDelta
}

func (c *Core) replayInputs() bool {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.ReplayInputs
}

func (c *Core) replayNameColor() (string, string) {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.ReplayName, c.ReplayColor
}

// connectionSettings is the snapshot a dial builds its Hello from.
func (c *Core) connectionSettings() ConnectionSettings {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return ConnectionSettings{
		RelayAddr: c.RelayAddr, Room: c.Room, RoomCode: c.RoomCode,
		DisplayName: c.DisplayName, NameColor: c.NameColor,
		MaxReceiveHz: c.MaxReceiveHz, Offline: c.Offline,
	}
}

// --- setters ------------------------------------------------------------------

// SetSmoothing changes the render-side smoothing under c.mu. The render path
// reads these every tick (remotes.go documents them as changeable while
// running), so the next tick uses them. A curve or prediction name the core
// does not know is refused with an error and nothing changes -- a typo in a
// file saved mid-session must not silently pick a default.
func (c *Core) SetSmoothing(interp, localInterp, extrapolate time.Duration, curve CurveMode, predict PredictMode) error {
	switch curve {
	case CurveLinear, CurveCatmullRom:
	default:
		return fmt.Errorf("curve %q is not a render curve -- use %q or %q", curve, CurveLinear, CurveCatmullRom)
	}
	switch predict {
	case PredictLinear, PredictAccelerated, PredictDamped:
	default:
		return fmt.Errorf("predict %q is not a prediction model -- use %q, %q or %q", predict, PredictLinear, PredictDamped, PredictAccelerated)
	}
	c.mu.Lock()
	c.InterpolationDelay = interp
	c.LocalInterpolationDelay = localInterp
	c.Extrapolate = extrapolate
	c.Curve = curve
	c.Predict = predict
	c.mu.Unlock()
	return nil
}

// SetGhostCollisionPreference changes this client's ghost_collision preference
// and re-tells the attached adapter the resolved policy (the room's value still
// wins where it is stricter). The de-dupe key is cleared so a push happens even
// if the resolved value is unchanged -- the log line that follows is the one
// place a player sees why their ghosts are or are not solid.
func (c *Core) SetGhostCollisionPreference(pref string) {
	c.mu.Lock()
	c.GhostCollision = pref
	c.sentGhostCollision = ""
	c.mu.Unlock()
	c.pushSessionPolicy()
}

// SetChaserSettings replaces the chaser section and restarts the pack from it:
// StartChasers stops the running pack first and snapshots the fields under
// c.mu, so an in-flight pack visibly despawns and respawns after spawn_delay
// (the same as a fresh attach). With Enabled false the pack is stopped. The
// contact half of the session policy is re-pushed either way. Returns the
// number of chasers now running.
func (c *Core) SetChaserSettings(s ChaserSettings) int {
	c.mu.Lock()
	c.ChaserEnabled, c.ChaserCount, c.ChaserDelay, c.ChaserSpacing = s.Enabled, s.Count, s.Delay, s.Spacing
	c.ChaserName, c.ChaserColor, c.ChaserContact, c.ChaserSpawnDelay = s.Name, s.Color, s.Contact, s.SpawnDelay
	c.sentGhostCollision = ""
	c.mu.Unlock()
	n := 0
	if s.Enabled {
		n = c.StartChasers()
	} else {
		c.StopChasers()
	}
	c.pushSessionPolicy()
	return n
}

// SetReplaySettings replaces the replay section. Most of it is read at the
// next use (the next recording start, the next save-last, the next replay
// start, the next seek); the two that arm something now are re-armed here:
// save_last resizes the live ring (and the input ring, when inputs is on) and
// inputs turned on arms the input ring it had skipped. record_on_launch is a
// launch setting -- a recording in progress is neither started nor stopped by
// a save, which is the one thing a player editing mid-session would not want
// decided for them.
func (c *Core) SetReplaySettings(s ReplaySettings) {
	c.settingsMu.Lock()
	c.RecordOnLaunch = s.RecordOnLaunch
	c.SaveLastSpan = s.SaveLastSpan
	c.ReplayStartDelay = s.StartDelay
	c.SplitTimes = s.SplitTimes
	c.ReplayGzip = s.Gzip
	c.ReplayDelta = s.Delta
	c.ReplayInputs = s.Inputs
	c.ReplayName, c.ReplayColor = s.Name, s.Color
	c.settingsMu.Unlock()
	c.mu.Lock()
	c.ReplaySeek = s.Seek
	c.mu.Unlock()
	if s.SaveLastSpan > 0 {
		c.armRing()
		c.armInputRing()
	} else {
		c.SetRingSpan(0)
		c.SetInputRingSpan(0)
	}
	if !s.Inputs {
		c.SetInputRingSpan(0)
	}
}

// SetConnectionSettings replaces what the relay Hello is built from. When any
// of it changed and a relay session is live, the session is closed on purpose:
// the connection's own disconnect path then redials with the new values
// through the same auto-retry a dropped socket gets (ConnectRelay reads these
// fields per dial), so the room, name or relay a player just saved is where
// they end up, without touching the game. Offline turned on closes the session
// and the retry declines to dial; offline turned off with a game attached
// dials again. Returns whether a reconnect was set in motion.
func (c *Core) SetConnectionSettings(s ConnectionSettings) bool {
	c.settingsMu.Lock()
	changed := s != ConnectionSettings{
		RelayAddr: c.RelayAddr, Room: c.Room, RoomCode: c.RoomCode,
		DisplayName: c.DisplayName, NameColor: c.NameColor,
		MaxReceiveHz: c.MaxReceiveHz, Offline: c.Offline,
	}
	wasOffline := c.Offline
	c.RelayAddr, c.Room, c.RoomCode = s.RelayAddr, s.Room, s.RoomCode
	c.DisplayName, c.NameColor = s.DisplayName, s.NameColor
	c.MaxReceiveHz, c.Offline = s.MaxReceiveHz, s.Offline
	c.settingsMu.Unlock()
	if !changed {
		return false
	}
	c.mu.Lock()
	live := c.relay
	retry := relayRetry{c.autoRetryGameID, c.autoRetryAdapterGameVersion, c.autoRetryBridgeConn}
	c.mu.Unlock()
	if live != nil {
		// The disconnect callback does the rest: clearRelaySession, the
		// remotes dropped, and reconnectWithBackoff when an adapter is
		// attached -- which reads the new settings on its first dial.
		log.Printf("core: connection settings changed -- leaving the relay session to rejoin with them")
		live.Close()
		return true
	}
	if wasOffline && !s.Offline && retry.gameID != "" {
		log.Printf("core: offline turned off -- connecting to the relay")
		go c.reconnectWithBackoff(retry.gameID, retry.adapterGameVersion, retry.bridgeConn)
		return true
	}
	return false
}

// Per-field forms of connectionSettings, for the read sites that want one value.
func (c *Core) relayAddr() string {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.RelayAddr
}
func (c *Core) room() string { c.settingsMu.RLock(); defer c.settingsMu.RUnlock(); return c.Room }
func (c *Core) roomCode() string {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.RoomCode
}
func (c *Core) displayName() string {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.DisplayName
}
func (c *Core) nameColor() string {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.NameColor
}
func (c *Core) maxReceiveHz() int {
	c.settingsMu.RLock()
	defer c.settingsMu.RUnlock()
	return c.MaxReceiveHz
}
func (c *Core) offline() bool { c.settingsMu.RLock(); defer c.settingsMu.RUnlock(); return c.Offline }
