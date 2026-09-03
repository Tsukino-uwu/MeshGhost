package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/core"
	"github.com/Tsukino-uwu/MeshGhost/netx/tlsx"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// The shipped config.json is a SECOND place every default lives, and an explicit value in it
// overrides the code default for every packaged player. So a default that is improved in code and
// not in the file is not a default that shipped — it is a default nobody gets.
//
// That happened, which is why this test exists: DefaultInterpolationDelay was raised from 100ms to
// 250ms on 2026-08-19 after being measured on screen, and both packaging/release/config.json and
// the per-game client template kept "100ms" until the user asked what the release actually ships.
// Every packaged player would have kept exactly the stutter the measurement was about.
//
// Two kinds of value live in that file and this test treats them differently:
//
//   - Values that must TRACK a code default. Checked below. A default change that forgets the file
//     fails here rather than at a player.
//   - Values that deliberately DIVERGE, because a release wants something a bare flag should not
//     assume. Pinned below with their reasons, so the divergence stays a decision rather than
//     decaying into a discrepancy nobody can date.
type shippedConfig struct {
	Client struct {
		ConnectTo             string `json:"connect_to"`
		Transport             string `json:"transport"`
		TLS                   string `json:"tls"`
		Room                  string `json:"room"`
		Name                  string `json:"name"`
		LocalGameBridge       string `json:"local_game_bridge"`
		Interp                string `json:"interp"`
		MaxReceiveHzPerPlayer int    `json:"max_receive_hz_per_player"`
		Replay                struct {
			RecordOnLaunch bool   `json:"record_on_launch"`
			SaveLast       string `json:"save_last"`
			StartDelay     string `json:"start_delay"`
			Seek           string `json:"seek"`
			SplitTimes     bool   `json:"split_times"`
		} `json:"replay"`
		Chaser struct {
			Enabled bool   `json:"enabled"`
			Count   int    `json:"count"`
			Delay   string `json:"delay"`
			Spacing string `json:"spacing"`
			Contact bool   `json:"contact"`
		} `json:"chaser"`
		Hotkeys map[string]string `json:"hotkeys"`
	} `json:"client"`
	Server struct {
		ListenOn   string `json:"listen_on"`
		Transport  string `json:"transport"`
		TLS        string `json:"tls"`
		MaxClients int    `json:"max_clients"`
		SendHz     int    `json:"send_hz"`
	} `json:"server"`
}

func loadShippedConfig(t *testing.T, rel string) shippedConfig {
	t.Helper()
	path := filepath.Join("..", "..", rel)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	var cfg shippedConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		t.Fatalf("parsing %s: %v", path, err)
	}
	return cfg
}

func TestShippedConfigTracksCodeDefaults(t *testing.T) {
	cfg := loadShippedConfig(t, filepath.Join("packaging", "release", "config.json"))

	interp, err := time.ParseDuration(cfg.Client.Interp)
	if err != nil {
		t.Fatalf("shipped interp %q does not parse: %v", cfg.Client.Interp, err)
	}
	if interp != core.DefaultInterpolationDelay {
		t.Errorf("shipped interp is %v but core.DefaultInterpolationDelay is %v -- an explicit "+
			"value in config.json overrides the default, so players would get %v no matter what "+
			"the code says. Update packaging/release/config.json (and the per-game template).",
			interp, core.DefaultInterpolationDelay, interp)
	}
	if cfg.Server.SendHz != protocol.DefaultSendHz {
		t.Errorf("shipped send_hz is %d but protocol.DefaultSendHz is %d",
			cfg.Server.SendHz, protocol.DefaultSendHz)
	}
	if cfg.Server.MaxClients != relay.DefaultMaxClients {
		t.Errorf("shipped max_clients is %d but relay.DefaultMaxClients is %d",
			cfg.Server.MaxClients, relay.DefaultMaxClients)
	}
	if cfg.Client.MaxReceiveHzPerPlayer != core.DefaultMaxReceiveHz {
		t.Errorf("shipped max_receive_hz_per_player is %d but core.DefaultMaxReceiveHz is %d",
			cfg.Client.MaxReceiveHzPerPlayer, core.DefaultMaxReceiveHz)
	}
	// tls used to be a deliberate divergence -- the flag defaulted to off so a client could not
	// suddenly demand encryption from an older relay. That reasoning was retired on 2026-08-19:
	// the project's stance is that everyone is on the latest release, so a default that exists to
	// protect stale versions is protecting nobody while leaving fresh installs unencrypted by
	// default. Both flags now default to auto, and the shipped config must agree.
	if cfg.Client.TLS != tlsx.Auto.String() {
		t.Errorf("shipped client tls is %q but the flag default is %q",
			cfg.Client.TLS, tlsx.Auto.String())
	}
	if cfg.Server.TLS != tlsx.Auto.String() {
		t.Errorf("shipped server tls is %q but the flag default is %q",
			cfg.Server.TLS, tlsx.Auto.String())
	}
}

// Where the release deliberately does NOT match a flag default. Each is a decision with a reason,
// and pinning them here means the reason has to be revisited to change them rather than quietly
// eroded. A failure is not necessarily a bug — it means read the reason and decide again.
func TestShippedConfigDeliberateDivergences(t *testing.T) {
	cfg := loadShippedConfig(t, filepath.Join("packaging", "release", "config.json"))

	// listen_on: the -addr FLAG defaults to 127.0.0.1, which is right for development and useless
	// for hosting -- a host has to accept connections from other machines. The shipped server
	// config is for someone hosting, so it binds every interface.
	if cfg.Server.ListenOn != "0.0.0.0:7777" {
		t.Errorf("shipped listen_on should bind every interface for a host, got %q",
			cfg.Server.ListenOn)
	}
}

// TestShippedConfigNeverRecordsOrChasesBySurprise pins the replay-era keys
// (ADR 0047, 0048): a release must never write a file or spawn a chaser
// unless the player asked, the contact hook ships off, and the six hotkey
// chords match the flag defaults so the log, the README and the file agree.
func TestShippedConfigNeverRecordsOrChasesBySurprise(t *testing.T) {
	cfg := loadShippedConfig(t, filepath.Join("packaging", "release", "config.json"))
	if cfg.Client.Replay.RecordOnLaunch {
		t.Error("shipped replay.record_on_launch must be false: nobody's disk fills up by surprise")
	}
	if cfg.Client.Replay.SplitTimes {
		t.Error("shipped replay.split_times must be false: a nametag that changes several times a second is opted into")
	}
	if cfg.Client.Chaser.Enabled || cfg.Client.Chaser.Contact {
		t.Errorf("shipped chaser must be off with contact off, got enabled=%v contact=%v",
			cfg.Client.Chaser.Enabled, cfg.Client.Chaser.Contact)
	}
	if cfg.Client.Replay.SaveLast != "30s" || cfg.Client.Replay.Seek != "5s" || cfg.Client.Replay.StartDelay != "0s" {
		t.Errorf("shipped replay durations drifted from the flag defaults: %+v", cfg.Client.Replay)
	}
	if cfg.Client.Chaser.Count != 1 || cfg.Client.Chaser.Delay != "3s" || cfg.Client.Chaser.Spacing != "2s" {
		t.Errorf("shipped chaser numbers drifted from the flag defaults: %+v", cfg.Client.Chaser)
	}
	want := map[string]string{
		"record_toggle": "ctrl+shift+F9", "save_last": "ctrl+shift+F10", "replay_last": "ctrl+shift+F11",
		"replay_restart": "ctrl+shift+F5", "replay_rewind": "ctrl+shift+F6", "replay_fast_forward": "ctrl+shift+F7",
	}
	for k, v := range want {
		if cfg.Client.Hotkeys[k] != v {
			t.Errorf("shipped hotkeys.%s = %q, want the flag default %q", k, cfg.Client.Hotkeys[k], v)
		}
	}
}
