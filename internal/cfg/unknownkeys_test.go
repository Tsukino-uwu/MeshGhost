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

// A MISSPELLED KEY MUST SAY SO. It parses, it is ignored, and the setting the
// player thought they changed is still at its default -- which is the same cost
// as a wrongly-typed value, a class this package already warns about and which
// is on record as having cost a tester their room code.
func TestAKeyThatIsNotASettingIsReported(t *testing.T) {
	raw := []byte(`{"connect_to":"1.2.3.4:7777","roomcode":"hunter2","min-send":"50ms"}`)
	out := captureLog(t, func() {
		WarnUnknownKeys(raw, clientSection{}, "C:\\x\\config.json", "meshghost", "client")
	})
	if !strings.Contains(out, "roomcode") || !strings.Contains(out, "min-send") {
		t.Fatalf("both misspelled keys should be named, got:\n%s", out)
	}
	if strings.Contains(out, "connect_to\"") {
		t.Fatalf("a key that IS a setting was reported as unknown:\n%s", out)
	}
	// The message has to say what the accepted keys are, or the player is told
	// they made a mistake and not what the right spelling was.
	if !strings.Contains(out, "room_code") {
		t.Fatalf("the warning does not list the settings this section accepts:\n%s", out)
	}
}

// A TYPO INSIDE A NESTED SECTION IS EXACTLY AS SILENT, so it gets the same
// treatment -- and the section is named, because "save_lastt" means nothing
// without knowing which object it was in.
func TestATypoInANestedSectionIsReportedWithItsPath(t *testing.T) {
	raw := []byte(`{"replay":{"save_lastt":"30s","folder":"r"}}`)
	out := captureLog(t, func() {
		WarnUnknownKeys(raw, clientSection{}, "cfg.json", "meshghost", "client")
	})
	if !strings.Contains(out, "save_lastt") {
		t.Fatalf("a typo inside a nested section went unreported:\n%s", out)
	}
	if !strings.Contains(out, `"client.replay"`) {
		t.Fatalf("the warning does not name the section the typo is in:\n%s", out)
	}
}

// A CORRECT FILE MUST BE SILENT. A warning a player sees on a file with nothing
// wrong with it teaches them to ignore this line, which costs the case it
// exists for.
func TestAFileWithNoMistakesSaysNothing(t *testing.T) {
	raw := []byte(`{"connect_to":"x","room_code":"y","features":["a"],"replay":{"folder":"r"}}`)
	out := captureLog(t, func() {
		WarnUnknownKeys(raw, clientSection{}, "cfg.json", "meshghost", "client")
	})
	if out != "" {
		t.Fatalf("a valid config produced a warning:\n%s", out)
	}
}

// A json:"-" FIELD IS NOT A SETTING, so naming it in the accepted list would be
// advertising a key that does nothing.
func TestASkippedFieldIsNeverOfferedAsASetting(t *testing.T) {
	out := captureLog(t, func() {
		WarnUnknownKeys([]byte(`{"nope":1}`), clientSection{}, "cfg.json", "meshghost", "client")
	})
	if strings.Contains(out, "Internal") {
		t.Fatalf("a json:\"-\" field was offered as a setting:\n%s", out)
	}
}

// WHAT IT MUST NOT DO IS COMPLAIN ABOUT SOMEONE ELSE'S FILE. Every caller
// scopes this to a section it owns; handed something it cannot check -- a
// non-object, a type that is not a struct -- it stays quiet, because being
// unable to check is not evidence of a mistake.
func TestItIsSilentOnWhatItCannotCheck(t *testing.T) {
	out := captureLog(t, func() {
		WarnUnknownKeys([]byte(`["not","an","object"]`), clientSection{}, "cfg.json", "meshghost", "client")
		WarnUnknownKeys([]byte(`{"a":1}`), map[string]string{}, "cfg.json", "meshghost", "client")
		WarnUnknownKeys([]byte(`not json at all`), clientSection{}, "cfg.json", "meshghost", "client")
	})
	if out != "" {
		t.Fatalf("warned about something it cannot check:\n%s", out)
	}
}
