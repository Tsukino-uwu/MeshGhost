package main

import (
	"bytes"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/Tsukino-uwu/MeshGhost/internal/cfg"

	"github.com/Tsukino-uwu/MeshGhost/core"
	"github.com/Tsukino-uwu/MeshGhost/protocol"
	"github.com/Tsukino-uwu/MeshGhost/relay"
)

// shippedConfig is the shipped config.json, a second place every default lives: an explicit value there overrides
// the code default for every packaged player. Values that must track a code default are checked, so a change that
// forgets the file fails here; values that diverge on purpose are pinned with their reasons.
type shippedConfig struct {
	Client struct {
		ConnectTo             string  `json:"connect_to"`
		Transport             string  `json:"transport"`
		TLS                   *string `json:"tls"`
		TLSFingerprint        *string `json:"tls_fingerprint"`
		Room                  string  `json:"room_name"`
		Name                  string  `json:"player_name"`
		NameColor             string  `json:"player_name_color"`
		LocalGameBridge       string  `json:"local_game_bridge"`
		Interp                string  `json:"interp"`
		LocalInterp           string  `json:"local_interp"`
		Predict               string  `json:"predict"`
		GhostCollision        string  `json:"ghost_collision"`
		Offline               bool    `json:"offline"`
		MaxReceiveHzPerPlayer int     `json:"max_receive_hz_per_player"`
		Replay                struct {
			RecordOnLaunch bool   `json:"record_on_launch"`
			SaveLast       string `json:"save_last"`
			StartDelay     string `json:"start_delay"`
			Seek           string `json:"seek"`
			SplitTimes     bool   `json:"split_times"`
			Gzip           bool   `json:"gzip"`
			Delta          bool   `json:"delta"`
			Inputs         bool   `json:"inputs"`
		} `json:"replay"`
		InputDisplay struct {
			Player bool `json:"player"`
			Ghost  bool `json:"ghost"`
		} `json:"input_display"`
		Chaser struct {
			Enabled    bool   `json:"enabled"`
			Count      int    `json:"count"`
			Delay      string `json:"delay"`
			Spacing    string `json:"spacing"`
			Name       string `json:"name"`
			Color      string `json:"color"`
			Contact    string `json:"contact"`
			SpawnDelay string `json:"spawn_delay"`
		} `json:"chaser"`
		Hotkeys map[string]string `json:"hotkeys"`
	} `json:"client"`
	Server struct {
		ListenOn       string  `json:"listen_on"`
		Transport      string  `json:"transport"`
		TLS            *string `json:"tls"`
		MaxClients     int     `json:"max_clients"`
		SendHz         int     `json:"send_hz"`
		GhostCollision string  `json:"ghost_collision"`
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
	localInterp, err := time.ParseDuration(cfg.Client.LocalInterp)
	if err != nil {
		t.Fatalf("shipped local_interp %q does not parse: %v", cfg.Client.LocalInterp, err)
	}
	if localInterp != core.DefaultLocalGhostDelay {
		t.Errorf("shipped local_interp is %v but core.DefaultLocalGhostDelay is %v -- an explicit "+
			"value in config.json overrides the default, so a replay or chaser would be drawn %v "+
			"behind its own schedule no matter what the code says.",
			localInterp, core.DefaultLocalGhostDelay, localInterp)
	}
	if cfg.Client.Replay.Gzip {
		t.Error("shipped replay.gzip is true but core.New defaults it false -- a recording cut " +
			"short when the game closes is then refused whole by ordinary tools (ADR 0051)")
	}
	if !cfg.Client.Replay.Delta {
		t.Error("shipped replay.delta is false but core.New defaults it true -- a player would " +
			"write about four times more than they need to (agent_docs/scaling.md)")
	}
	// Shipped off, since the shipped client plays with other people; the key is present so a player can flip it.
	if cfg.Client.Offline {
		t.Error("shipped offline is true -- the shipped client would never contact a relay " +
			"and nobody would see anyone")
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
	// tls and tls_fingerprint are obsolete: a shipped "tls" would print a note on every launch, or at "auto" refuse
	// to start.
	if cfg.Client.TLS != nil || cfg.Client.TLSFingerprint != nil {
		t.Errorf("the shipped client section still carries tls/tls_fingerprint; both keys are obsolete")
	}
	if cfg.Server.TLS != nil {
		t.Errorf("the shipped server section still carries tls; the key is obsolete")
	}
}

// TestShippedConfigDeliberateDivergences pins where the release does not match a flag default, each with its reason. A
// failure is not necessarily a bug: read the reason and decide again.
func TestShippedConfigDeliberateDivergences(t *testing.T) {
	cfg := loadShippedConfig(t, filepath.Join("packaging", "release", "config.json"))

	// player_name_color: the flag defaults to blank, and the shipped file carries a real hex so a player sees what the
	// value looks like; a colour is ignored without a name.
	if cfg.Client.NameColor != "#A89975" {
		t.Errorf("shipped player_name_color should be the example hex #A89975, got %q", cfg.Client.NameColor)
	}
	// player_name: the shipped placeholder word teaches what the field wants and resolves back to blank; both halves
	// are pinned, or an unrecognised placeholder would be drawn over every new player's ghost.
	if cfg.Client.Name != namePlaceholder {
		t.Errorf("shipped player_name should be the placeholder %q, got %q", namePlaceholder, cfg.Client.Name)
	}
	if !isPlaceholderName(cfg.Client.Name) {
		t.Errorf("the client does not recognise the shipped player_name %q as a placeholder, so it "+
			"would be drawn as a real nametag", cfg.Client.Name)
	}
	// room_name: shipped blank so the file reads as something to fill in, and pinned with normalizeRoom, since an
	// empty room that did not normalize would be a separate room.
	if cfg.Client.Room != "" {
		t.Errorf("shipped room_name should be blank, got %q", cfg.Client.Room)
	}
	if normalizeRoom(cfg.Client.Room) != defaultRoom {
		t.Errorf("a blank shipped room_name resolves to %q, not the -room flag default %q",
			normalizeRoom(cfg.Client.Room), defaultRoom)
	}
	// listen_on: the -addr flag's 127.0.0.1 suits development, and a host must accept other machines.
	if cfg.Server.ListenOn != "0.0.0.0:7777" {
		t.Errorf("shipped listen_on should bind every interface for a host, got %q",
			cfg.Server.ListenOn)
	}
}

// TestShippedConfigNeverRecordsOrChasesBySurprise: a release never writes a file or spawns a chaser unless asked,
// contact ships off, and the hotkey chords match the flag defaults so the log, the README and the file agree.
func TestShippedConfigNeverRecordsOrChasesBySurprise(t *testing.T) {
	cfg := loadShippedConfig(t, filepath.Join("packaging", "release", "config.json"))
	if cfg.Client.Replay.RecordOnLaunch {
		t.Error("shipped replay.record_on_launch must be false: nobody's disk fills up by surprise")
	}
	if cfg.Client.Replay.Inputs {
		t.Error("shipped replay.inputs must be false: recording what the player pressed is a new " +
			"kind of artefact and ships off, like every other capability here")
	}
	if cfg.Client.InputDisplay.Player || cfg.Client.InputDisplay.Ghost {
		t.Errorf("shipped input_display must be off (player=%v ghost=%v): an overlay is opted into",
			cfg.Client.InputDisplay.Player, cfg.Client.InputDisplay.Ghost)
	}
	if cfg.Client.Replay.SplitTimes {
		t.Error("shipped replay.split_times must be false: a nametag that changes several times a second is opted into")
	}
	// Contact is the string "off", not false: the file is what a player copies from, so it shows the word to change.
	if cfg.Client.Chaser.Enabled || cfg.Client.Chaser.Contact != "off" {
		t.Errorf("shipped chaser must be off with contact \"off\", got enabled=%v contact=%q",
			cfg.Client.Chaser.Enabled, cfg.Client.Chaser.Contact)
	}
	if cfg.Client.Replay.SaveLast != "30s" || cfg.Client.Replay.Seek != "5s" || cfg.Client.Replay.StartDelay != "0s" {
		t.Errorf("shipped replay durations drifted from the flag defaults: %+v", cfg.Client.Replay)
	}
	// Blank name and colour: a chaser is you, so a tag over your own past is clutter.
	if cfg.Client.Chaser.Name != "" || cfg.Client.Chaser.Color != "" {
		t.Errorf("shipped chaser name/colour are %q/%q, want both empty -- a chaser ships unlabelled",
			cfg.Client.Chaser.Name, cfg.Client.Chaser.Color)
	}
	if cfg.Client.Chaser.Count != 1 || cfg.Client.Chaser.Delay != "3s" || cfg.Client.Chaser.Spacing != "2s" || cfg.Client.Chaser.SpawnDelay != "0s" {
		t.Errorf("shipped chaser numbers drifted from the flag defaults: %+v", cfg.Client.Chaser)
	}
	want := map[string]string{
		"record_toggle": "shift+4", "save_last": "shift+5", "replay_last": "shift+2",
		"replay_restart": "shift+F2", "replay_rewind": "shift+1", "replay_fast_forward": "shift+3",
	}
	for k, v := range want {
		if cfg.Client.Hotkeys[k] != v {
			t.Errorf("shipped hotkeys.%s = %q, want the flag default %q", k, cfg.Client.Hotkeys[k], v)
		}
	}
}

// TestShippedGhostCollisionStaysDisabled pins what the release ships in both blocks. The two values are asymmetric:
// "enabled" lets each adapter's default stand, while "disabled" binds every game, so flipping it would silently make
// ghosts solid for every player.
func TestShippedGhostCollisionStaysDisabled(t *testing.T) {
	cfg := loadShippedConfig(t, filepath.Join("packaging", "release", "config.json"))

	if cfg.Client.GhostCollision != "disabled" {
		t.Errorf("shipped client.ghost_collision is %q, want %q -- ADR 0035: \"disabled\" is the binding value, and it ships",
			cfg.Client.GhostCollision, "disabled")
	}
	if cfg.Server.GhostCollision != "disabled" {
		t.Errorf("shipped server.ghost_collision is %q, want %q -- this is the room policy the relay advertises",
			cfg.Server.GhostCollision, "disabled")
	}
}

// TestTheShippedPredictorIsWhatTheReleaseShips keeps shippedPredict, which the smoothing log line compares against, in
// step with the release; it diverges from the flag default, so it is pinned rather than tracked.
func TestTheShippedPredictorIsWhatTheReleaseShips(t *testing.T) {
	cfg := loadShippedConfig(t, filepath.Join("packaging", "release", "config.json"))
	if cfg.Client.Predict != string(shippedPredict) {
		t.Errorf("packaging/release/config.json ships predict %q, but shippedPredict is %q -- "+
			"the smoothing log line labels runs against the second one", cfg.Client.Predict, shippedPredict)
	}
}

// TestEachGameConfigCarriesOnlyItsOwnModKeys: a game's config carries only keys something in that game reads, or a
// player edits a setting to no effect. It pins stage-release.ps1's $gameOnly table, which no Go code otherwise
// touches, and skips in a clean checkout, where the per-game files (gitignored staging output) do not exist.
func TestEachGameConfigCarriesOnlyItsOwnModKeys(t *testing.T) {
	// key -> the one game whose mod reads it, by its folder under games/.
	owner := map[string]string{
		"map_markers":   filepath.Join("tevi"),
		"input_display": filepath.Join("pseudoregalia"),
	}
	games := map[string]string{
		"tevi":            filepath.Join("packaging", "release", "games", "tevi", "config.json"),
		"pseudoregalia":   filepath.Join("packaging", "release", "games", "pseudoregalia", "config.json"),
		"pokemon/emerald": filepath.Join("packaging", "release", "games", "pokemon", "emerald", "config.json"),
		"pokemon/crystal": filepath.Join("packaging", "release", "games", "pokemon", "crystal", "config.json"),
	}
	for game, rel := range games {
		t.Run(game, func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join("..", "..", rel))
			if err != nil {
				if os.IsNotExist(err) {
					t.Skipf("%s is staging output (gitignored); run dev-scripts/stage-release.ps1 to check it", rel)
				}
				t.Fatalf("reading %s: %v", rel, err)
			}
			var root map[string]json.RawMessage
			if err := json.Unmarshal(raw, &root); err != nil {
				t.Fatalf("%s does not parse: %v", rel, err)
			}
			var client map[string]json.RawMessage
			if err := json.Unmarshal(root["client"], &client); err != nil {
				t.Fatalf("%s has no readable \"client\" section: %v", rel, err)
			}
			for key, ownedBy := range owner {
				_, present := client[key]
				want := ownedBy == game
				if present && !want {
					t.Errorf("%s carries %q, which only %s's mod reads -- a player editing it here "+
						"gets no effect and no explanation. stage-release.ps1's $gameOnly strips it.",
						rel, key, ownedBy)
				}
				if !present && want {
					t.Errorf("%s is MISSING %q, which its own mod reads -- $gameOnly stripped it from "+
						"the game that owns it, or the key left the root config.json.", rel, key)
				}
			}
		})
	}
}

// TestShippedConfigsProduceNoUnknownKeyWarning: the shipped configs must not warn about their own keys, the ones read
// by the game's mod. Every shipped config is walked, since the per-game files carry keys the root does not.
func TestShippedConfigsProduceNoUnknownKeyWarning(t *testing.T) {
	shipped := []string{
		filepath.Join("packaging", "release", "config.json"),
		filepath.Join("packaging", "release", "games", "pokemon", "crystal", "config.json"),
		filepath.Join("packaging", "release", "games", "pokemon", "emerald", "config.json"),
		filepath.Join("packaging", "release", "games", "pseudoregalia", "config.json"),
		filepath.Join("packaging", "release", "games", "tevi", "config.json"),
	}
	for _, rel := range shipped {
		t.Run(rel, func(t *testing.T) {
			path := filepath.Join("..", "..", rel)
			raw, err := os.ReadFile(path)
			if err != nil {
				// The per-game files are gitignored staging output, absent in a clean checkout; their tracked
				// inputs are checked by TestConfigOverridesProduceNoUnknownKeyWarning.
				if os.IsNotExist(err) {
					t.Skipf("%s is staging output (gitignored); its tracked inputs are covered by "+
						"TestConfigOverridesProduceNoUnknownKeyWarning", rel)
				}
				t.Fatalf("reading %s: %v", path, err)
			}
			section := clientSection(raw)
			if section == nil {
				t.Fatalf("%s has no \"client\" section", rel)
			}
			out := captureLogForTest(t, func() {
				cfg.WarnUnknownKeys(section, fileConfig{}, rel, "meshghost", "client", notClientSettings)
			})
			if out != "" {
				t.Errorf("the shipped %s makes the client warn about its own keys:\n%s\n"+
					"Either the key is a real setting and belongs in fileConfig, or it is read by "+
					"the game's mod and belongs in notClientSettings.", rel, out)
			}
		})
	}
}

// TestConfigOverridesProduceNoUnknownKeyWarning checks the tracked inputs of the per-game files, the root
// config.json's "client" block with packaging/config-overrides/<game>.json merged over it, so CI sees the per-game
// keys. An override is a flat map of client keys; _comment keys are dropped, as staging drops them.
func TestConfigOverridesProduceNoUnknownKeyWarning(t *testing.T) {
	dir := filepath.Join("..", "..", "packaging", "config-overrides")
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("reading %s: %v", dir, err)
	}
	seen := 0
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".json" {
			continue
		}
		seen++
		t.Run(e.Name(), func(t *testing.T) {
			raw, err := os.ReadFile(filepath.Join(dir, e.Name()))
			if err != nil {
				t.Fatalf("reading %s: %v", e.Name(), err)
			}
			var all map[string]json.RawMessage
			if err := json.Unmarshal(raw, &all); err != nil {
				t.Fatalf("%s is not a JSON object: %v", e.Name(), err)
			}
			for k := range all {
				if strings.HasPrefix(k, "_comment") {
					delete(all, k)
				}
			}
			section, err := json.Marshal(all)
			if err != nil {
				t.Fatalf("re-marshalling %s: %v", e.Name(), err)
			}
			out := captureLogForTest(t, func() {
				cfg.WarnUnknownKeys(section, fileConfig{}, e.Name(), "meshghost", "client", notClientSettings)
			})
			if out != "" {
				t.Errorf("the shipped override %s makes the client warn about its own keys:\n%s\n"+
					"Either the key is a real setting and belongs in fileConfig, or it is read by "+
					"the game's mod and belongs in notClientSettings.", e.Name(), out)
			}
		})
	}
	if seen == 0 {
		t.Fatalf("no override files found in %s -- this test would pass by checking nothing", dir)
	}
}

func captureLogForTest(t *testing.T, fn func()) string {
	t.Helper()
	var buf bytes.Buffer
	oldOut, oldFlags := log.Writer(), log.Flags()
	log.SetOutput(&buf)
	log.SetFlags(0)
	defer func() { log.SetOutput(oldOut); log.SetFlags(oldFlags) }()
	fn()
	return buf.String()
}
