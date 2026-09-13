package main

import (
	"strings"
	"testing"
	"time"
)

// identityTargets is a full configTargets whose three identity settings are
// readable afterwards, plus the replay and chaser names that must NOT follow
// them. Every field is passed for the reason applyTestConfigWithTLS gives: a
// nil target is a nil dereference the moment the file sets that key.
type identity struct {
	room, name, nameColor         string
	replayName, replayColor       string
	chaserName, chaserColor       string
	relayAddr, bridgeAddr, gameID string
	roomCode, gameVersion         string
	features, transport           string
	tlsMode, tlsPin, curve        string
	predict, ghostCollision       string
	interp, minSend               time.Duration
	maxReceiveHz                  int
	showConsole                   bool
}

func (id *identity) targets() configTargets {
	return configTargets{
		relayAddr: &id.relayAddr, bridgeAddr: &id.bridgeAddr, gameID: &id.gameID,
		room: &id.room, name: &id.name, nameColor: &id.nameColor,
		interp: &id.interp, minSend: &id.minSend, roomCode: &id.roomCode,
		gameVersion: &id.gameVersion, maxReceiveHz: &id.maxReceiveHz,
		curve: &id.curve, predict: &id.predict, ghostCollision: &id.ghostCollision,
		transport: &id.transport, tlsMode: &id.tlsMode, tlsPin: &id.tlsPin,
		showConsole: &id.showConsole, features: &id.features,
		replayName: &id.replayName, replayColor: &id.replayColor,
		chaser: &chaserTargets{name: &id.chaserName, color: &id.chaserColor},
	}
}

// resetIdentityNotices lets a test see the once-per-process lines. They are
// package-level so a reload does not repeat them at a player; a test that ran
// after another would otherwise assert on a line that was already spent.
func resetIdentityNotices(t *testing.T) {
	t.Helper()
	loggedRoomDefault, loggedPlaceholderName = false, false
	t.Cleanup(func() { loggedRoomDefault, loggedPlaceholderName = false, false })
}

// AN OLD SPELLING STILL WORKS AND SAYS SO. This is the whole reason the rename
// shipped with an alias: without it, "room" became an unknown key, the player
// fell back to "default" -- a real room, just not their friends' -- and the only
// clue was a line telling them the key was not a setting.
func TestOldClientKeysStillApplyAndSaySo(t *testing.T) {
	resetIdentityNotices(t)
	path := writeConfig(t, nil, `{"client": {"room": "castle", "name": "me", "name_color": "#F00"}}`)
	var id identity
	out := captureLogForTest(t, func() { loadClientConfig(path, map[string]bool{}, id.targets()) })

	if id.room != "castle" || id.name != "me" || id.nameColor != "#F00" {
		t.Fatalf("an old config stopped applying: room=%q name=%q colour=%q", id.room, id.name, id.nameColor)
	}
	for _, want := range []string{"room_name", "player_name", "player_name_color"} {
		if !strings.Contains(out, want) {
			t.Errorf("the log does not tell the player to rename the key to %q:\n%s", want, out)
		}
	}
	if strings.Contains(out, "are not settings") {
		t.Errorf("an aliased key was ALSO reported as a typo, which is the opposite of reassuring:\n%s", out)
	}
}

// WHEN A FILE CARRIES BOTH SPELLINGS the current one wins -- the shape a player
// ends up with after copying a fresh shipped config and pasting their old value
// in beside it.
func TestTheCurrentSpellingWinsOverTheOldOne(t *testing.T) {
	resetIdentityNotices(t)
	path := writeConfig(t, nil, `{"client": {"room": "old", "room_name": "new"}}`)
	var id identity
	out := captureLogForTest(t, func() { loadClientConfig(path, map[string]bool{}, id.targets()) })
	if id.room != "new" {
		t.Errorf("room = %q, want the current spelling's value", id.room)
	}
	if !strings.Contains(out, "both") {
		t.Errorf("the player is not told their file carries both spellings:\n%s", out)
	}
}

// AN EMPTY ROOM IS THE DEFAULT ROOM, not a different one. Before this, a blank
// room_name was a real room of its own: two players whose files differed only in
// blank-versus-"default" silently never met, and the relay cannot tell the two
// apart either, since it keys rooms on whatever string it is handed.
func TestAnEmptyRoomNameIsTheDefaultRoom(t *testing.T) {
	resetIdentityNotices(t)
	path := writeConfig(t, nil, `{"client": {"room_name": "   "}}`)
	var id identity
	out := captureLogForTest(t, func() {
		loadClientConfig(path, map[string]bool{}, id.targets())
		// Twice: the file is re-read on every save, and a line repeated on each
		// one is a line people stop reading.
		loadClientConfig(path, map[string]bool{}, id.targets())
	})
	if id.room != defaultRoom {
		t.Fatalf("a blank room_name left the room as %q, want %q", id.room, defaultRoom)
	}
	if n := strings.Count(out, "default room"); n != 1 {
		t.Errorf("the default-room notice appeared %d time(s) across two reads, want exactly 1:\n%s", n, out)
	}
}

// THE SHIPPED PLACEHOLDER IS NOT A NAME. It ships so the file teaches what the
// field wants; drawing it would label every player who has not edited the file
// "nickname".
func TestThePlaceholderPlayerNameIsUnset(t *testing.T) {
	for _, spelling := range []string{"nickname", "Nickname", "NICKNAME", "  nickname  "} {
		t.Run(spelling, func(t *testing.T) {
			resetIdentityNotices(t)
			path := writeConfig(t, nil, `{"client": {"player_name": "`+spelling+`"}}`)
			var id identity
			out := captureLogForTest(t, func() { loadClientConfig(path, map[string]bool{}, id.targets()) })
			if id.name != "" {
				t.Errorf("player_name %q was kept as %q, so it would be drawn over the ghost", spelling, id.name)
			}
			if !strings.Contains(out, "placeholder") {
				t.Errorf("nothing told the player why they have no nametag:\n%s", out)
			}
		})
	}
}

// A REAL NAME THAT MERELY RESEMBLES THE PLACEHOLDER IS A REAL NAME. The
// sentinel is one exact word, and the cost of it being a word at all is that
// this line has to hold.
func TestANameThatIsNotThePlaceholderSurvives(t *testing.T) {
	resetIdentityNotices(t)
	path := writeConfig(t, nil, `{"client": {"player_name": "Nickname!"}}`)
	var id identity
	loadClientConfig(path, map[string]bool{}, id.targets())
	if id.name != "Nickname!" {
		t.Errorf("player_name = %q, want the name the player actually typed", id.name)
	}
}

// THE PLACEHOLDER MUST NOT LEAK INTO THE OTHER TWO NAMES IN THE SAME FILE.
// replay.name labels a recording and chaser.name labels a chaser; they share a
// word with the player's nametag and mean something else. This also catches an
// alias shim that recursed into the nested sections.
func TestThePlaceholderDoesNotLeakIntoReplayOrChaserNames(t *testing.T) {
	resetIdentityNotices(t)
	path := writeConfig(t, nil,
		`{"client": {"player_name": "nickname", "replay": {"name": "nickname"}, "chaser": {"name": "nickname"}}}`)
	var id identity
	loadClientConfig(path, map[string]bool{}, id.targets())
	if id.name != "" {
		t.Errorf("the player's own name = %q, want it treated as unset", id.name)
	}
	if id.replayName != "nickname" || id.chaserName != "nickname" {
		t.Errorf("a nested name was changed: replay.name=%q chaser.name=%q, want both left alone",
			id.replayName, id.chaserName)
	}
}

// A BLANK ROOM MUST NOT READ AS A CHANGE ON THE NEXT SAVE. Room is deliberately
// relaunch-only, so if only one of startup and reload resolved the blank, the
// first save of any other key would report "needs the client relaunched" for a
// room nobody touched.
func TestABlankRoomIsNotAChangeWhenTheFileIsSavedAgain(t *testing.T) {
	resetIdentityNotices(t)
	path := writeConfig(t, nil, `{"client": {"room_name": "", "interp": "450ms"}}`)
	var startup identity
	loadClientConfig(path, map[string]bool{}, startup.targets())

	var next identity
	loadClientConfig(path, map[string]bool{}, next.targets())
	if startup.room != next.room {
		t.Fatalf("the same file read twice gave two rooms: %q then %q -- a reload would report a "+
			"change and ask for a relaunch", startup.room, next.room)
	}
}
