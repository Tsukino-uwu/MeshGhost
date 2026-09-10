# Getting started — playing with friends

This is everything that a player need to do. If you are the one **hosting** the server for your
group, do this page first anyway — a host is also a player — then read [hosting.md](hosting.md).

You need your own copy of the game. No games, ROMs or game files are included here, and never
will be.

---

## 1. Download and unzip

Go to the [Releases page](https://github.com/Tsukino-uwu/MeshGhost/releases) and download **`MeshGhost-full-<version>.zip`**. That is
the one nearly everyone wants: it has the client, the server, and the mod for every supported game.

Unzip it anywhere you like — Desktop is fine. Do not leave it inside the .zip and try to run it
from there; Windows will let you, and then nothing can find anything.

Inside you will find:

| | |
| --- | --- |
| `meshghost.exe` | The client. It runs quietly in the background while you play. **You do not open this yourself** — your game's mod starts it and closes it for you. |
| `meshghost-server.exe` | The server. Only the one person hosting ever touches this. |
| `config.json` | The settings file. You will edit three lines of it. |
| `games\` | One folder per supported game. Only your game's folder matters to you. |

## 2. Install your game's mod

Find your game below. Each one has its own `README.txt` in its folder with the full detail — this
is the short version.

**Pokémon Emerald** and **Pokémon Crystal** (`games\pokemon\emerald\`, `games\pokemon\crystal\`)

Nothing to install. You play these through the BizHawk emulator, and you load the mod fresh each
time: **Tools → Lua Console → Script → Open Script**, and pick `meshghost_emerald.lua` (or
`meshghost_crystal.lua`) from that folder. Leave the `lib\` folder next to it where it is.

Then copy **`meshghost.exe`** into that same folder, beside the script. (It also works left in the
folder you unzipped — the script checks its own folder first and falls back there — but keeping it
beside the script is the same rule every supported game follows, and it gives each game its own settings
and its own log.)

**TEVI** (`games\tevi\`)

Needs BepInEx 5.4.x, 64-bit, **Mono** build — not IL2CPP — from
[BepInEx's releases](https://github.com/BepInEx/BepInEx/releases). Unzip that into your TEVI folder
(the one with `TEVI.exe`), run TEVI once and close it, then drag the `MeshGhost` folder into
`BepInEx\plugins\`. Then copy **`meshghost.exe` and `config.json`** from the folder you unzipped
into your TEVI folder, next to `TEVI.exe`.

**Pseudoregalia** (`games\pseudoregalia\`)

Drag the `pseudoregalia` folder onto your Steam `Pseudoregalia` folder so the two merge, and say
yes when Windows asks about merging and replacing. Then copy **`meshghost.exe` and `config.json`**
into that same Pseudoregalia folder. Everything else it needs is already bundled. If you already
run other Pseudoregalia mods, read that folder's `README.txt` first — one paragraph, and it
matters.

> **One rule for every supported game: `meshghost.exe` and `config.json` travel as a pair, and the copy
> next to the mod is the one that counts.** Whichever folder you put them in is the folder
> MeshGhost reads its settings from and writes its log to — so that is the `config.json` you edit
> in step 3, not the one you unzipped.
>
> | Game | Where the pair goes |
> | --- | --- |
> | Pokémon Emerald | `games\pokemon\emerald\`, beside the script |
> | Pokémon Crystal | `games\pokemon\crystal\`, beside the script |
> | TEVI | your TEVI folder, next to `TEVI.exe` |
> | Pseudoregalia | your Pseudoregalia folder |
>
> Each game's `config.json` is already there — only `meshghost.exe` has to be copied in. The two
> Pokémon games are the forgiving ones: they fall back to the unzipped folder if you skip the
> copy. TEVI and Pseudoregalia do not, because the mod lives inside the game.

**Nothing here touches your save, and no ROM is patched.** Some mods put a ghost into the game's
live memory while you play, and that memory is gone the moment you close the game. Uninstalling is
deleting the mod's folder.

## 3. Fill in three things

Open the `config.json` in the folder from the table above — the one sitting next to your game's
mod. Notepad is fine.

In the `"client"` section near the top, set three things:

```json
"connect_to": "the host's address, which they will give you",
"room":       "a word your whole group agrees on",
"name":       "what you want on your nametag"
```

- **`connect_to`** — whoever is hosting gives you this. It looks like `203.0.113.40:7777`. The
  prefilled `127.0.0.1:7777` means "my own computer", so leave it only if you are also the host.
- **`room`** — any word, as long as everyone types the *same* word. You only ever see people in
  your room.
- **`name`** — optional. Blank means no nametag is drawn above your ghost.
- **`room_code`** — only if the host tells you they set one. Leave it empty otherwise.

Keep the quotes, colons and commas exactly as they are, or the file will not load. Save it as
plain UTF-8 — Notepad's default is right, so if you are not using Notepad, do not save it as
"Unicode".

Everything else in that file already ships at a sensible value. You do **not** set which game you
are playing — the mod says that itself.

## 4. Play

Just start your game. The mod starts MeshGhost for you with no window and closes it when you
quit — there is nothing to launch first, nothing to leave open, and no order to get right. (For
Emerald and Crystal, "start the game" means opening your ROM in BizHawk and loading the script as
in step 2.)

Walk around. Once a friend is on the same server in the same room, they appear as a ghost with
their real position, facing and animation.

**Your worlds stay separate.** No shared items, enemies, health or story progress. If a friend
beats a boss, it is still alive in your game.

## Did it work?

Your "it worked" signal is a line reading **`connected to relay ... in room ...`**:

- **Emerald / Crystal** — in BizHawk's Lua Console window.
- **TEVI / Pseudoregalia** — in `meshghost.log`.

`meshghost.log` is always written next to the `meshghost.exe` that ran, which is the folder from
the table above.

If you do not see a ghost, [troubleshooting.md](troubleshooting.md) goes through the usual causes
in order. Nine times in ten it is a typo in `connect_to`, or the host's port not being open.

## No server? It still works

You do not need anyone else to use MeshGhost. With no server running, the game plays normally and
you can:

- **Record yourself** — `ctrl+shift+F9` starts and stops. Recordings land in the `replay` folder.
- **Race your own ghost** — drop a recording into `replay\active\` and it plays back beside you
  next time you play. Take it out to stop.
- **Turn on the chaser** — a ghost of you from a few seconds ago, tailing you as you play. Needs
  no file at all: set `"enabled": true` under `"chaser"`.

Emerald and Crystal do not do replays or chasers yet (as of 2026-09-08); TEVI and Pseudoregalia
do. The knobs for all of this are in [config.md](config.md) under `replay` and `chaser`.

## Where to go next

- **[hosting.md](hosting.md)** — you are the one running the server for your group.
- **[troubleshooting.md](troubleshooting.md)** — it did not work, or something looks wrong.
- **[config.md](config.md)** — every setting in `config.json`, what it does, and who reads it.
- **[antivirus.md](antivirus.md)** — your antivirus flagged one of the two `.exe` files.
