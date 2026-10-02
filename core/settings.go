package core

import (
	"fmt"
	"log"
	"time"
)

// Live settings: cmd/meshghost polls config.json and calls the setters below; each changes the fields it owns under the
// lock that guards them and re-runs whatever consumed the old value, so a save lands without a relaunch.
//
// Two locks, on purpose. c.mu guards what the render and frame path reads every tick (smoothing, chaser, ghost
// collision). The replay and connection fields are read from the recorder, replay and dial paths, and go through
// settingsMu, an RWMutex since the reads are many and the writes are a person saving a file. Nothing here takes c.mu
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
	Contact    ChaserContact
	SpawnDelay time.Duration
}

// ConnectionSettings is what the relay Hello is built from; a change takes effect only on a fresh connection.
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

// SetSmoothing changes the render-side smoothing under c.mu, used from the next tick. An unknown curve or prediction
// name is refused and nothing changes: a typo saved mid-session must not silently pick a default.
func (c *Core) SetSmoothing(interp, localInterp, extrapolate, correction time.Duration, curve CurveMode, predict PredictMode) error {
	if correction < 0 {
		return fmt.Errorf("correction %s is negative -- 0 turns error decay off, a positive duration is the time a correction slides over", correction)
	}
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
	c.Correction = correction
	c.mu.Unlock()
	return nil
}

// SetGhostCollisionPreference changes this client's ghost_collision preference and re-tells the adapter the resolved
// policy (the room's value still wins where stricter). The de-dupe key is cleared so the push and its log line happen
// even when the resolved value is unchanged: that line is where a player sees why ghosts are or are not solid.
func (c *Core) SetGhostCollisionPreference(pref string) {
	c.mu.Lock()
	c.GhostCollision = pref
	c.sentGhostCollision = ""
	c.mu.Unlock()
	c.pushSessionPolicy()
}

// SetChaserSettings replaces the chaser section and restarts the pack from it, so a running pack despawns and respawns
// after spawn_delay as on a fresh attach; disabled, the pack stops. The contact policy is re-pushed either way. It
// returns the number of chasers now running.
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

// SetReplaySettings replaces the replay section. Most of it is read at its next use; save_last resizes the live rings
// now, and inputs turned on arms the input ring. record_on_launch is a launch setting: a save neither starts nor stops
// a recording in progress.
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

// SetConnectionSettings replaces what the relay Hello is built from. When any of it changed and a relay session is
// live, the session is closed on purpose and the disconnect path redials with the new values through the ordinary
// auto-retry, without touching the game. Offline turned on closes the session and the retry declines to dial; turned
// off with a game attached, it dials again. It reports whether a reconnect was set in motion.
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
		// The disconnect callback does the rest, and reconnectWithBackoff reads the new settings on its first dial.
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
