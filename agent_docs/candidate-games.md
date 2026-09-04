# Candidate games and prior-art reads — nothing checked, nothing scheduled

**What this is.** Games that might get an adapter one day, and other projects read for prior art, with
whatever was found out at the time. Every entry says how much was actually checked, which is usually
nothing. Moved out of `ideas.md` on 2026-09-02 for findability. **Reference projects named here have
NOT had their licences checked** — the user's call for brainstorm material; `licensing.md`'s gate
exempts this file, and the moment an adapter for one of these starts, `/new-adapter` sends you to
`access-models.md` and `licensing.md` first.

## Index

- Super Mario Sunshine (GameCube, Dolphin) — candidate adapter, nothing checked yet
- Carrion (MonoGame, PC) — candidate adapter, and possibly this project's first tier-1 game
- Super Metroid (SNES): a starting memory map, filed 2026-08-18
- osu! — online co-op, "tag co-op without the tag", filed 2026-08-19
- Dark Souls 3 / Elden Ring — full online sync, filed 2026-08-19
- ROM hacks and randomizers worth supporting — candidate list, NOTHING CHECKED (2026-08-19)
- Pikmin 1 and 2 (GameCube) — a possible next adapter
- Super Mario Odyssey Online — a prior art read, not a target
- Super Metroid (SNES) — two reference projects, filed UNREAD — 2026-08-23
- Ori (Blind Forest / Will of the Wisps) — candidate adapter, neither title owned
- Two Ori randomizer clients, parked for later (filed 2026-08-30, NOTHING CHECKED)

---

## Super Mario Sunshine (GameCube, Dolphin) — candidate adapter, nothing checked yet

**Status: named as a candidate 2026-08-17, zero investigation done.** Recorded so the idea is not
re-derived from scratch, and so the checks below happen in the right order. Everything here is a
question, not a finding.

**Why it is a plausible fit.** It is a single-player 3D platformer, which is the exact shape
MeshGhost already handles — a position, an orientation, and an animation tag per player, with
independent worlds and desync expected. Nothing about it needs the planes past cosmetic. And it
has a large, long-lived speedrunning community, which is the thing that most often means
addresses are already documented: practice tools for a speedgame generally read position, state
and timers, and that work is exactly what a tier-2 lookup needs.

**Presence is a genuinely good pitch for a speedgame specifically.** Two people doing separate
runs and seeing each other's ghost is close to what a race already is, and it is the one thing
Dolphin's own lockstep netplay cannot deliver, because netplay is a single shared session. See
`access-models.md`'s emulator section for that distinction — it is the difference between a
different product and a worse one.

**The blocker is inherited and it is not about this game.** Per that same section, Dolphin looks
like solved reading and **no drawing API**. So an SMS adapter is gated on the rendering question
for Dolphin — hook its renderer, an external overlay, or a fork with GPL obligations — regardless
of how well documented the game itself turns out to be. **Answer that before spending any time on
the game**, or you end up with an adapter that can read perfectly and cannot show anything.

**Checks to run, in this order, before treating this as real work:**

1. **Prior art — two candidates already found, neither examined.** Supplied 2026-08-17 and
   deliberately **not opened**, so nothing below is a claim about them:
   - <https://gamebanana.com/mods/697699>
   - <https://github.com/TheAzack9/SMSCoop>

   **A third, supplied 2026-09-04 and also not opened:**
   - <https://github.com/Daytendo64/Better-Super-Mario-Sunshine-Online-BSMSO->

   The user's read of it: *"looks like super mario sunshine already have a proper online mod"*.

   **LICENCE CHECKED 2026-09-04 — GPL-3.0**, by reading the repo's own `LICENSE`, and it now has a
   `licensing.md` row. It builds on
   <https://github.com/DotKuribo/BetterSunshineEngine> (user's read: *"the online mod is using this
   ... for actually working i think"*), also **GPL-3.0**, also checked and rowed. No source of
   either has been opened.

   **The first question to take to prior art here is "where does it RUN and how does it DRAW",
   never "what does it sync"** — drawing is this entry's recorded blocker, and an online mod that
   shows other players has by definition solved it. **On the metadata alone, the answer looks like
   the door this project has closed.** BetterSunshineEngine describes itself as *"a modification of
   the SMS engine"* and ships C++/C with **Assembly and a linker script** — the shape of code built
   for the console and injected into the game, not an emulator plugin. If that holds, the mechanism
   is a game-side patch, and `CLAUDE.md`'s "nothing that ships writes a save, game state, or a ROM
   patch — ever" rules it out however well it works. That is an inference from metadata and the
   repo's own description, not a measurement — but it is the cheap check, and it points the
   opposite way from how this was first filed earlier the same day (2026-09-04).

   **So the Dolphin drawing question in step 2 is NOT answered by this**, and may even be
   reinforced: the working precedent went around the emulator rather than through it.

   **PRIORITY, the user's call 2026-09-04:** *"guess it also means it won't be any priority for us
   as it already has online"*. Agreed and recorded. The one caveat worth keeping next to it, not as
   an argument against: an existing online mod deprioritises this only insofar as it delivers the
   same thing, and this entry's own pitch was presence between INDEPENDENT runs, which is a
   different product from co-op — the same distinction `access-models.md` draws about Dolphin
   netplay. Nobody has checked which BSMSO is.

   **Unknown for all three: whether they work, what state they are in, what they actually do
   (co-op? presence? lockstep?).** The two 2026-08-17 links have no `licensing.md` row, so
   under this repo's standing rule **neither may be read as a reference until its licence has
   been checked** — and the check reads the project's own `LICENSE` file, not a GitHub badge,
   per the Archipelago and GBA-PK entries where badge and file disagreed. If any turns out
   to be a real working co-op mod, that is both a source of facts and a reason to revisit the
   pitch, since "presence between independent runs" is a different product from co-op and the
   difference should be stated rather than assumed.
2. **The Dolphin drawing question** (the blocker above). Nothing else matters until it has an
   answer.
3. **Does a decompilation or a documented address set exist** for SMS — decomp project, practice
   tool source, speedrun community documentation? That decides whether the per-game half is a
   lookup (tier 2, like Emerald) or a differential hunt (tier 8).
4. **Only then** the ordinary adapter questions: which field is position, which is orientation,
   what stands in for an animation tag.

**Not scheduled, and downstream of an emulator decision rather than a game one.** If an emulator
adapter is ever built, the emulator is chosen first and the game second — and `access-models.md`
argues Dolphin is the strongest candidate of the emulators surveyed.

## Carrion (MonoGame, PC) — candidate adapter, and possibly this project's first tier-1 game

**Status: surfaced 2026-08-17 as a side-track while scoping Crystal, parked immediately.** Two
public sources were read (the wiki's modding guide and the Workshop item below); the game itself
has **not** been opened, no binary inspected, and nothing here is a runtime finding.

**Why it stands out: it appears to have real, first-party mod support.** Per
<https://carrion.wiki.gg/wiki/Guide:Modding>, Carrion ships a **Mod Loader** driven by project
directories — the game looks in `UserContent\<projectname>` before `Content`, so levels, scripts,
templates, audio and textures all override by path. And **Carrion Dev Tools**
(<https://steamcommunity.com/sharedfiles/filedetails/?id=2258772789>) is published by the game's own
developers, described there as "an essential selection of tools used by the developers of Carrion to
build the base game's content" — not a community reverse-engineering effort.

If that holds up, it is **approach 1 in `access-models.md`, which is currently an empty row** — no
game this project has touched has had official mod support. It also has a tier-3 fallback beneath
it: the engine is custom but built on **MonoGame**, i.e. .NET/C#, so the game assembly should be
managed and readable with ILSpy exactly as TEVI's `Assembly-CSharp.dll` was.

**The catch, and it is the thing to check first: the mod loader may be the wrong door entirely.**
An adapter needs two capabilities — a socket to its local core (the bridge) and a way to draw an
overlay. A **content-override** system gives assets and scripts, neither of which is obviously
either one. So the likely real route is the TEVI shape, a .NET loader, and the question that
decides the whole approach is **whether BepInEx (or an equivalent) supports non-Unity MonoGame
games**. Unanswered; do not assume it from BepInEx's Unity support.

**Checks to run, in this order:**

1. **The loader question above.** Nothing else matters until it has an answer, the same way the
   Dolphin drawing question gates Sunshine below.
2. **What the scripting system can actually do** — is it sandboxed content scripting, or can it
   reach a socket and draw? If it can do both, the adapter gets radically simpler and the
   dependency story is the cleanest this project has ever had.
3. **What kind of binary it is**, per `access-models.md`'s "how to find out" list — MonoGame is
   .NET, but confirm managed rather than AOT/obfuscated before relying on it.
4. **Only then** the ordinary adapter questions: position, orientation, what stands in for an
   animation tag.

**Licensing, checked 2026-08-17 so it doesn't gate later work:**

- **`xnbcli`** (<https://github.com/LeonBlade/xnbcli>) is **GPL-3.0**, via `gh api`. The wiki marks
  it "not required". Treat as a **read-only local tool at most, never a dependency and never
  vendored** — the same posture as ILSpy, but with copyleft terms that make the "never vendored"
  half load-bearing rather than incidental. It has no `licensing.md` row yet; add one before it is
  used for anything.
- **Nothing else here has been licence-checked**, including the Dev Tools item. The standing rule
  applies: no project may be read as a reference until its licence has been.

**The usual asset line applies and is worth stating for this game specifically**, since the whole
mod system is asset overrides: extracted `.xnb` content is game assets, so **none of it may ever be
committed**, the same as ROMs and sprites. A Carrion adapter would be our own code plus, at most, a
runtime read of the user's own installed files.

**Not scheduled.** The install lives under the ordinary Steam library path (`steamapps\common\Carrion`).

## Super Metroid (SNES): a starting memory map, filed 2026-08-18

**Status: filed only. Nothing is planned, scheduled or begun** — this is not a phase and there is
no adapter. Recorded here because a cheat list for a game with no decompilation is an accidental
partial memory map, and that is the expensive thing to obtain later.

The user supplied a large Game Genie + Pro Action Replay list. The two formats are not equally
useful and the difference is the point:

- **Pro Action Replay codes are plain RAM writes.** SNES PAR is `AAAAAADD` — a 24-bit address and
  a byte, no encryption. All 45 codes below decode into `0x7E0000`-`0x7FFFFF`, which is SNES WRAM,
  so each one names **an address the game keeps live state in**. Same situation as Crystal's GB
  GameShark codes, and the opposite of Emerald's GameShark v3 / CodeBreaker codes, which are
  encrypted and turned out to be unusable (`pitfalls.md`).
- **Game Genie codes are ROM patches**, with address and value scrambled through a letter
  alphabet. They patch code, not state, so they are useless as a memory map and unusable by the
  approach every adapter here takes. Their *names* are still informative about what the engine has
  a switch for — walk through walls, disable water physics, all doors open — but nothing more.
- **Six PAR codes in the list address ROM banks, not WRAM** (`90BEBFA7`, `90BE6FAD`, `90BEC4AD`,
  `90C02DEA`, `81A81A00`, `81A8AF80`). Those are code patches wearing PAR clothing; they are not
  part of the table below.

### Decoded addresses (WRAM), from the PAR list

| Address | Value | Cheat it came from |
| --- | --- | --- |
| `0x7E05B6` | `0xFF` | Invulnerability |
| `0x7E0945`-`0x7E0947` | `00/00/01` | Escape timer |
| `0x7E09A2` / `0x7E09A4` | `04`, `16` | Morph Ball; Morph+Bomb+Spring |
| `0x7E09A3` / `0x7E09A5` | `10` | Bomb |
| `0x7E09A6` / `0x7E09A8` | `04`, `16` | Spazer; Spazer+Ice |
| `0x7E09A7` / `0x7E09A9` | `10` | Charge Beam |
| `0x7E09C2` | `0x63` | Energy |
| `0x7E09C4` / `0x7E09C5` | `78`, `05` | Tanks |
| `0x7E09C6` / `0x7E09C7` | `E7`, `03` | Missiles |
| `0x7E09C8` | `01` | Have Missiles |
| `0x7E09CA` / `0x7E09CC` | `50`, `01` | Super Missiles |
| `0x7E09CE` / `0x7E09D0` | `50`, `01` | Power Bombs |
| `0x7E09D1` | `0x64` | Bombs at start / Reserve Tank |
| `0x7E09D6` / `0x7E09D7` | `90`, `01` | Reserve Energy |
| `0x7E0A6E` | `02`, `0F` | Hyper Run; kill-on-contact |
| `0x7E0ACC` | `01` | Permanent super charge |
| `0x7E0B2D` / `0x7E0B2E` | `44`, `01` | Moon Jump |
| `0x7E0B3F` | `04` | Hyper Run |
| `0x7E0CD2` | `00` | Bomb lay rate |
| `0x7E100D` | `00` | Metroid health |
| `0x7E18A8` | `4C`, `FF` | Untouchable / invulnerable |
| `0x7ED908`-`0x7ED90D` | `FF` | Map explored bits, one byte per area: Crateria, Brinstar, Norfair, Wrecked Ship, Maridia, Tourian |

### What is worth noticing, and what is only a guess

- **`0x7ED908`-`0x7ED90D` is one byte per area, in area order.** That is the closest thing here to
  an `area_id`, which is the first field any adapter needs. Strong lead, still unverified.
- **The a/b pairs two bytes apart** (`09C4`/`09C5`, `09C6`/`09C7`, `09A2`/`09A4`) look like
  current/maximum and equipped/collected pairs — a normal layout, and consistent with what the
  cheats are named. **This is an inference from the shape of the list, not a measured fact**, and
  it is exactly the kind of tidy-looking guess this project treats as invented until confirmed
  against a running game.
- **Position is absent.** Nothing here gives Samus's X/Y, which is the one field a cosmetic ghost
  cannot do without. A cheat list only covers what people wanted to cheat at, so the most
  important address for us is the one it will never contain.

### If this is ever picked up

It would be a new phase with a new phase file, and the standing rules apply before any code:
read `adapters/_template/README.md` end to end, establish the access model
(`access-models.md` — SNES has no decompilation of the quality `pokeemerald`/`pokecrystal` have,
so this is a harder tier than either Pokémon game), and check the licence of any reference project
**before** reading its source (`licensing.md`). The BizHawk toolchain transfers unchanged: the dev
loader, the syntax checker, the probe conventions, and the spawn-versus-draw question in the same
form. What does not transfer is the address source — every address would have to be measured
live, which is precisely why this list was worth recording.

---

## osu! — online co-op, "tag co-op without the tag", filed 2026-08-19

**The idea.** osu!'s existing multi mode has *Tag Co-op*: players share one beatmap and one combo,
but they alternate — one person plays a section, then hands off. The idea here is Tag Co-op
**without the taking turns**: everyone plays the same map at the same time, on the same objects,
sharing one score/combo, so a note anyone hits counts once for the group. In Tag Co-op only one
player can "click" a circle at any moment; here everyone plays the whole map at once.

**Two possible homes, undecided.** Either **inside the multiplayer lobby**, where it would be
picked from the same list as Standard and Tag Co-op and simply lets everyone play at once — the
tidier fit, since the lobby already exists to hold a shared map and a shared result. Or **on top
of normal singleplayer**, which is where MeshGhost's other adapters live. **If it is the
singleplayer route it must be an unranked mod** — a play with other people in it is not a solo
score and must never be submitted as one. Deciding between the two is the first thing to settle,
because it decides everything else: the lobby route is a mode inside the game's own multiplayer,
the singleplayer route is an adapter in this project's usual shape.

**Where it lands.** Not Tier 0 — a shared combo is shared *state*, and whether a note is hit is a
gameplay outcome, not a cosmetic one. Two honest reads of the tier: presenting each other's
cursors and hit results as decoration on top of an otherwise-normal solo play is Tier 1-2, and
actually letting one player's hit satisfy an object for everybody is Tier 3, the cliff. Only the
first is anywhere near what MeshGhost promises today.

**What's unknown and would have to be checked first**, in order:
- osu!'s access model (`access-models.md`) — osu!(lazer) is open source, osu!(stable) is not,
  and which one this targets changes the entire difficulty question. Read the licence before
  reading anything else (`licensing.md`).
- Whether an adapter can observe hit events at all without writing anything, since the cosmetic
  version of this needs only that.
- Whether the game already refuses to run modified clients online, which is a policy question,
  not a technical one, and could make the whole entry moot for anything touching osu!'s own
  servers. A purely local/offline arrangement is the version that stays inoffensive.

**Not scheduled.** Filed as a game candidate plus a mode idea; nothing checked yet.

## Dark Souls 3 / Elden Ring — full online sync, filed 2026-08-19

**The idea.** Not ghosts: real shared-world play — the same enemies, the same bosses, the same
world, several players in it at once, without the host/summon model the games ship with.

**This is the far end of the ladder** — Tier 3 and past it, for every subsystem at once
(enemy state, boss state, damage, death, loot, progression). It is the entry that most needs
`beyond-cosmetic.md` read first: the authority taxonomy, the sync model, and what actually has
to be closed before any of it is coherent. The kill-credit entry below is not a detail of this
one, it is a *precondition* of it.

**What it would collide with, before any code:**
- Both games have their own online services and their own anti-cheat, and this is handled the way
  the existing online mods for these games handle it: **the mod forces the game offline first**,
  and only then does MeshGhost carry the online part. The game runs in its own singleplayer/
  offline mode, never touching the official servers, so nobody is playing modded while connected
  and nobody gets banned for it. Forcing offline is therefore not a caveat on this entry, it is
  a required part of the feature and the first thing the adapter must do — before any sync, and
  reliably enough that it can't silently fail open. How the existing mods do it is the obvious
  reference, and each one's licence gets checked before its source is read (`licensing.md`).
  **It is the same class of rule as "nothing that ships writes a save", and held the same way**:
  an invariant that protects the player from an accident, not a preference to be weighed against
  convenience. The failure it exists to prevent is someone ending up online *without meaning to*
  while modded, and eating a hardware/IP ban for it — a consequence that lands outside the game
  and that we cannot undo for them. So it fails closed: if the adapter cannot confirm the game is
  offline, it does not sync.
- Access model: neither game is open source, so everything is runtime observation
  (`access-models.md`), and the existing modding ecosystems are the obvious reference — but each
  one's licence gets checked before it is read, and a private or invite-only source stays out of
  every tracked file entirely.
- Nothing that ships writes a save. A shared world that persists is exactly where that rule gets
  tested hardest, and it does not bend.

**Not scheduled**, and further from scheduled than anything else in this file.

## ROM hacks and randomizers worth supporting — candidate list, NOTHING CHECKED (2026-08-19)

**Status: a list, and only a list.** None of these has been downloaded, run, read, or licence-checked,
and none may be until it gets a row in `licensing.md` — that is the rule for any third-party project,
and a list of URLs is exactly the point at which it is cheap to honour. Logged here because the
user gathered them from what a streamer actually plays, which is better evidence of what people
would want to use MeshGhost with than anything we would guess.

**Why they matter to this project specifically.** Both Pokémon adapters already carry a patched-ROM
story: Archipelago's Emerald build relocates `gObjectEvents` by 0x284 and the graphics-info pointer
table by 0x7530, and Crystal's has its own shifted addresses. Every hack below is another recompile
that may move the same things, so each is a test of whether the adapters' *detection* generalises —
Emerald's startup probe for the relocated addresses, Crystal's ROM-header check picking a
separately-measured address set, and the measured-vs-candidate discipline — not a new feature.
(There is no `detect_rom_variant()`; a shared helper of that name has been written down twice as
though it existed, and both times it was prose only.)
A hack that only shuffles data (item/type/map randomizers) is far likelier to just work than one
that recompiles the engine.

| Project | Kind | What it would test |
| --- | --- | --- |
| [pokeemerald-ex-speedchoice](https://github.com/ProjectRevoTPP/pokeemerald-ex-speedchoice/releases/) | Emerald engine recompile | Address detection against a rebuilt binary, the Archipelago case again with different offsets |
| [pokeemerald-speedchoice](https://github.com/ProjectRevoTPP/pokeemerald-speedchoice) | Emerald engine recompile | Same, and whether one detection covers both speedchoice builds |
| [pokecrystal-speedchoice](https://github.com/choatix/pokecrystal-speedchoice/releases/) | Crystal engine recompile | Crystal's equivalent; GB/GBC addresses only exist after a build, so this needs its own `.sym` |
| [Universal Pokemon Randomizer ZX](https://github.com/Ajarmar/universal-pokemon-randomizer-zx/releases) | Patcher over a vanilla ROM | Data-only in the main modes — likely the easiest win, and the most widely used |
| [Crystal Key Item Randomizer](https://github.com/erudnick-cohen/Pokemon-Crystal-Item-Randomizer/releases) | Crystal patcher | Whether item shuffling leaves the overworld structures alone |
| [Pokemon Type Chart Randomizer](https://github.com/NPO-197/PokemonTypeChartRandomizer/releases) | Data patcher | Almost certainly irrelevant to an overworld ghost — a useful negative control |
| [Emerald/Platinum Map Rando](https://warprandomizer.com/) | Warp/map patcher | **The interesting one for us**: `area_id` is map group/number, so a warp randomizer changes what "the same area" means without changing the engine |
| [Emerald EX Map Rando](https://kittypboxx.github.io/Emerald-Ex-Map-Rando/dist/RomMaker/) | Map patcher on the EX base | Both of the above at once |
| [HGSS Map Randomizer](https://github.com/adrienntindall/hgss-map-randomizer/releases) | DS-era map patcher | Nothing today — logged because HGSS would be a new adapter, not a variant |
| [Crystal Map Rando](https://github.com/iFatRain/pokemon-crystal-map-randomizer) | Crystal map patcher | Crystal's `area_id` under a warp shuffle |

Also useful, and not a ROM at all: a [type-chart tracker](https://demki.github.io/poketypechart/) the
same streamer uses — noted only because it shows the shape of the audience.

**Deliberately not listed here:** the invite-only Crystal Archipelago fork. It stays out of every
tracked file by the rule in `CLAUDE.md` — a source that cannot be cited cannot be audited.

**Before touching any of them:** licence row first (`licensing.md`), then a ROM-variant detection
check, then `verified.md` for whatever addresses come out. The order matters more than the speed.

## Pikmin 1 and 2 (GameCube) — a possible next adapter

**Unscheduled, unresearched.** Raised by the user 2026-08-22 as something to look at later:
`https://github.com/projectPiki/pikmin`, a matching decompilation of GameCube Pikmin, and
`https://github.com/projectPiki/pikmin2`, the same group's work-in-progress decomp of Pikmin 2. Both are the same access model and the same licensing
question; how complete each one is has not been checked, and "WIP" means the second may not answer
the questions below yet.

**Before anything is read from either, they go through `licensing.md`** — neither is on that list, so
by CLAUDE.md's rule neither may be used until its license has been checked and recorded. A decomp is
the highest-risk shape of reference we have: it is source, so the facts/expression line matters more
than usual. Facts learned from one (a structure's field order, what a function does) may be used with
a citation; their code may never be committed, adapted, or paraphrased into ours, whatever the license
says — see `access-models.md`.

**What makes it interesting anyway:** a matching decomp is the strongest access model in
`access-models.md` — the questions Emerald is still chipping at with probes (what spawns an
avatar, what its state looks like, what a map transition does to it) are answerable by reading. It
would also be the project's first Dolphin/GameCube target, so the adapter host is an open question
of its own: BizHawk has a Dolphin core, and Dolphin itself has a Lua/scripting story — neither has
been looked at, and which one can meet `_template/README.md`'s bar is the first thing to establish.

## Super Mario Odyssey Online — a prior art read, not a target

**Unscheduled, unresearched, and explicitly NOT something to build.** Raised by the user
2026-08-22: `https://github.com/CraftyBoss/SuperMarioOdysseyOnline`, a mod that adds online
multiplayer to a singleplayer game. Their framing, recorded because it sets the scope: *"not
anything i plan to build/make. but might be nice to add in ideas for now and make take a peak at
how they do things later"*.

**It goes through `licensing.md` before a line of it is read**, like every other reference — it is
not on that list today, so by CLAUDE.md's rule it may not be used until its license has been
checked and recorded. The facts/expression line applies in its strongest form here, because unlike
a decomp this is somebody's own original work: what they *do* may be learned and cited, what they
*wrote* may never be committed, adapted or paraphrased. `access-models.md`.

**Why it is worth a read anyway, and this is the unusual part:** every reference this project has
looked at so far answers *how a game works*. This one answers *how somebody else solved the same
problem we are solving* — a cosmetic-first online layer over a singleplayer game, on a console
title, presumably against a hostile modding surface. The questions worth taking to it are ours, not
the game's:

- **What do they put on the wire, and how often?** Compare against `contract.md`'s packet schema
  and the 20Hz/100Hz question the relay keeps raising.
- **How do they handle a peer whose state has not arrived** — interpolation, extrapolation, or
  neither? MeshGhost's answer is a 250ms interpolation delay plus per-adapter smoothing
  (`core/core.go`, Emerald's drawn tier); a second opinion on that trade would be genuinely useful.
- **Where does their equivalent of the adapter/core split fall**, if it exists at all? The rule
  that adapters never speak the relay protocol is one of this project's load-bearing decisions
  (`architecture.md`), and it is worth knowing what a project that did not make that split pays.
- **What do they refuse to sync**, and why? MeshGhost's cosmetic-default and the depth ladder in
  `beyond-cosmetic.md` are the same question answered once.

**What it is not.** Not a proposed adapter — Odyssey is not a target, and nothing about it is
scheduled. If it ever were, the host question (emulator vs. console vs. Ryujinx-style runtime)
would have to clear `_template/README.md`'s bar first, and "the repo must WORK for a user who has
only it plus what they legitimately own" is a much harder test for a Switch title than for a ROM.

## Super Metroid (SNES) — two reference projects, filed UNREAD — 2026-08-23

The user's find, handed over explicitly *"before we even look at them"*:

- `https://github.com/strager/supermetroid`
- `https://github.com/snesrev/sm`

**Nothing here has been opened, and nothing may be until `licensing.md` carries a row for each.**
That is the standing order of operations — read a project's licence before reading its source — and
it applies harder to this pair than usual, because a disassembly or a C reconstruction of a
commercial game is *expression* even where the facts inside it are free to use. The rule that
decides what could ever come out of them is already written: **facts may be used and recorded with
a citation; expression may never be committed** (`access-models.md`). The user's own framing was
that one is a disassembly and the other might be a decompilation — that is a question to answer at
the licence check, not an assumption to carry in.

**Why it is interesting**, on what is already known without opening anything: SNES would be a
**fifth platform and a second emulator-hosted game**, and Crystal has just paid for most of what
that costs — the BizHawk Lua adapter shape, the spawn-versus-draw tier decision, the "read the
camera, do not infer it" lesson, and a probe kit that is mostly platform-agnostic. Super Metroid is
also a very different movement model from the four games so far (momentum, aim, morph ball,
non-tile-quantised motion), which is exactly the kind of case that finds out whether the contract's
`position`/`anim`/`area_id` shape is actually game-agnostic or merely Pokémon-and-platformer shaped.

**What it is NOT**: not scheduled, not a commitment, and not ahead of the Crystal work still open in
`status.md`. Filed so the links are not lost.

**First three steps, in order, whenever it is picked up:**

1. Licence check both repos, add both rows to `licensing.md`, and decide the access model
   (`access-models.md`) BEFORE any source is read.
2. Establish what a SNES adapter can even reach from BizHawk Lua — memory domains, and whether
   the game exposes a stable object table the way Crystal's does.
3. Only then ask spawn-versus-draw, which is the decision that shaped the whole Crystal adapter.

## Ori (Blind Forest / Will of the Wisps) — candidate adapter, neither title owned

Filed 2026-08-25, moving `adapters/oribf/` here and deleting the folder. It held a README and
nothing else since 2026-08-11 — an empty adapter directory reads as work in progress to anyone
scanning `adapters/`, and the 2026-08-11 ADR that created it (`architecture.md`) had already
picked TEVI as the actual second game.

**Status: candidate, not owned, not scheduled — and not expected soon.** The user, 2026-08-25:
Ori was one of the first games they planned to build for, they then realised they did not own it
and made TEVI instead, and it *"will probly be a while before i get around to any Ori game."*
Treat this as a someday entry, not a next-game shortlist one.

The brief originally named *Ori: Will of the Wisps* as the second target game; the folder was for
*Blind Forest*, the earlier title. The two should not be conflated, and neither is owned. TEVI
was picked instead because it is owned and Unity-based (`adapters/tevi/README.md`), on the same
"movement-focused platformer, the genre where ghost co-op shines" reasoning the brief used for
Ori and Pseudoregalia.

**If Ori is ever acquired**, the first questions are the ordinary ones for a new adapter, in the
order `adapters/_template/README.md` gives them — the access model first (`access-models.md`),
then whether the build is IL2CPP or Mono, which is what decides how much of the TEVI adapter's
approach transfers. Nothing about Ori's runtime has been checked; the Unity-ness is an assumption
from its genre and vintage, not a measurement.

## Two Ori randomizer clients, parked for later (filed 2026-08-30, NOTHING CHECKED)

**Filed verbatim on the user's request, and deliberately un-researched** — *"put both of these in
ideas.md for now, don't check anything about them"*. Recorded so the pointers are not lost:

- `https://github.com/ori-community/wotw-rando-client` — Ori and the Will of the Wisps randomizer
- `https://github.com/sparkle-preference/OriDERandomizer` — Ori and the Blind Forest randomizer

**NOTHING HERE IS CLEARED FOR USE, and this entry is not a step toward it.** No license has been
read, no source has been opened, nothing has been fetched. Per `CLAUDE.md`: a project not listed in
`licensing.md` has not been checked, and its license is read BEFORE its source — so the first
action on either of these is a `licensing.md` entry, not a clone. Naming a public repo in a tracked
file is fine; deriving anything from one that has not been cleared is not.

**Why they would be interesting** (inference from the names alone, not from the repos): a rando
client for a game is the same shape as every adapter here — it already hooks the game, already
tracks player state, and its existence is evidence the game is instrumentable at all. Both Ori
games are also 2.5D with continuous movement, so the rotation/interpolation work of 2026-08-30
would apply rather than the tile-game path. **Read `/new-adapter` before any of that becomes a
plan**, and `agent_docs/access-models.md` first, since "a randomizer exists" says nothing about
whether OUR access model is legitimate.
