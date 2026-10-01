package cfg

import (
	"strings"
	"testing"
)

type replaySection struct {
	SaveLast *string `json:"save_last"`
	Folder   *string `json:"folder"`
}

type clientSection struct {
	Relay    *string        `json:"connect_to"`
	RoomCode *string        `json:"room_code"`
	Replay   *replaySection `json:"replay"`
	Features []string       `json:"features"`
	Internal *string        `json:"-"`
}

func TestAKeyThatIsNotASettingIsReported(t *testing.T) {
	raw := []byte(`{"connect_to":"1.2.3.4:7777","roomcode":"hunter2","min-send":"50ms"}`)
	out := captureLog(t, func() {
		WarnUnknownKeys(raw, clientSection{}, "C:\\x\\config.json", "meshghost", "client", nil)
	})
	if !strings.Contains(out, "roomcode") || !strings.Contains(out, "min-send") {
		t.Fatalf("both misspelled keys should be named, got:\n%s", out)
	}
	if strings.Contains(out, "connect_to\"") {
		t.Fatalf("a key that IS a setting was reported as unknown:\n%s", out)
	}
	// The message lists the accepted keys, so the player learns the right spelling.
	if !strings.Contains(out, "room_code") {
		t.Fatalf("the warning does not list the settings this section accepts:\n%s", out)
	}
}

func TestATypoInANestedSectionIsReportedWithItsPath(t *testing.T) {
	raw := []byte(`{"replay":{"save_lastt":"30s","folder":"r"}}`)
	out := captureLog(t, func() {
		WarnUnknownKeys(raw, clientSection{}, "cfg.json", "meshghost", "client", nil)
	})
	if !strings.Contains(out, "save_lastt") {
		t.Fatalf("a typo inside a nested section went unreported:\n%s", out)
	}
	if !strings.Contains(out, `"client.replay"`) {
		t.Fatalf("the warning does not name the section the typo is in:\n%s", out)
	}
}

// TestAFileWithNoMistakesSaysNothing: a warning on a correct file teaches a player to ignore the line.
func TestAFileWithNoMistakesSaysNothing(t *testing.T) {
	raw := []byte(`{"connect_to":"x","room_code":"y","features":["a"],"replay":{"folder":"r"}}`)
	out := captureLog(t, func() {
		WarnUnknownKeys(raw, clientSection{}, "cfg.json", "meshghost", "client", nil)
	})
	if out != "" {
		t.Fatalf("a valid config produced a warning:\n%s", out)
	}
}

func TestASkippedFieldIsNeverOfferedAsASetting(t *testing.T) {
	out := captureLog(t, func() {
		WarnUnknownKeys([]byte(`{"nope":1}`), clientSection{}, "cfg.json", "meshghost", "client", nil)
	})
	if strings.Contains(out, "Internal") {
		t.Fatalf("a json:\"-\" field was offered as a setting:\n%s", out)
	}
}

func TestItIsSilentOnWhatItCannotCheck(t *testing.T) {
	out := captureLog(t, func() {
		WarnUnknownKeys([]byte(`["not","an","object"]`), clientSection{}, "cfg.json", "meshghost", "client", nil)
		WarnUnknownKeys([]byte(`{"a":1}`), map[string]string{}, "cfg.json", "meshghost", "client", nil)
		WarnUnknownKeys([]byte(`not json at all`), clientSection{}, "cfg.json", "meshghost", "client", nil)
	})
	if out != "" {
		t.Fatalf("warned about something it cannot check:\n%s", out)
	}
}

// TestAKeyAnotherProgramOwnsIsNotReported: the game's mod reads keys from the same file, and calling one ignored sends
// a player hunting.
func TestAKeyAnotherProgramOwnsIsNotReported(t *testing.T) {
	raw := []byte(`{"connect_to":"1.2.3.4:7777","autostart":true,"roomcode":"hunter2"}`)
	out := captureLog(t, func() {
		WarnUnknownKeys(raw, clientSection{}, "cfg.json", "meshghost", "client",
			map[string]bool{"client.autostart": true})
	})
	if strings.Contains(out, "autostart") {
		t.Fatalf("a key declared as another program's was reported as a typo:\n%s", out)
	}
	// A declared key must not silence a real typo beside it.
	if !strings.Contains(out, "roomcode") {
		t.Fatalf("declaring one foreign key silenced a real typo beside it:\n%s", out)
	}
}

func TestAForeignSectionIsNotDescendedInto(t *testing.T) {
	raw := []byte(`{"replay":{"save_last":"30s","indicator":true,"indicator_color":"#EE4B2B"}}`)
	out := captureLog(t, func() {
		WarnUnknownKeys(raw, clientSection{}, "cfg.json", "meshghost", "client",
			map[string]bool{"client.replay.indicator": true, "client.replay.indicator_color": true})
	})
	if out != "" {
		t.Fatalf("a nested key another program owns was reported:\n%s", out)
	}
}

// TestAKeyInTheWrongCaseIsAppliedAndSoNotReported: encoding/json matches keys case-insensitively, so "Room_Code" is
// applied.
func TestAKeyInTheWrongCaseIsAppliedAndSoNotReported(t *testing.T) {
	type section struct {
		RoomCode string `json:"room_code"`
	}
	got := captureLog(t, func() {
		WarnUnknownKeys([]byte(`{"Room_Code": "x", "ROOM_CODE": "y"}`), section{}, "config.json", "test", "server", nil)
	})
	if got != "" {
		t.Fatalf("a wrong-case key was reported as unknown although the decoder applies it:\n%s", got)
	}
	got = captureLog(t, func() {
		WarnUnknownKeys([]byte(`{"room_cod": "x"}`), section{}, "config.json", "test", "server", nil)
	})
	if got == "" {
		t.Fatal("a genuine typo was not reported")
	}
}
