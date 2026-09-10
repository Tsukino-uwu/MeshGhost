# Troubleshooting

Work down this page in order — the causes at the top are far more common than the ones at the
bottom.

## First: read the log

Both programs write everything they print to a log file, so a window that closed too fast — or
that never existed, because your game started the client hidden — is never lost.

- **`meshghost.log`** (the client) is written next to whichever copy actually ran: the folder you
  unzipped for a client you started yourself, or **the game's own folder** for one a mod started
  for you.
- **`meshghost-server.log`** (the server) sits next to `meshghost-server.exe`.

Each run appends rather than replacing, so a crash from earlier is still there. Every run begins
with a `=== meshghost run start ===` line saying which executable it was, which folder it read its
config from, and whether a game started it or you did.

**Emerald and Crystal also print to BizHawk's Lua Console**, which is usually the quickest place to
look for those two.

Your "it worked" signal is a line reading `connected to relay ... in room ...`.

## Nothing happens — no ghosts at all

**Is anyone actually there?** MeshGhost with no server reachable is not an error. The game works
normally, the log says `playing alone -- no relay reached yet`, and it keeps retrying — so ghosts
appear by themselves the moment a server answers. Set `"offline": true` if you want it to stop
trying and stop mentioning it.

Then, in order:

1. **Check `connect_to` matches the host's real address exactly.** Typos here are the single most
   common cause of "nothing happens".
2. **Check everyone typed the same `room`.** You only ever see people in your room. It is
   case-sensitive.
3. **Check the host has their port open** — see [hosting.md](hosting.md). That is their setup, not
   yours. If one person can connect and another cannot, suspect the transport they are on: a
   player set to something the host has not forwarded just times out with nothing explaining it.
4. **Check the server window** on the host's machine — it should show your name joining.
5. **Check you loaded the mod from the right folder** under `games\`. For TEVI and Pseudoregalia,
   check you did the one-time copy of `meshghost.exe` **and** `config.json` into the game's own
   folder — their log names the exact folder it looked in.

## I edited `config.json` and nothing changed

Almost always: **you edited the wrong copy.**

Open `meshghost.log` and find the **`config loaded from ...`** line. It prints the full path of the
file it actually read. For TEVI and Pseudoregalia that is the copy in the game's folder, not the
one you unzipped; for Emerald and Crystal it is `games\pokemon\<game>\config.json`.

The other cause is a broken file. Only edit the text between the quotes — keep the quotes, colons
and commas exactly as they are. And save as plain **UTF-8**; saving as "Unicode"/UTF-16 makes the
file unreadable, and then **every** setting in it is ignored, not just the one you changed. The
log says so plainly when that happens.

Most settings apply about a second after you save the file, without a relaunch — the log names
every changed key and says what happened to it, including which ones need a relaunch.
[config.md](config.md) has the full list.

## My antivirus flagged `meshghost.exe`

It may, and it is a false positive. Both executables are unsigned Go programs, and scanners often
do not recognise the shape of Go binaries — Go's own FAQ says this is common and almost always
wrong. Microsoft Defender may show a name ending in `!ml`, which means a machine-learning guess
rather than a match against anything known.

1. **Verify the file is the one we published.** The Releases page shows a SHA-256 next to every
   download — GitHub computes it, not us. Run `Get-FileHash <file> -Algorithm SHA256` in
   PowerShell; if it matches, it is exactly what the public build produced.
2. **If it is specifically your game *starting* `meshghost.exe` that the scanner objects to**, that
   is a shape antivirus software watches for. Turn autostart off (below) and open the client
   yourself. Nothing is lost.
3. **If a file was already quarantined**, that looks identical to never having installed it — the
   mod's log will say it could not find `meshghost.exe`.
4. **Reporting it to your vendor as a false positive genuinely helps.** It is what Go's FAQ asks
   people to do, and it is the only thing that makes scanners stop.

[antivirus.md](antivirus.md) and [code-signing.md](code-signing.md) have the long version.

## Running the client yourself instead

Normally your game's mod starts the client hidden and closes it with the game. Running it yourself
is fully supported — not a debug mode — and is the answer whenever an antivirus objects, or when
you just want to watch the client's window.

Set `"autostart": false` in the `config.json` your game reads, then double-click `meshghost.exe`
before you start the game and close it after. The mod then starts nothing and simply uses whichever
client is already running.

**Keep `config.json` next to the exe.** The client reads the config in the folder it runs from, so
if you move the exe, move the config with it — they travel as a pair. Alone, the client falls back
to built-in defaults (`127.0.0.1:7777`, your own machine) and quietly never reaches your host.

For TEVI and Pseudoregalia you may not need the setting at all: the mod only starts a client
because you copied `meshghost.exe` into the game's folder. Do not copy it in, and there is nothing
to switch off. The setting matters most for Emerald and Crystal, where the script finds the client
in the unzipped folder whether you want it to or not.

*(The older `MESHGHOST_NO_AUTOSTART` environment variable still counts as "no" if you set one
years back. To be rid of it: Start → "environment variables" → Edit the system environment
variables → Environment Variables… → delete it under User variables.)*

## I want to watch it work

Set `"show_console": true` in the `config.json` your game reads, and the client a mod started gets
a real window with live output instead of running silently. Off by default on purpose.

For numbers rather than a feeling, start the client from a command prompt with `-stats`:

```text
meshghost.exe -stats=10s
```

Every 10 seconds it writes one summary line to the window and the log: your round-trip time to the
host, how many other players it knows about versus how many it is actually drawing, and bytes sent
and received with an hourly rate — which is the real answer to "how much data is this using",
measured on your own connection. It costs nothing when off.

Hosts have the matching switch, `meshghost-server.exe -introspect=30s` — see
[hosting.md](hosting.md).

## Two players on the same machine

Each copy needs its own local bridge port, and how it gets one depends on the game:

- **Emerald and Crystal** — nothing to do. Each BizHawk instance walks `127.0.0.1:7778-7785`
  looking for a free port, so a second emulator finds its own and starts its own client.
- **Pseudoregalia** — nothing to do either; its mod walks the same range.
- **TEVI** — the port lives in BepInEx's own config for that install
  (`BepInEx\config\dev.meshghost.tevi.cfg`, `[Network] BridgePort`), so two TEVI installs can be
  given different ones.

## Playing on Linux or macOS

The full zip is the Windows build. Native Linux and macOS builds of the **client and server** are
separate downloads on the same release page.

**You may well not need them.** Every game MeshGhost supports today is a Windows game, so on Linux
you are already running the game through Proton or Wine — and the Windows client runs there too,
inside the same prefix. For Pseudoregalia that happens by itself.

The native builds are worth grabbing when you want a real Linux or macOS process rather than a
Wine one — above all for **hosting**, since a server has no game attached and no reason to go
through Wine at all. That is the easy part. If you want a native client too, start it before
launching the game; Pseudoregalia's mod checks whether one is already running and uses it.

Mix freely: a Windows player, a Linux player and a macOS host are one ordinary session.

Two things to know under Proton/Wine:

- **`show_console` does nothing there.** Wine has no usable console window for a game launched
  this way, so none can appear whatever you set. The client says so in `meshghost.log`, which
  carries exactly the same output.
- **Running the client yourself is the more predictable choice**, since it does not depend on the
  game being able to launch a second program from inside the prefix.

MeshGhost exits with the game under Proton — confirmed on a real Linux setup 2026-08-16 across six
sessions, including when the game is killed outright rather than quit normally.

**The Pokémon adapters are not the exception they look like.** Emerald and Crystal are BizHawk Lua
scripts, and BizHawk itself runs natively on Linux and macOS — but the scripts reach the network
through a LuaSocket library shipped here as a **Windows** DLL, and there is no Linux or macOS build
of it in the package. Everything else about those scripts is portable; only the socket is not.
Running BizHawk through Proton/Wine is the only route with any chance of working today, and nobody
has tried it.

## Ghost collision

**Can you bump into a friend's ghost?** Sometimes, and it depends entirely on the game, because a
ghost is built differently in each one:

- **Pokémon Emerald and Crystal** — yes. A ghost there is a real character standing on a real
  tile, the same as any NPC, so it takes up space and you cannot walk through it. Crystal already
  gets out of your way on its own: a ghost that has not moved for a few seconds, or that you push
  against for a moment, becomes walk-through.
- **Pseudoregalia** — partly. The ghost is physically present, but reports so far are that it does
  not actually block you; what it does do is shove things around if you end up inside one.
- **TEVI** — no, never. That ghost is a picture with no physical presence at all.

`"ghost_collision": "disabled"` asks every game to stop doing any of it. The host sets it for the
whole server, and each player can also set it just for themselves; the strictest setting wins.

Three honest caveats:

- **No shipped mod acts on it yet (2026-09-08).** The setting travels the whole way — your client
  works out the answer and hands it to the game's mod — and then every shipped mod ignores the message.
  So setting it today changes nothing you can see: whether a ghost blocks you is still whatever
  the list above says. There is nothing to change on your end; the work is in each game's mod.
  This paragraph is what to re-read after an update to find out whether that is still true.
- **It is a request, not a rule the server can enforce**, and it stays one once the mods do act on
  it. The server has no idea what these games are or what collision means in them.
- **Turning it off is not free in the two Pokémon games.** Solidity there comes from the ghost
  being a real engine character, so the only way to make it non-solid is to draw it as an overlay
  instead — and an overlay does not get hidden behind buildings the way a real character does.
  Improving that is being worked on.

A **replay or chaser** ghost is meant to be just a picture — never solid, never harmful, whatever
`ghost_collision` says. Your client marks every one of them that way when it hands it to the game.

## Still stuck?

- [config.md](config.md) — every setting, its shipped value, and which program reads it.
- [security.md](security.md) — what is checked-safe and what is not.
- [reviewing.md](reviewing.md) — auditing the code yourself.
- Your game's own `README.txt` under `games\`, which has the per-game detail this page summarises.
