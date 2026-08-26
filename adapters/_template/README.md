# Adapter template

<!-- line-cap: 1500 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**First written 2026-08-11**, at the end of Phase 5, and kept current since with what the four
shipped adapters learned the hard way (last swept 2026-08-17, against `agent_docs/contract.md`,
`bridge`, and the four shipped adapters' own docs; last recount 2026-08-18, when Crystal
shipped and every "three" in this folder became wrong at once; re-swept later the same day against
all four adapters' sources and the repo-wide tooling — `dev-scripts/preflight.ps1`, `meshghost
-stats`, the relay's `-introspect`; staleness-swept again 2026-08-21 against the Go source, the
four adapters' sources and `.gitignore`). The core was proven to run against a fake
adapter (`cmd/meshghost-fakeadapter`, a ghost that walks in a circle, driven by
`core.RunAdapter` — see [agent_docs/verified.md](../../agent_docs/verified.md)'s Phase 5 entry)
with no game attached and no import of anything under `adapters/`. This folder is what that
phase promised to leave behind: a reusable starting point for the next game's adapter, not code
to run as-is.

## What is in this file, and what you can safely read later

**This file is long because it is the accumulated cost of four adapters. It is not all urgent.**
Nothing below is optional once you are building, but the ORDER matters and the whole thing does not
have to be read in one pass. Read the hard rules first — they are the ones written because
something already went wrong.

**The hard rules** (read before writing anything): a bandage fix is not a finished feature ·
find out how the GAME does it before you work around it · never let a ghost exist before the player
is in the game · ship the bare minimum · never write a save or game state · this folder is the gold
standard. Six more hard rules load themselves from [../CLAUDE.md](../CLAUDE.md) on first contact
with `adapters/`, and the BizHawk host rules from [../emulator/CLAUDE.md](../emulator/CLAUDE.md).

**Starting out**: what's here · folder convention · starting a new game's adapter · first, work out
what you will be able to READ · a new game gets its own `phaseN.md`.

**Finding out how the game works**: where does this already happen normally · ask the game what it
has · when a mirrored effect's timing is slightly off · the tier ladder (inside "find out how the
GAME does it"). Probe method is a separate file — [probes.md](probes.md).

**Building it**: a movement that does not animate is still a movement · do as much as the game can
handle, then fake it above that cap · find out how many ghosts this game can hold · read the working
adapter for the same host first · every adapter starts the client, and stops it again · "the map
changed" vs "the world was rebuilt".

**Getting the rendering right**: anything drawn SMOOTHLY rides in `position` · judge a renderer at
the SHIPPED settings · when a renderer looks wrong, measure THE WIRE first.

**Testing and writing it up**: testing it · writing the new adapter's own README.

## Hard rule: this folder is the gold standard, and it is never allowed to go stale

**Anything a shipped adapter learns belongs here too.** A new rule, a new file convention, a hard-won
trap, a new per-adapter document — when it lands in `emulator/pokemon/emerald/`,
`emulator/pokemon/crystal/`, `tevi/` or `pseudoregalia/`, back-port it to `_template/` in the same
pass, not "later". The next game starts from this folder,
so whatever is missing here is a lesson the next adapter gets to learn the hard way a second time.

**The rule lives here, in the template itself, deliberately** — not only in `CLAUDE.md` — because
the failure mode is drift, and drift is exactly the case where the other copy of the rule is the
one that got forgotten. Found live 2026-08-16: `documentation.md` was created for Pseudoregalia and
this README did not mention it at all until the next day.

Three things that make it concrete:

- **Adding a file to an adapter?** Add its template (or at minimum a line in "What's here" and
  "Folder convention" saying what it is and when to create one).
- **Adding a rule to an adapter's own doc?** Copy the rule text here, generalised — same wording
  where it can be, so the two don't quietly diverge into different rules.
- **Sweeping this folder?** Update the date on the line above, and say what you swept against.

The counterpart rule for content lives in each file: `BANDAGES.md` for compensations,
`documentation.md` for how the game works, and neither may hold the other's material.

## What's here

- [documentation.md](documentation.md) — **how the GAME works**, per mechanic: the fields, the
  components, what each move actually does. Copy it into the adapter folder and fill it in as you
  learn. It carries two hard rules of its own: no adapter workarounds may be described in it (those
  belong in `BANDAGES.md`), and everything in it must be publishable — facts observed from a running
  copy, never source, decompiled output, asset content or verbatim dumps. The licensing assessment
  behind that is in [agent_docs/licensing.md](../../agent_docs/licensing.md).
- [probes.md](probes.md) — **how to build a probe that answers something**: how to search for a
  value you cannot name, how to instrument a running game without changing what it does, how much a
  probe is allowed to cost, and the traps that make a probe lie. Not copied into an adapter folder —
  it is method, and it is read, not filled in.
- [BANDAGES.md](BANDAGES.md) — the shipped-compensation register, plus the canonical
  how-to-tell-a-bandage guide and the user's standing position that a bandage is a state to leave,
  never a resting place.
- [FLAGS.md](FLAGS.md) — the switch register: every switch sorted into shipped **behaviour**,
  **probe**, or **dormant** negative, plus the two kinds that are not bools at all — `constexpr`
  **numbers** that decide behaviour, and **runtime** switches (environment variables, flag files,
  loader-set globals), which are the only kind an interpreted adapter has. Write it once you have
  more than a handful; Pseudoregalia reached 56 without one and paid for it, and the two Lua
  adapters had none at all until 2026-08-18 because this file used to contemplate compile-time
  bools only. It is the tie-breaker when a flag's
  comment and its value disagree, and the place where flags that only work as a *set* are marked.
- [PROTOCOL.md](PROTOCOL.md) — the three-function contract (`get_local_state` /
  `render_remote` / `despawn_remote`) and the tick model, written language-agnostically
  (pseudocode, wire envelope examples), because the game it was written for next (TEVI,
  Phase 6) was Unity/C#, not BizHawk Lua — a Lua-specific stub would not have transferred, and
  Pseudoregalia's UE4SS C++ mod after it proved the point twice. Every real adapter, in any language,
  implements this same shape by speaking the bridge wire protocol (`bridge/bridge.go`);
  nothing here is Go-specific.
- The `core.Adapter` Go interface (`core/core.go`) is a *different* thing: an
  in-process shortcut used only by `cmd/meshghost-fakeadapter` and Go tests
  (`core/core_test.go`'s `TestRunAdapterInProcess`) to drive the core without a socket
  at all. A real adapter — including TEVI's — never implements it; it dials the bridge and
  speaks NDJSON, exactly like `adapters/emulator/pokemon/emerald/meshghost_emerald.lua` does. See
  [PROTOCOL.md](PROTOCOL.md) for why this distinction matters and where to look for a worked
  example of each.

## Folder convention

One folder per game, named after the game itself (`emerald`, `tevi`, `pseudoregalia`).

**Games running inside an emulator are grouped under `emulator/`; everything else sits at the top
level.** So `adapters/emulator/pokemon/emerald/` and `adapters/tevi/`. Added 2026-08-18 and
renamed from `bizhawk/` on 2026-08-25, both on the user's call, because "how this adapter reaches
the game" is the division that actually predicts what an adapter looks like: everything under
`emulator/` is a script reading emulated machine memory against a decompilation, while everything
else is a mod inside the game's own process using its engine's API. A future Dolphin or
DuckStation game goes **inside** `emulator/`, not beside it.

**There is deliberately no `emulator/bizhawk/` level, and no `unity/` or `unreal/` level.** The
rule — stated once, in [../CLAUDE.md](../CLAUDE.md), which loads itself — is **create a level only
when two things actually share it.** A second emulator is what creates `emulator/bizhawk/`; a
second Unity game is what creates `unity/`. Until then host rules sit at the level that exists
(`emulator/CLAUDE.md`, `tevi/CLAUDE.md`, `pseudoregalia/CLAUDE.md`), and each of those says so at
its top so the move is obvious when it comes.

Within `emulator/`, games in the same franchise are grouped again —
`adapters/emulator/pokemon/emerald/`, with a future `adapters/emulator/pokemon/platinum/` alongside
it — purely for browsability as more games get added; it's not a code-sharing boundary. A hypothetical Platinum adapter (NDS, a
different console/engine than Emerald's GBA) would share essentially no code with Emerald's,
same as any two unrelated games — grouping by franchise just keeps the top level of
`adapters/` from getting crowded by one series' many entries.

**The files a mature adapter folder carries**, so a new one knows what it is aiming at:

| File | When to create it | Template |
| --- | --- | --- |
| `README.md` | Immediately — the build story, one numbered step per thing that happened | see "Writing the new adapter's own README" below |
| `documentation.md` | **Immediately** — start it with the first mechanic you learn | [documentation.md](documentation.md) |
| `BANDAGES.md` | **Immediately, empty** — an empty register is the goal, an absent one is a gap | [BANDAGES.md](BANDAGES.md) |
| `FLAGS.md` | Once you pass a handful of compile-time switches — sooner than feels necessary | [FLAGS.md](FLAGS.md) |
| `VERIFIED.md` | **Immediately, empty** — this game's dated, user-confirmed facts. Split per game 2026-08-25; `agent_docs/verified.md` keeps only Go-side and cross-game entries | [VERIFIED.md](VERIFIED.md) |
| `UNVERIFIED.md` | Once the first thing is built but unwatched — this game's queue waiting on the user. Split per game 2026-08-25 | [UNVERIFIED.md](UNVERIFIED.md) |
| `probes/README.md` | Once `probes/` holds more than a couple of scripts — an index of what each one answered | [probes-README.md](probes-README.md) |

**`README.md`, `BANDAGES.md` and `documentation.md` are expected of EVERY adapter, with no
exceptions.** Create all three when the folder is created.

**All three of those templates were written on 2026-08-25.** The table had mandated the files and
pointed at "any shipped adapter's" since it was written, which is exactly how four copies of the
same ~30-line `VERIFIED.md` preamble came to exist and start drifting apart. A mandated file with
no template is a mandated file that gets copied from whichever sibling was opened first.


**Probes and their logs go in a `probes/` subfolder, not at the top level.** Only what ships
lives beside the `.md` files — the adapter script itself and anything a release copies. A mature
adapter accumulates dozens of probe scripts and hundreds of log files, and at the top level they
bury the documentation that a reader actually came for: Crystal reached 25 scripts and 72 logs
within a day of being started, at which point its four `.md` files were genuinely hard to find in
the listing. **The probes themselves are committed and kept** — they are the record of how each
fact was established, and several written for a vanilla ROM were re-run later against a
patched one to chase the same class of bug (Emerald's four `avatar_*` probes, 2026-08-14). **Their logs are not**: `.gitignore` covers
`/adapters/**/*.log`, because once a run has been read its conclusions belong in
`verified.md`, not in a megabyte of raw text. Convention adopted 2026-08-18, on the user's ask, and
applied to Emerald and Crystal together. **A new adapter needs no `.gitignore` change** — the rule
was widened from `emulator/pokemon/**` to all of `adapters/**` on 2026-08-25, precisely because
this paragraph used to end by telling you to widen it yourself, which is a rule enforced by whoever
gets 168 lines into this file before creating their first probe.

**This replaces an earlier carve-out, overturned by the user 2026-08-18**, which said
`documentation.md` was needed only for games with no readable source — on the reasoning that
Emerald has a decompilation and TEVI a managed assembly, so a doc would restate them. That was
wrong for two reasons worth keeping:

- **A curated description of the mechanics an adapter depends on is a different artifact from the
  source it was learned from.** The decomp describes the whole game; this describes the handful of
  systems we actually touch, in the order that matters, with the traps noted.
- **Being *able* to look something up is not the same as having looked.** The carve-out assumed a
  future reader would go to the decomp. In practice they read the adapter folder, and if the
  knowledge is not there it gets rediscovered — which is what these files exist to prevent.

**An empty `BANDAGES.md` is the goal; an absent one is a gap.** A register that is present and
empty says "this adapter has no compensations". An absent one says nothing at all — you cannot tell
whether there are none or whether nobody wrote them down.

### What may go in `documentation.md`: explain facts, never reproduce expression

**This is the publishability rule applied to prose**, and it is strict — see
[CLAUDE.md](../../CLAUDE.md)'s standing test: *is this fine sitting in a public repo forever?* Not
"does a licence permit it". No, or unclear, means it stays out.

**Facts are not copyrightable; expression is.** So the file explains how the game works, in our own
words, and never carries the material it was learned from:

| Fine | Never |
| --- | --- |
| Measured numbers, timings, coordinates | Source text, in any language |
| Field, function and type *names* | Decompiler or disassembler output |
| Which component does what, how states relate | Asset content, extracted strings |
| Behaviour described in your own sentences | Verbatim reflection or memory dumps |
| Citing a reference by file, so a claim is checkable | Bulk data tables copied wholesale |

**The test to apply: could someone re-derive this by owning the game and watching it?** If yes it is
a fact and may be explained. A decompilation or an assembly only saved you the time; it is not the
source of your right to know it. If no — if the only way to have it is to copy something — it stays
out.

**Two edges worth naming rather than discovering later.** A small data table restated as facts is
usually fine, but a table that *is* the entire content of a source file is the closest you will get
to the line, so make it a considered call and prefer prose when in doubt. And every copy must carry
the provenance sentence at the top — `agent_docs/licensing.md`'s audit greps for it.

**The rule above is repeated verbatim at the top of every adapter's `documentation.md`, and must
stay there.** Not a link to it — the text itself. A rule that lives one click away is read once,
when the file is created, and then not again at the moment it matters: someone pasting something in
long after they have forgotten it exists. `_template/documentation.md` carries it as a `## Before adding anything to this file`
section, marked KEEP; copying that file forward is what propagates it. All four shipped adapters
carry it (added 2026-08-18, on the user's instruction: *"so we always guarantee that we don't
accidently add something wrong/bad anywhere"*).

**A new adapter's `documentation.md` therefore starts with three things**, before a single fact
about the game: that section, the provenance sentence, and the no-workarounds rule. Delete none of
them.

**A state inventory is not expected either** — it is worth a file
only when the game gives you far more readable state than you sync, and its form is completely
game-specific: memory addresses for Emerald, C# class fields for TEVI, reflected UE properties for
Pseudoregalia. Only Pseudoregalia has one (`PLAYER_FIELDS.md`), because UE reflection hands you
hundreds of properties and an inventory with sync status pays for itself. Emerald's addresses are
few and each was its own research project, so they live in `agent_docs/verified.md` and that is the
right call — **don't create an inventory file for a game whose readable surface is small.**

Where one does exist, it answers a different question from `documentation.md` and the two should
not merge: the inventory is *which state exists and which we sync*, `documentation.md` is *how the
game's mechanics work*. Copy the shape from `adapters/pseudoregalia/PLAYER_FIELDS.md`; there is
deliberately no template, since a stub with no content would go stale immediately.

## Starting a new game's adapter

1. Read [agent_docs/contract.md](../../agent_docs/contract.md) in full — the packet schema,
   message types, adapter interface, and tick model are the parts that don't change per game.
2. Read [PROTOCOL.md](PROTOCOL.md) in this folder for the wire-level shape (connect,
   per-frame send/receive, redraw-every-frame) independent of any particular language.
3. For a worked, complete reference of a real adapter speaking this protocol end-to-end
   (connection retry, the hello handshake, NDJSON framing, the remote-ghost set, the tick
   loop), read `adapters/emulator/pokemon/emerald/meshghost_emerald.lua`. Its game-reading parts are
   Emerald-specific and won't transfer; its bridge-connection, hello, and tick-loop shape will.
4. Figure out, for the new game: what counts as `area_id` (a scene/level identifier), what
   `position` looks like (2D or 3D — the schema doesn't fix this), what `anim` tags are
   meaningful, and whether `get_local_state()` should ever return "don't send this frame" (a
   menu, loading screen, or similar).
5. **Enumerate the game before guessing at it** — see "Ask the game what it has" below. Do this
   as soon as a ghost renders at all, not later. It is the biggest time-saver found so far, and
   it was found late enough to have cost real sessions in the Pseudoregalia adapter.
6. Read [agent_docs/pitfalls.md](../../agent_docs/pitfalls.md) — at minimum its "Diagnostic
   methodology" section (one diagnostic at a time, never log the value you just wrote, run the
   test without the fix, two identical failures means stop guessing). It's the most transferable
   content in the repo, and the rest of the file is the log of what the four existing adapters
   got wrong so you don't have to.
7. Follow this project's verification standard ([CLAUDE.md](../../CLAUDE.md)): no address,
   hook, or API call from memory — everything traceable to a source, and nothing in
   [agent_docs/verified.md](../../agent_docs/verified.md) until it's been watched happening on
   screen.
8. Do not modify `core` or `relay` for game-specific reasons. If something
   about the new game seems to require that, stop — it means either the contract needs a real,
   ADR'd revision (rare), or the adapter is trying to do something the boundary doesn't allow
   (much more likely).
9. When the adapter is actually ready to ship, add it to the release: give it its own step in
   `.github/workflows/release.yml`'s "Assemble release package" step, under
   `packaging/release/games/<game>/` (or `games/<franchise>/<game>/` if the game is grouped, as
   `games/pokemon/emerald/` is — the release groups by franchise the way `adapters/` does, but
   **not** by emulator: there is no `games/emulator/`, because a player installing a game's files
   does not care which host reads them) — nothing
   under `adapters/` is picked up automatically. See
   [packaging/README.md](../../packaging/README.md)'s "Adding a game to the release" for the
   pattern (and its TEVI section if the adapter needs a build step, not just a file copy,
   before it's shippable). A *compiled* adapter is four things, not one: a
   `dev-scripts/build-<game>.bat` that stages its output into `packaging/release/games/...` and
   writes a `built-from.txt` SHA-256 record, the build output committed to the repo (CI can't
   build these), its own staleness-verification step in `release.yml`, and a hand-written
   `README.txt` for the game folder that nothing generates.
   **If the adapter autostarts a core** — which it should; see "Start the client, and stop it
   again" below — check where it installs. A mod that drag-and-drops *into the game's own
   directory tree* has nothing pointing back at the unzipped release folder, so it needs a
   `config.json` of its own in the mod folder, and the player copies `meshghost.exe` in beside it
   once. **The client is deliberately NOT shipped in mod folders** (changed 2026-08-18): it is
   9 MB, every such adapter would carry the same copy, and the alternative — a shared client found
   through a `%LOCALAPPDATA%` breadcrumb — is machinery that goes stale when a folder moves and
   silently picks the wrong one when two installs exist. `config.json` is 1 KB and does ship, so
   only the big file is manual. An adapter loaded from the release folder itself (both BizHawk
   adapters) reaches the root exe and config with no copy of anything.

## An emulator adapter is Lua-only — never patch the ROM (moved)

The rule and its full reasoning are in [../emulator/CLAUDE.md](../emulator/CLAUDE.md), which loads
itself when you touch a BizHawk adapter. The one-line version, which is also in the root
`CLAUDE.md`: an emulator adapter never ships, generates or requires a patched ROM — that is what
lets MeshGhost run on top of an Archipelago seed instead of fighting it.

## First, work out what you will be able to READ

Do this before estimating anything. The four shipped adapters differed enormously in difficulty,
and the best predictor was not the engine, the language or the modding framework — it was **how much
readable source existed about the game before work started.**

| Adapter | Access model |
| --- | --- |
| Emerald | External source decompilation (`pokeemerald`) |
| Crystal | External source decompilation (`pokecrystal`) — with a twist: Game Boy RAM labels live in *floating* sections, so no address appears in the decomp's source at all and the decomp has to be **built** to produce a symbol file |
| TEVI | Self-documenting artifact (`Assembly-CSharp.dll` via ILSpy) — the easiest, and by far the fastest adapter |
| Pseudoregalia | Runtime reflection only, no readable source anywhere — the largest and hardest by a wide margin |

**Full reference: [agent_docs/access-models.md](../../agent_docs/access-models.md)** — the other
approaches that exist, a checklist for working out what a new game offers, and the axis that
actually predicts pain (does a wrong input *tell* you it is wrong, or return something plausible?).

The short version, because it is what the next section rests on: with a decompile you can look up
the truth, and a wrong name is a build error. With runtime reflection only, every name is a string
resolved live and **a wrong one does not fail to compile — it returns nothing, or something
plausible.** On those games, enumerating what the game contains is not a debugging technique. It is
the substitute for having source.

## Where does this already happen normally? — pick the common path, not the matching feature

**Before asking "how do I make X happen", ask "where does the game already do X, in ordinary
play?"** Then go and watch that, and see whether you can call or copy it. This turns an invention
problem into an observation problem, and observation is the thing you can actually do.

**The trap it avoids is picking the wrong place to look.** The instinct is to find the feature
that *thematically* matches what you want. That feature is usually the worst possible teacher: it
is rare, special-cased, hard to trigger, and often built for constraints that have nothing to do
with yours. The ordinary path runs every session, is trivial to observe, and is far more likely to
be the generic mechanism everything else is built on.

**The live case, 2026-08-17.** Wanting to put another player's character into Pokémon Emerald, the
obvious place to look was **Union Room** — the game's own multiplayer mode, where other players'
avatars appear. A full decomp investigation went there. The user's later reframing was better:
*"something is obviously handling the spawn of the character normally in the game after all"* —
the game spawns the player character **every time a save loads**. Same question, a path that runs
constantly instead of one behind a link cable.

And the investigation's own findings back that up: the function Union Room uses,
`TrySpawnObjectEvent`, is explicitly noted there as **a generic engine function, not
Union-Room-specific**. The thematic feature was a special case of the common mechanism the whole
time. Worse, having gone to the special case, the investigation went on to ask how to *imitate*
what it writes, and never asked whether the generic function could simply be **called** — the
question the common-path framing produces immediately. See `agent_docs/ideas.md`.

**The feeling is the tell.** Picking the thematically-matching feature does not feel like a
mistake while you are doing it — it feels *clever*, because "reuse the game's own multiplayer code
to do multiplayer" is good reasoning that often works. This is the same bias the naming section
below records one level down (*"a plausible name makes you confident while you're wrong"*), applied
to features instead of identifiers. Treat a plan that feels particularly neat as a prompt to check
whether the boring, frequent path would answer the same question, not as a reason to skip that
check. Nothing about the Emerald case was visible in advance; it only resolved once someone asked
where a character gets spawned *normally*.

**The sequence, and it is short:**

1. **Name the thing in the game's own terms** — "a character appears", not "spawn a remote ghost".
2. **Find when that happens in normal play**, preferring the most boring, most frequent occurrence.
   Loading a save. Entering a room. Drawing the HUD.
3. **Watch it happen** with a read-only probe, and find the call that does it.
4. **Ask whether you can call that**, before asking how to reproduce its effects. Calling it gets
   you everything the game does around it for free; reproducing its effects gets you a maintenance
   burden and a list of things you forgot.
5. **Only if you cannot call it**, imitate — and write down *why* you could not, because that is
   the blocker the next person needs (see the create/borrow/draw tiers below).

**Why this is worth a section of its own.** "Ask the game what it has" (next) tells you how to
enumerate what exists. This tells you *where to point that enumeration*. Getting the location
wrong makes every other technique here more expensive, because you are studying a special case and
generalising from it — and you will not notice, since the special case does genuinely work.

## Ask the game what it has, before you guess at what it might have

**Do this early — right after a ghost renders at all, not once you are deep into polish.** It is the
single biggest time-saver this repo has found, and it was found late: Pseudoregalia's adapter
spent multiple sessions guessing property and function names before anyone thought to simply
enumerate what the game contained. User's own conclusion, 2026-08-16, and the reason this section
exists: *"if we had done this earlier in the pseudo adapter i think we could have saved a lot of
time. so it's probably a good idea to check what's in a game instead of trying to piece it together
by guessing."*

**The failure mode this replaces.** The intuitive approach is to reason from a name: the trail
effect is probably called something with "Trail" in it, the glide ability is probably called
"glide", a tracking-particles flag probably controls tracking particles. Every one of those was
wrong in this repo. `AnimGraphNode_Trail` turned out to be stock bone physics for dangling cloth
and ears. Cling Gem has no "glide" string anywhere in the game. `spawnTrackingParticles?` is a
static flag set once at spawn. Each wrong guess costs a full build-deploy-play-watch cycle, and
worse, a plausible name makes you *confident* while you're wrong.

**The replacement is two complementary passes.** Run both; they answer different questions and
neither substitutes for the other.

1. **A catalog probe — "what does each thing look like?"** Enumerate everything of a kind the
   game has loaded, then play them onto a ghost one at a time on a fixed cadence (~3s each),
   logging a line naming each as it starts. A human watches and matches look to name. This
   sidesteps the trigger problem entirely: you never need to know how to make the game produce an
   effect in order to find out what it is. In Pseudoregalia this confirmed 8 untested animations in
   one session, and later identified the empty-hand glow out of a catalog of 58 effects.
2. **A passive watcher — "what does the real player produce, and when?"** Every N ticks, enumerate
   what is currently live, and log the *difference* against the previous sample. Diffing is what
   makes it cheap: static scenery reports itself once and then stays quiet, so what you see is
   what actually just happened. This is the half that answers the trigger question — which effect
   appears at the moment of a throw, a landing, a wall-ride — by observation instead of inference.

**What the probe must log to be worth running**, learned by getting each wrong once:

- **Attachment, not just identity.** Log what each thing hangs off and where: parent component,
  socket/bone name, and relative offset. Without it you can reproduce an effect but not *place*
  it, and you will end up nudging offsets by eye. The first watcher here logged identity only, and
  the resulting ghost glow sat visibly in the wrong spot.
- **A known-good control in the cycle.** Include one entry you have already confirmed. If the
  control doesn't look right, the probe is broken and every other result that session is worthless.
- **A shortlist, not everything — for a probe a HUMAN has to watch, and only there.** 58 effects at
  3s each is three minutes of mostly level dressing, and a person cannot track that. Filter by name
  substring to something under about a dozen, widenable, never a hardcoded list of names you already
  picked. **This does not apply to a name dump you read yourself — see "Dump everything" below,
  where filtering first cost a whole night.** The distinction is who consumes the output: a person
  watching in real time needs a shortlist; a text file you grep does not.
- **Stable ordering** (sort the catalog), so "the seventh one" still means the same thing after a
  relaunch. That is the note a human watching will actually take.
- **One at a time.** Retire the previous item before starting the next, or a look cannot be
  attributed to a name.

**Check every system the engine offers, not just the first one you find.** Unreal has two particle
systems (Niagara and the older Cascade) and effects can live in either; a search that assumes one
reports "not found" for something that is plainly on screen. The general rule: before concluding an
effect does not exist, confirm you searched everywhere it could be. If it is in neither, that is
still a real result — it likely is not a particle effect at all, but a material property on the
mesh, which is a different search to run deliberately.

**Engine-agnostic in shape, engine-specific in API.** The mechanics above are Unreal
(`FindAllOf`-style object enumeration, spawning by asset path). The shape transfers: any engine has
some registry you can enumerate and some way to trigger one entry — Unity has animator states and
particle systems, a ROM has a fixed animation table at a known address. Ask what the game contains
before you theorise about what it might contain.

**One caveat that bites in multiplayer specifically.** Catalogs include content from *mods the
local machine has installed*. Pseudoregalia's enumeration turned up a custom effect from a
third-party mod. Anything built on such an asset silently does nothing for peers who lack it, so
prefer base-game assets and treat a failed asset lookup as an expected case, not an error.

### How to build the probe that answers this — [probes.md](probes.md)

Everything about probe *method* now lives in [probes.md](probes.md), next to this file: searching
for something you cannot name (drive an input one way, then reverse it), dumping without filtering
first, logging a window rather than an event, delaying your own change so its effects separate from
the game's own startup, and the two ways a probe lies to you — by breaking what it measures, and by
being too expensive to run at all.

**Read it before writing the first probe for a new game.** Every section in it is a run that
already went wrong once in this repo.

### When several mechanisms each "do nothing", try them together

One-variable-at-a-time is the right way to attribute an effect and it is **blind to systems with
preconditions**, where the effect exists only for the union. The Pseudoregalia slide pose needed
**five mechanisms simultaneously**, every one of which tested negative alone — and two were
switched off as proven no-ops and had to be restored when removing them broke a working build.

**After about three single-variable negatives, run the union of everything plausible.** If it
works, subtract from there: that direction is safe, because you always have a working state to
compare against. Full case study: `agent_docs/pitfalls.md`.

## When a mirrored effect's timing is slightly off, stop reconstructing the trigger

Enumeration (above) answers *what exists*. This answers *when it happens* — and it is the fix for
the specific, recurring symptom of a ghost that does roughly the right thing at roughly the wrong
moment: a trail that starts late, an effect that lingers, a pose that lags.

**The failure mode.** You cannot see the peer's game, so the tempting move is to reconstruct the
condition under which the effect fires — "a slide is this state plus this capsule height for this
many ticks" — and drive the ghost from your reconstruction. It works, mostly. But it is a
re-implementation of a rule the peer's game already evaluated perfectly, so it can lead, lag, or
miss edge cases, and it only ever covers the cases you enumerated. Pseudoregalia went through
three wrong triggers for one trail before landing on a measured-but-still-inferred fourth, and it
still only knew about slides.

**The fix: mirror the decision, not the rule.** Detect that the effect actually happened on the
local player, count those events, send the count, and have the ghost reproduce one per increment.
Send a **monotonic counter**, never a boolean: a flag that is true for one frame will not survive a
~20 Hz send rate, whereas "has this number gone up since I last looked" is well-defined no matter
which samples arrive. Baseline the counter on a peer's first sample so a mid-session joiner does
not replay its whole history at spawn.

This is strictly better than a reconstruction in three ways: the timing is the game's own, it
covers every situation that produces the effect rather than the ones you thought of, and it cannot
drift when the game changes. The same reasoning fixed a glow whose real rule ("only near a save
crystal") nobody had guessed — mirroring presence meant never needing to know the rule at all.

**Latch anything that travels with the counter, at the moment you detect the event.** A counter
survives a lossy, low-rate send precisely because it is never recomputed; a payload sent alongside
it — a colour, an asset path, a hit type — needs that same property. Recompute the payload from
live state each tick and the counter stays exact while its payload becomes a lottery, decided by
which tick the send happens to sample. That is invisible at the call site, because both fields look
equally "synced". Pseudoregalia lost roughly half its ultra-hop trail colours to exactly this, from
a single line that read a baseline value into the outgoing field every tick while the real value
updated more slowly.

The failure has a recognisable escalation, and it is worth knowing before you are in it: the first
fix is a tie-break, the second a hold window, the third a longer hold window, and then one day six
real events produce ninety-eight fake ones. **When you find yourself adding a second timer to
protect a value from being overwritten, stop and remove whatever overwrites it instead.** The
correct version has no window to size and no race to lose.

**Finding what to count.** If the effect is an object, diff the world around it: snapshot the
candidate object types, trigger the effect, snapshot again, print what is new. Trigger it *on the
ghost* if you can — being able to fire it on demand beats waiting to perform a hard trick in-game.
That is how Pseudoregalia identified its afterimage as a spawned actor carrying a posed mesh
snapshot, after several sessions of assuming it was a particle effect and guessing colour
properties — and that identification is what finally located the ultra hop's blue, which had been
parked as unsolvable.

**Know whether the objects are pooled.** Engines recycle particles, projectiles, decals and damage
numbers rather than destroying them, so "an object I have not seen before" fires while the pool
grows and then goes quiet. The cheap test is whether the objects ever disappear at all: track them
and log a lifetime when one vanishes. If nothing ever vanishes, they are pooled.

Worth knowing, but note how it played out in Pseudoregalia: pooling was real, and re-writing the
spawn detector around it was still **the wrong fix** and got reverted. The trail was not
short of spawns at all — see the cost warning in [probes.md](probes.md) for what was actually
wrong. *"This mechanism
is real"* and *"this mechanism explains my bug"* are separate claims and need separate evidence.

### Before you instrument any of this, read the probe cost warning

Three rules that are one rule, and every adapter has paid for at least one of them:

- **A probe can break the effect it is measuring**, and four metrics agreeing with each other
  proves only that they share a blind spot. This is the most expensive lesson in the repo, and it
  applies directly to the enumeration and spawn-detection work above — exactly the shape that got
  costly. [probes.md](probes.md) has the method; [../../agent_docs/pitfalls.md](../../agent_docs/pitfalls.md),
  "The diagnostics were the bug", has the incident.
- **A probe that costs frame time is reporting on a different game.** The user's standing position,
  2026-08-21: *"non laggy/good performance should be the default for things like this"*. Buffered
  log, console throttled to a glance, flush on a timer, per-frame work done once rather than once
  per peer — designed in, not tuned in after somebody complains. **Both halves of the logging cost
  were measured separately and each alone was enough to stutter the game**, so fixing one and
  stopping is a wasted cycle. `dev-scripts/bizhawk-hitch-meter.lua` is how you check rather than
  assume.
- **It is not only about probes.** The same cost applies to anything that runs every frame, shipped
  code first — and both Lua adapters got that wrong. When anyone says "choppy", measure PACING, not
  rate: an average cannot see a hitch. Host-specific numbers: [../emulator/CLAUDE.md](../emulator/CLAUDE.md).

### If you are about to start effect work, read the playbook first

The two sections above tell you *what to build* — enumerate before guessing, and mirror the
decision rather than the rule; [probes.md](probes.md) tells you how to instrument either one. They do not tell you how to run the hunt — what order to do things in, how to
instrument a run so it can answer something, or how to tell when you are actually finished.

That is [agent_docs/effect-investigation.md](../../agent_docs/effect-investigation.md), and it is
worth the read **before** starting, not after something goes wrong. It follows one investigation —
Pseudoregalia's afterimage trail and the ultra hop's blue afterimage, the hardest and longest single
piece of work in that adapter — from the first wrong guess to the working version, and then extracts
the procedure.

**Why it earns a whole file.** That effect looked like one property on one object. It became: three
wrong triggers, a fourth that shipped and was still wrong, a fatal crash from hooking the wrong kind
of function, bursts that truncated each other, a coverage gap that sat written down and unread for
days, a probe that broke the very thing it measured badly enough to need this project's first commit
bisection, an engine object pool that made a naive detector both under- and over-count, and **seven
separate points at which the whole thing was confirmed working and then reopened.**

The three findings most likely to save you time on a different game:

1. **When a plausible property provably never changes, that is evidence about which OBJECT holds the
   state — not evidence that the problem is unsolvable.** This one wrong inference parked the feature.
2. **When a count looks wrong, log identity, not more counts.** "The game produced two" and "one was
   counted twice" produce identical numbers and need opposite fixes. A pointer separated them in one
   line.
3. **Test the move performed *badly*, and test that the effect stays absent.** A reconstructed
   trigger agrees with the real one on the clean case and diverges on the messy one, so the clean
   case can never tell them apart.

## Testing it

The local rig already exists — read [dev-scripts/README.md](../../dev-scripts/README.md) before
inventing your own. Four things about it are worth knowing up front, because each was learned
the expensive way:

- **Give each game a `run-core-<game>.bat`, and test with `-interp=0ms -min-send=10ms`.** The
  core's default interpolation buffer (`core.DefaultInterpolationDelay`, 250ms) smooths over real
  local timing bugs — treat "looks fine with the buffer on" as untested, not confirmed. (If you
  also start a relay locally, it needs `-send-hz=100` or it silently overrides every core's fast
  `-min-send`.)
- **A run over the wrong transport looks exactly like a run over the right one.** The client
  default is `auto` and the shipped relay serves `tcp,quic`, so a default session lands on quic —
  but every connection handshakes over tcp first and only then upgrades, and a preference the
  relay does not serve degrades quietly to a working tcp session. Confirm from the client's own
  `core: relay offers ... — using <transport> at ...` line which one a run actually used; a run
  that "works" proves nothing on its own. Pseudoregalia keeps a `run-core-<game>-tcp/-udp/-quic.bat`
  per transport for this, paired with `run-netsim.bat` for real packet loss.
- **Solo-test through `run-relay-loopback.bat`**, which echoes your own state back as
  `<id>-ghost`, and give loopback ghosts a **render-only** offset so you can tell the ghost from
  your own character — Emerald 2 tiles, TEVI 160 units, Pseudoregalia 150. Offset for judging
  render quality, zero for verifying exact tracking; either way it never touches what goes on the
  wire. **Crystal's default is 0, and that is a deliberate difference rather than an omission**:
  its ghost is a real object event with real collision, so the offset is about not spawning inside
  something solid rather than about telling two sprites apart, and a tester raises it by hand when
  they want a side-by-side comparison. So this is four adapters and three defaults — pick yours
  from what your ghost *is*, not from what the others chose.
- **If your adapter renders peers TWO ways, make the loopback ghost show BOTH at once.** Any
  adapter with a second, hand-written renderer beside the engine's — the Pokémon adapters paint an
  overflow tier over the emulator, and any game with a hard cap on spawnable characters will end up
  with the same shape — inherits a question the engine answers for free and the painted path does
  not: occlusion, a dark cave, a water reflection, a doorway. `MESHGHOST_COMPARE_TIERS` is how both
  BizHawk adapters answer it: the one loopback ghost is rendered twice in the same frame, engine
  copy two tiles right, painted copy two tiles left, so a missing effect is visible next to a
  correct copy of itself in the same lighting. **Comparing across two runs cannot do this** — the
  place has changed by the time the other renderer is on. Dev-only, off by default, announced in
  the log as `PROBE FLAG IN USE`, and never applied to a real peer. User's request, 2026-08-19.
- **Loopback cannot exercise cross-area filtering, join/leave, or despawn** — it always echoes
  your own area back. Those bugs only appear with two real instances, which is why the bridge
  port has to be per-instance overridable (see [PROTOCOL.md](PROTOCOL.md)). `run-fakeadapter1/2`
  exercise core+relay with no game attached at all.

Two habits from the existing adapters worth copying:

- **Diagnostics are named constant flags, default off, left in the tree with what they found
  written in the comment** (Emerald's `DIAG_STEP_CURVE`, TEVI's `DIAG_REDRAW_TRACE`,
  Pseudoregalia's `ANIM_PULSE_TRACE`). Throttle or edge-trigger every one of them — a per-frame
  log produced 7324 lines in a single TEVI session.
- **Hash-diff the file actually deployed into the game directory against your repo copy before
  believing any live test.** Every adapter here is a build artifact copied somewhere, and a
  stale copy has invalidated whole test sessions twice. `dev-scripts/preflight.ps1` does this
  check and the rest of the "are these the artifacts we think they are" sweep, read-only; run it
  before handing the user a game, and point the `MESHGHOST_*_DLL` environment variables it
  documents at wherever your adapter deploys so a new game is covered too.
- **Ask the client what it saw, rather than inferring it from the game.** `meshghost -stats=10s`
  logs one line: link health, how many peers are known versus actually rendered, bytes each way,
  and what share of received remote states this client discarded because the sender was in another
  area. That last number separates "the adapter is not rendering" from "nothing was meant to
  render", which is otherwise a guess. The relay's `-introspect` is the same idea from the other
  end (rooms, members, and cross-area fan-out); both are off by default and cost one log line.

## Writing the new adapter's own README

Give the game's folder a `README.md` with a **"How this adapter was built"** numbered list — the
short, readable version of the story, one step per thing that happened, ~2-4 lines each, in plain
language. See `adapters/pseudoregalia/README.md` for the worked example. Keep the detail
(field names, dump sizes, failed attempts, dated evidence) in `agent_docs/phases/phaseN.md`,
`verified.md`, and `pitfalls.md`, and link to them — a step that has grown into paragraphs of
caveats belongs there with a one-line pointer left behind. See [CLAUDE.md](../../CLAUDE.md)'s
hard rule on this.

**Any time figure is time to reach a named milestone, not total time spent** — "~10 hours from
nothing to good enough", never "~10 hours in". It is the number a reader is actually asking for.
**A time figure is optional, though**: three of the four adapter READMEs carry one and Crystal's
carries none, which is fine. What is not fine is an ambiguous one. (Corrected 2026-08-25: this
said "all four read that way".)

**Why the length rule is a rule.** Found live 2026-08-15: Pseudoregalia's steps 19-22 had each
grown to 15-20 dense lines while steps 1-18 stayed at 2-4, which made the file hard to read for
exactly the audience it exists for. Length creeps step by step and nobody notices until the file
is unreadable end to end, so the cap is per step rather than per file.

**One standing exception, and do not "fix" it.** Granted by the user 2026-08-16 and extended
2026-08-17: Pseudoregalia's steps 38-41 (the ultra-hop blue trail) and 43-44 (the slide pose) run
6-10 lines each and must not be trimmed — they are that adapter's two hardest pieces of work. A
note at the bottom of that list says so too.

**Carry a "Limits that come from the game, not from us" section near the top**, before the build
story. Every game has a ceiling — how many peers it can show at once, and what happens past it —
and a reader deserves to meet it in the adapter's own README rather than discover it in a session.
`adapters/emulator/pokemon/crystal/README.md` has the worked example; the numbers and the measuring
rig live in [agent_docs/crowd-limits.md](../../agent_docs/crowd-limits.md), and the README carries
the short version with a link.

**This matters most for emulated games, and it is also easiest there** — which is the whole reason
to insist on it. An emulator hands you the engine's arrays and the console's own sprite hardware to
read directly, so the ceiling is a *measurement* rather than an estimate: slot counts, hardware
sprite entries, frames per second under load, all readable from a probe in an afternoon. A native
PC game usually cannot be pinned down that precisely, so an emulated adapter that shrugs at the
question is leaving free, exact knowledge on the table. State the number, say which resource runs
out, and say what a player sees past it — **including that it is the game's limit and not a bug**,
because from the player's chair an invisible friend and a disconnected friend look identical.

**Also state the access model up top**, as a bullet alongside platform and adapter language:
**"How the game is read: ..."** — decompilation, self-documenting artifact, runtime reflection,
modding API, and so on, per the section above. All four shipped adapters carry this bullet. It is
the single fact that best explains why an adapter is the size and shape it is, it tells a reader
immediately how much of the code is discovery scaffolding versus feature work, and it sets
expectations for anyone picking the adapter up later.

**If the game is emulated, also carry a one-line bullet naming the exact roms or isos confirmed
working.** Use this layout verbatim — user-facing and direct, quoted names, nothing else:

```markdown
- Confirmed working roms: "Vanilla", "Archipelago 0.6.7".
```

(`isos` where that is what the platform uses.) `adapters/emulator/pokemon/emerald/README.md` carries the live
one. **Keep it a bare list of names**: a player checks their own copy against it at a glance, and
turning it into prose defeats the entire point.

**Name them the way a player thinks of them, not the way a file system does.** `"Vanilla"` means the
unpatched base game, and the axis that actually matters to a reader is base-versus-patched — so
`"Vanilla", "Archipelago 0.6.7"` reads instantly, where a region code or a full file name
(`(USA, Europe)`) invites the reader to check the wrong thing and makes the line harder to scan.
Region variants, exact file names and hashes are a separate question and belong in
[agent_docs/environment.md](../../agent_docs/environment.md).

- **Emulated games need this most, because their players arrive with randomizer, translation and
  region variants** — "will my copy work?" is otherwise a question only the adapter's author can
  answer and no reader can look up.
- **For a PC game, silence means Steam.** Store builds are not truly identical — Steam, Epic and
  GOG releases can differ in version and behaviour — so the convention is: **list nothing when only
  Steam has been confirmed** (which is why TEVI and Pseudoregalia carry no such line), and list the
  platforms explicitly the moment another one is — `"steam", "epic", "gog"`. An absent line reads as
  "Steam, or works whatever you have"; a present one is a real claim about each platform named.
- **Only list what was watched running**, per [CLAUDE.md](../../CLAUDE.md)'s standard for an
  adapter — a patch that merely booted without errors is not a confirmation.
- **It is for the player, not for us.** Keep `game_id`/`game_version` and any other protocol
  versioning out of it: those are ours, they mean something different, and mixing them in turns the
  one line a player can actually use into something they have to interpret.

**The other sections every shipped README carries**, and which the build story alone doesn't cover:

- **A bold `**Status:**` line as line 3** — the phase, what's done, what the last live
  confirmation was and when. All four shipped adapters open this way, and it is the line a reader
  checks first. **Rewrite it the day the adapter's state changes, not the day someone notices.**
  Crystal's still said "groundwork only, there is no adapter yet" while a ~1000-line adapter that
  renders ghosts, opens a socket, writes RAM and ships in the release sat beside it — the single
  most misleading line in the repo when it was found, 2026-08-18, precisely because it is the line
  a reader trusts most.
- **"Further work past 'good enough'"** — what is still open, with `agent_docs/status.md` named as
  the authoritative list. This is the section that stops the numbered story turning into a status
  file: anything still open goes here, not into a step. All four shipped adapters carry it
  (Crystal's was the last to land).
- **"Custom features"** — anything this adapter does that isn't required of an adapter (TEVI and
  Pseudoregalia both have one). Keeps game-specific extras out of the build story.
- **"Dev tools"** — an index of the probe scripts the adapter accumulated. Emerald's dozen-plus
  probes are only findable because its README lists them; write an index the moment you have more
  than two. **Past roughly a dozen, move the index out to `probes/README.md` instead of growing a
  README section** — Crystal has 76 probes and indexes them there, which is the better shape at
  that size and is why it has no "Dev tools" section at all. Either location satisfies this; no
  index does not.

## Hard rules: player-capability parity, and reproducing the WHOLE effect — moved

Both now live in [../CLAUDE.md](../CLAUDE.md), which loads itself whenever you touch anything
under `adapters/`. In one line each: **anything the player can do, anything else should be able
to do** — "impossible" means the mechanism has not been found yet; and **reproduce the whole
effect, not just the animation** — the extras (sound, dust, shadow, screen shake) are part of it.

## Hard rule: a bandage fix is not a finished feature

**Default: no.** If the fix compensates for a value instead of causing it, forces state back after
something else changes it, or leans on a constant tuned until the screen looked right, it is not
done — however good it looks. **"Almost" and "good enough" are the words to watch for in your own
reasoning**; they are usually the moment the real mechanism stopped being investigated.

**The tell is mechanical, so you can check it without judgement:** does the fix *prevent* the wrong
thing, or *correct* it afterwards? Correcting afterwards means the cause is still running, and
something else will eventually read the state you patched.

**Why this is a hard rule and not a preference — two worked examples, one day apart.** The
Pseudoregalia **camera fight-back outlived its cause and became the bug**, blocking every
legitimate camera change until players saw it as the ghost stealing the camera; the measured fix
was one line ([pitfalls.md](../../agent_docs/pitfalls.md), "Camera / view-target ownership").
And **bandages spread**: the slide floor-sinking fix taught a second bug to be described as
"structurally the same bug as" it, and the proper fix — driving the game's own crouch path — had
existed the whole time. The bandage is what stopped anyone looking for it
([pitfalls.md](../../agent_docs/pitfalls.md), "Case study: the slide pose").

**The narrow exception, and its price.** A temporary fix is allowed when it unblocks something else
that must be tested now — early bring-up, or getting a camera usable so a different feature can be
watched at all. When you take it:

1. **Say it is temporary in the code**, in the comment, where the next person reads it. Not in a
   commit message.
2. **Record the measurement that would replace it.** A bandage with *no* measurement behind it is
   the expensive kind — there is nothing to build the real fix on.
3. **Log it as an open item**, not a finished one, in this adapter's own
   [BANDAGES.md](BANDAGES.md), with `status.md` saying so.

**You will not always know at the time**, which is why the register is a living file.
[BANDAGES.md](BANDAGES.md) carries the eight tells that only surface afterwards, the 1:1 bar, and
the one legitimate kind. Read it when auditing, not just when writing.

**What this rule is not.** It does not mean every constant is suspect. A number measured from the
game and documented (the loopback ghost's deliberate sideways offset; a reconnect interval matching
an observed cadence) is a design decision with evidence behind it. The difference is whether the
number came from *measuring the mechanism* or from *trying values until it looked right*.

## Hard rule: find out how the GAME does it before you work around it

**Before writing anything that overrides, forces, corrects, or fights the game, observe what the
game itself does — read-only — and prefer using its own mechanism.** The rule is not "never work
around anything". It is: **the observation comes first, and the workaround has to be aimed at what
you actually saw.** Sometimes the answer really is a targeted override — but you cannot target what
you have not measured.

**Three times this was paid for here**, each written up where its detail belongs:

- **The Pseudoregalia camera** — a "force the view target back" fix worked for its one case and
  fought every legitimate camera change the game made thereafter.
  [pitfalls.md](../../agent_docs/pitfalls.md), "Camera / view-target ownership".
- **The ultra-hop trail** — five rounds of predicting when the game would trail; what worked was
  letting the game's own spawns drive it ([adapters/pseudoregalia/README.md](../pseudoregalia/README.md), steps 38-41).
- **`landed?` / `jumped?` vs `moveState`** — names told you nothing about whether a field was a
  one-shot pulse or continuous state; only watching the values did.
  [verified.md](../../agent_docs/verified.md) has the full trail, including a later correction.

**If the game has a cleared decompilation, READ IT FIRST — watching is the slower half.** A probe
shows the flag *this* donor on *this* map happened to carry; the source lists every bit in the byte,
every path that reads it, and the cost attached to each — and no probe can tell you what a byte
MEANS. Measurement is for CONFIRMING what the source says, not for discovering it. Paid for
2026-08-23: a Crystal ghost cloned a live NPC understanding 4 of the 16 bytes it copied, and three
faults came out of the other twelve — ending in a ghost that *was a trainer* and hung the game. All
three were named constants in an already-cleared, already-built decomp.
[pitfalls.md](../../agent_docs/pitfalls.md), and `agent_docs/licensing.md` for what is cleared.
**It does not lower the confirmation bar** — a fact about the game is not evidence our adapter does
the right thing with it, and the user still confirms on screen.

**Watch it before you PLAN against it, not just before you work around it.** If a plan rests on a
model of how the game behaves, capture the behaviour first — one read-only run is almost always
cheaper than the plan. **The tell:** you can describe what the game does, but you cannot point at
the run where you watched it. Worked example, and why a wrong model aims the debugging at the wrong
subsystem: [pitfalls.md](../../agent_docs/pitfalls.md), "Planning on a model of the game you never
watched".

**What "observe first" looks like in practice**, cheapest first:

1. **Log what the game does, changing nothing.** A read-only hook on the function you were about
   to override, printing what it was called with and what it chose.
2. **Ask whether the game already has a mechanism** that does what you want (this file's "Ask the
   game what it has, before you guess at what it might have").
3. **Only then decide** whether to use its mechanism, or to override — and if you override, aim at
   the specific condition you observed rather than at the symptom.

### Did the game make this, or did you take it? — the question that decides what you may do to it

The same object can arrive two ways, and which one it was silently becomes a constraint on every
operation you perform on it afterwards. Decide it **explicitly and write it down**.

- **You asked the engine for it** — the game's own creation call, with the game's own class (in
  Unreal, `world->SpawnActor(pawn_class, …)`). It is a real instance of a real class, so **the
  game's own systems drive it for free** — animation, physics, state machines.
- **You took something that already existed** and repurposed it. Nothing was created; a thing the
  level placed for its own reasons is now doing your job.

**Repurposing is a bandage, and the highest-cost shape this project has found.** The full argument —
why the real cost is not the appearance but the permanent "never do X to this" rule you inherit,
and how Pseudoregalia kept one running against a premise that had stopped being true — is in
[BANDAGES.md](BANDAGES.md), "The bandage to avoid entirely".

**There is a third option, and an emulator adapter usually starts there: draw over the top.** You
never touch the game's world at all — you paint on the frame from outside, and the game does not
know anything is there. Ranked by how much the game does for you:

| Tier | What it is | You get for free | You pay |
|---|---|---|---|
| **Create** | ask the game to make one, with a class it already ships | animation, collision, layering, occlusion, lifetime | you own the lifetime and must not leak it |
| **Borrow** | repurpose an object the level already placed | it exists and is valid | it is still the game's: no animation, cannot destroy, cannot hide |
| **Hardware sprite** (emulators) | write extra entries into the game's own sprite table, in a range its per-frame path does not touch | the emulated GPU draws it: palettes, layering, fades — **occlusion only where the hardware gives it, see below** | no engine state at all — you drive position and animation, and you must release the entry |
| **Draw over** | paint on the frame from outside | nothing | you reimplement everything, permanently |

**For a BizHawk game the ladder is `spawn -> OAM -> drawn`, in that order** (settled 2026-08-21;
ADR in `agent_docs/architecture.md`, numbers in `verified.md`). **That is the ORDER to start from,
not a set of defaults to ship** — the two shipped adapters deliberately differ from each other and
from "all on": Crystal ships drawn ON and OAM OFF, Emerald ships both OFF. The reason is per-game
and is the useful lesson: Crystal's UI regions are locatable (a text box is the game's own frame
tiles in the tilemap, a menu publishes its border fields) so a drawn ghost can be clipped out of
them, and Emerald's are not, so its drawn tier would paint over text.

**The hardware tier does NOT buy occlusion for free — that was a GBA result stated as a property
of the tier, and the Game Boy refutes it** (corrected 2026-08-25). On the GB a text box is
background tiles with the BG-to-OAM priority bit clear, so a hardware sprite draws **in front of**
it, and Crystal's OAM tier has to reuse the drawn tier's clipping rather than inheriting anything.
Setting the priority bit is not the fix: it would put the peer behind every non-zero background
colour, i.e. behind the scenery it is standing on. **Ask what the hardware's priority rules
actually are on your console before budgeting occlusion as free.**
Each peer takes the best tier with room. **A rung may decline for a place, not only for lack of
room**: Emerald's OAM tier stands down under a screen-covering semi-transparent sheet — weather fog,
underwater — where the ladder becomes `spawn -> drawn` (its `FLAGS.md`, 2026-08-21). Expect one such
exception per hardware effect that owns the whole screen. Measured on Emerald, standing still with
the crowd on screen, each tier run alone against a 60.0 fps bare control:

| tier | at 16 peers | at its own ceiling | what the ceiling is |
| --- | --- | --- | --- |
| spawned | 60.0 | 60.0 at **11** | the engine's object array, shared with the map's own cast |
| OAM | 60.0 | **60.0 at 56** | the entries above the engine's layout cursor |
| drawn | 60.0 | **39.6 at 56**, 10.4 at 150 | nothing but the host CPU |

And the combination, which is the case that actually ships: **spawned at its cap AND OAM at its
ceiling at the same time — 67 characters on screen — also measured 60.0.** The two tiers the engine
and the hardware draw do not add up to a cost; the one that borrows neither does.

**Read the 16 column before the others.** At small peer counts the three are indistinguishable from
each other and from a bare emulator, so the tier choice buys nothing and a new adapter should not
agonise over it. The ladder only matters under crowd load — and there the middle tier is free to its
ceiling while painting costs a third of the frame rate at the same count.

**The ceiling itself is per-console, and "56 extra characters" is Emerald's number, not the
tier's.** Crystal's OAM tier adds **zero to one** character: the engine already uses 34-36 of the
Game Boy's 40 sprite entries outdoors and all 40 indoors, so there is almost no tail to allocate
into. A middle tier can therefore be worth building for its *fidelity* — live palettes, day/night,
fades — while buying essentially no capacity. Measure your own console's headroom before promising
a number.

**Do not reach for per-scanline OAM multiplexing to raise the middle tier's ceiling.** It needs code
inside the ROM, which is closed to us, and the front end has no scanline callback to substitute.
(The original third reason — "there is no sprite-count limit to beat in the first place" — is
GBA-only and was corrected 2026-08-25: the Game Boy has a hard per-scanline sprite limit, which is
exactly why Crystal's tier allocates *downward* from the last entry, so that when the limit bites
it drops a ghost rather than one of the game's own characters.) The full reasoning is the
2026-08-21 ADR — check it before re-proposing the idea, because it is an attractive one.

**"Draw over" is not automatically the wrong answer** — and this is the part worth getting right,
because the tiers are not a quality ranking. It is the correct answer when the tiers above are
blocked by something real, and the way to tell is whether you can name the blocker.

This project has one of each. Pseudoregalia's ghost moved **borrow → create** and should have
moved sooner; the constraint that kept it borrowing had quietly gone stale and nobody re-checked
it, which is the bandage described above. Emerald drew its ghost with overlay primitives and
**stayed there on purpose** for a time: the create tier needs a spawn path that writes game state,
which this project refused outright, and the middle tier (sprite/VRAM injection) had a cited fragility —
a reference implementation's own comments show its fixed address needing manual re-tuning between
*vanilla* versions of the same game, before any ROM patch. See `agent_docs/ideas.md`.

**Both halves of that have since been overturned, and the middle-tier half is the newer one
(2026-08-21).** The fragility was real but specific: it belonged to *hardcoding* addresses. Claiming
the same resources through the **game's own allocator** — its tile-allocation bitmap, its own
unused sprite-table range — carries none of it, because the numbers are read from the running game
rather than baked in. The middle tier is now a measured, free option, not a cited risk.

**Updated 2026-08-17 — that blocker's premise has since changed, and this is the worked example of
the rule two paragraphs down.** The refusal was never absolute: `agent_docs/plans.md` phrased it as
the current posture, liftable per-feature by an ADR. Crystal's adapter did exactly that and moves
to **create** — spawning a real object event via the engine's own path (`architecture.md`,
2026-08-17). Note what did and did not change: the template's "never write game state" rule below
already permits *spawning* — the line is persistence and authority, not pixels — so what the ADR
actually bought was the cruder **mechanism** an emulator forces, writing RAM from outside the
process rather than calling an engine API from within it.
**Emerald then re-tested the constraint and moved, exactly as point 4 below asks.** "We cannot
create, because writes are refused" had stopped being true, and the 2026-08-18 ADR extended
Crystal's to Emerald: a peer there is now a real object event first, with the OAM and drawn tiers
below it (`adapters/emulator/pokemon/emerald/README.md`, step 18). The overlay was never *wrong* —
it shipped and was proven — it was resting on a premise nobody had re-checked.

The difference between those two is not the tier. It is that one had a blocker anyone could state
and the other had a stale assumption nobody had tested. **Know which of those you have.**

**How to find out which one you are looking at**, and what the game's own path is:

1. **Ask where the object came from.** If your code holds a pointer it *found* (an enumeration, a
   name lookup, a search for something suitable), it is not yours. If it holds one a creation call
   *returned*, it is.
2. **Look for the creation call the game itself uses.** Dump the class's functions and the
   engine's spawn/factory API and look for the one the game would call to make this — then check
   whether you can call it with a class the game already ships. Cloning the player's own class is
   often available and gives you every system attached to it.
3. **Prefer it even when repurposing already works.** A found object that behaves correctly today
   is still borrowed, and the bill arrives later as an unexplained constraint.
4. **If you must repurpose, write down what you may not do to it, and why** — in the adapter's
   `BANDAGES.md`, not only as a code comment. Then, **when the design changes, re-test the
   constraint**: that is the step this project missed.

## A new game gets its own `agent_docs/phases/phaseN.md` — and you ASK for the number

**Create the phase file when the adapter folder is created, not when the work is finished.** Every
game so far has one, and it is the file that indexes a game's work: what is settled, what is open,
and the method notes that only make sense in that game's context. Without it, findings scatter into
`verified.md` with nothing tying them together, and the next session has to reconstruct the state
of the work from a dated log.

**Ask the user which number to use. Do not infer it.** The numbering is not simply "highest + 1":
phases 1–5.5 bundled the first game's adapter work together with building the core, server and
client, Phase 5.5 exists as a fraction, and Phase 8 was created for a game that already had phases,
because it was a *new stream of work on an old game*. Which of those a new piece of work resembles
is the user's call. Found live 2026-08-18: Crystal ran a full session of real findings with no
phase file at all, and the user had to point it out.

**What belongs in it** (see `phase9.md` for a worked example, and `phase8.md` for the "new stream
on an existing game" shape):

- **Purpose** — why this game, and what makes it different from the ones before it.
- **What is settled** — summary only, with the evidence staying in `verified.md`.
- **The shape of the thing** — what the game's model actually turned out to be, especially where it
  cost several attempts to learn. This is the section a future reader gets the most from.
- **Open** — a checklist, including what is deliberately out of scope and why.
- **Method notes** — what worked as a way of investigating this particular game.

## Hard rule: never let a ghost exist before the player is actually in the game

**Find the game's own "I am in play" signal early, gate every spawn on it, and do that before the
ghost is otherwise finished.** Every adapter meets this; it is one of the most common bugs in the
category, and far cheaper to build in than to retrofit after a ghost has been seen floating over a
title screen.

**There is one absolute case and a pile of judgment calls, and they should not be written as one
rule** — an over-broad first draft said "menus, intros, warps, cutscenes and battles", and the
user's correction (2026-08-18) is the version that is true:

- **ALWAYS blocked, no exceptions: anything before the player is in the world at all.** Title
  screen, main menu, file select, intro, the loading step itself. Here the world does not exist yet
  or is mid-construction — the object tables an adapter writes into are being built, and the data
  it reads is stale from before. **This is the case guaranteed for every game, and the one the gate
  exists for.**
- **Everything else is per-state judgment, and "hide it" is often the wrong answer.** Ask *does the
  game still render the overworld in this state* and *is the object table stable*. A pause menu
  drawn over a still-visible overworld is a state where leaving the ghost alone looks right and
  removing it looks like a bug; a battle that replaces the screen makes the question moot.
  **Decide per state, with a reason you can state.**

> **Two different questions, and this section only answers the first** — easy to conflate, and the
> wording above did until it was caught (2026-08-18):
>
> 1. **"*I* am not in the overworld"** — a menu, battle or cutscene on **this** machine. Then no
>    peer's ghost may be drawn or spawned here, full stop. That is this section.
> 2. **"*a peer* is not in the overworld"** — a **design decision, not a safety rule**, belonging
>    with the adapter's presence semantics. Their ghost is not dangerous; the question is what it
>    should honestly represent.
>
> **Question 2 has a known failure mode already shipped here**, so decide it deliberately: a peer
> that simply stops sending leaves the last thing you drew standing there forever, looking like a
> player standing still (`status.md`'s TEVI FullMap entry). **A frozen ghost is a lie about where
> someone is**, told often in a game with multi-minute battles. Keep it, hide it, or mark it away —
> none is automatically right, but **"stopped sending" must be distinguishable from "standing
> still"**, because the two look identical to the receiver and only one is true.

**It is not only cosmetic, which is the part that gets underestimated.** In those states the game
is frequently *rebuilding* the structures an adapter touches — object tables, sprite slots, the
map. Writing into them mid-rebuild corrupts rather than merely embarrasses, and an adapter that
only draws can still read half-initialised data and render nonsense from it.

**Ask the game what state it is in. Do not infer it from whether the data looks plausible.** This
is [CLAUDE.md](../../CLAUDE.md)'s "a wrong read returns a plausible number" applied to program
state: on a menu the data is usually just *stale*, so it looks reasonable and a data-shape check
sails through. The signal you want is the game's own state machine or mode variable. **Emerald**
compares `gMain.callback2` against `CB2_Overworld`; **Crystal** uses `wMapStatus` plus
`wMapEventStatus`, `wScriptRunning` and `wGameLogicPaused`, characterised with a dedicated probe
rather than assumed.

**How to establish it for a new game:**

1. **Write a change-only probe and start it on the title screen**, before loading anything. That
   state is the one you most need characterised and the one you cannot return to without a reset.
2. **Walk the whole lifecycle in one run**: menu → load → intro → overworld → open a menu → change
   area → battle → back. A gate is only trustworthy once you have seen it *refuse* correctly, not
   just accept correctly.
3. **Log what the proposed gate WOULD have decided at each moment**, alongside the raw values. That
   turns "does my gate work?" into something readable rather than something argued about.
4. **Prefer several cheap signals combined** over one clever one, and state what each is for.
5. Distinct from `get_local_state()` returning "don't send this frame" ([PROTOCOL.md](PROTOCOL.md)):
   that suppresses your own outbound state, this governs whether a peer's ghost may exist locally.
   **You need both**, and they can differ — it is reasonable to stop sending the moment a menu
   opens while leaving an already-spawned ghost alone until something more disruptive happens.

## "The map changed" and "the world was rebuilt" are different events

**An engine can do the first without the second, and a ghost's identity check must not confuse
them.** Learned the expensive way in Emerald, 2026-08-18, after it leaked a solid ghost at every
route boundary until a screenshot showed five of them standing in a line.

Any adapter that spawns something has to answer, every frame, *"is the thing I created still the
thing I created?"* — because the engine owns the slots and will reuse them. The obvious answer is
to record what makes it identifiable and re-check that. The trap is **which** properties you pick:

- **A rebuild** — a warp, a door, a level load — destroys what the engine owns and reassigns the
  slots. Anything of yours that survives is a stale pointer to somebody else's object. Here,
  destroying "your" ghost without re-checking deactivated a real NPC and freed another sprite's
  VRAM, both silently.
- **A move that is not a rebuild** — a seamless connection between adjacent maps, a streamed zone,
  a sub-area transition — changes the *identity of where you are* while leaving the objects
  untouched. An identity check keyed on location now reports a healthy entity as dead, so you drop
  your record, spawn a replacement, and leave the original alive with nobody tracking it. **One
  orphan per crossing.**

Both failures come from the same check, and each is invisible in exactly the case the other one
catches — which is why testing a house (a rebuild) proved nothing about a route boundary (a
connection), and the adapter passed one live test while failing the other.

**What to do:**

- **Identify a spawned entity by something you control that the engine cannot forge**, not by where
  it is. Emerald uses "active, not the player, and `localId == LOCALID_PLAYER`" — a state only its
  ghosts can be in, because real NPCs carry a template id and the player is flagged. Pick the
  equivalent property in your game; check that a *real* entity of that game can never wear it.
- **Sweep for orphans on a timer.** Anything wearing your marker that you are not tracking is
  yours, from a previous script load or a bug, and clearing it costs nothing. This also cleans up
  after the reload-driven development loop, which leaves debris by its nature.
- **Never destroy without re-checking identity first.** Clearing a slot you no longer own is worse
  than leaking one you do.
- **A leak plus solidity is a different severity from either alone.** Leaked cosmetic ghosts are
  untidy; leaked *solid* ones accumulate into a wall that can block a route. Decide collision and
  lifecycle together, not separately.

## Hard rule: never adopt a handle the engine can recycle — moved

In [../CLAUDE.md](../CLAUDE.md). One line: **copy what an effect DOES, not the data structure
that does it** — a structure naming another object by index is safe for the engine, which owns
every lifetime involved, and unsafe for you, who own none. Learned twice in Emerald, 2026-08-21.

## A movement that does not animate is still a movement

**Do not assume a character crossing tiles is playing a walk cycle.** Emerald's ice slides a
character across tiles with its legs still: the game's forced slide is a fast walk PLUS two bits on
the object -- animation disabled, and facing locked.

The general trap: an adapter naturally sends "where the peer is" and "what animation it is
playing", and treats the second as a consequence of the first. A game with ice, a conveyor, a
knockback, a slide or a mounted state breaks that link, and the ghost then walks where the player
glides. **Send the suppression as its own field** (Emerald uses `extras.noanim`), and check whether
your game's equivalent bit OUTRANKS a movement -- Emerald's does, which is why three separate
places were each quietly undoing it.

## Do as much as the game can handle on its own, then fake it above that cap

**The user's rule, 2026-08-19.** It resolves a tension this file otherwise leaves open: everywhere
else says *let the game do the work* and *a bandage is not a finished feature* — so what happens
when the game genuinely cannot do the work at all, because it ran out of a fixed array that was
sized in 1998?

The answer is not to pick one path for everything. It is to **use the engine to its limit, and
only then fall back** — and to know exactly where that limit is, because it is the seam between
the two.

- **Below the cap, the engine wins on every axis.** Animation, palettes, draw priority, occlusion
  behind scenery and menus, collision, and every future engine behaviour you have not thought of,
  all for free and all correct.
- **Above the cap, something faked beats nothing at all.** A ghost drawn over the emulator's
  output is subject to none of the engine's or the hardware's limits, because it happens after
  both. The peer exists on screen instead of silently not being there.
- **The fallback is a bandage, and it is registered as one**, with its costs written down — in
  Crystal's case: no occlusion, no collision, no engine animation, and two rendering paths in one
  adapter that will drift. That is the point of `BANDAGES.md`: a compensation you chose on purpose
  and can defend is fine, one you forgot you were making is not.
- **Decide which peers get the good tier.** Join order is the default and the worst answer — it
  freezes a peer's visual quality on when they connected. Nearest-wins is usually right, with a
  hysteresis band so ghosts do not churn between tiers as someone walks past.

- **The engine's tier is also the CHEAP one, and that is not why it was chosen** -- but it settles
  any argument for reaching past it. Measured on Emerald, 2026-08-20: a spawned ghost costs
  ~0.05ms of the script's frame because the engine is already walking its object array and
  building its sprite list, so one more entry rides along with work being done anyway. A drawn one
  costs ~0.6ms EVERY frame -- about twelve times more -- because it re-does the whole job after the
  frame is finished, borrowing nothing. **Faking it means paying for a second renderer.** So the
  fallback tier stays a fallback: never a default, and never reached for because painting pixels
  looks easier to control than steering a real object.

Worked reasoning for a specific game, including why hardware-level tricks (sprite multiplexing)
fix the wrong limit: `agent_docs/ideas.md`, "Spawn to the game's cap, then DRAW above it".

## Hard rule: the adapter may not cost the game its frame rate — moved

In [../CLAUDE.md](../CLAUDE.md). One line: **frame rate is a shipping requirement, not a tuning
concern** — and when anyone says "choppy", measure pacing, not rate.

## Find out how many ghosts this game can hold, and make it refuse cleanly

**An old game has a fixed number of character slots and a fixed hardware sprite budget, both
decided long before anyone thought about multiplayer.** So "how many players can share a map" has
a hard, per-game and often per-MAP answer that no amount of relay capacity changes, and an adapter
that does not know it will happily write into a slot it does not own.

Measure it early; the method and the reusable rig are in
[agent_docs/crowd-limits.md](../../agent_docs/crowd-limits.md). In short: generate real synthetic
peers with `meshghost-fakeadapter` (so the whole path is exercised, not just the engine), read the
engine's own slot counts and the hardware's sprite entries with a probe, count emulated frames
against a wall clock so "it looked fine" is not the evidence, and repeat in more than one kind of
map.

**Two things that generalise beyond one game:**

- **The binding resource changes with the map, and often for a different reason.** Crystal ran out
  of *object structs* outdoors and *map objects* indoors, at the same total of 9 ghosts. Reporting
  only one of them would sometimes name the wrong cause.
- **Refuse, and SAY SO.** *"My friend is invisible"* and *"my friend is not connected"* look
  identical from the player's chair. A rate-limited log line naming which pool ran out, and how
  many ghosts are present, is the difference between a diagnosable session and a mystery.

Record the answer in the adapter's `documentation.md` — it is a fact about the game, not a
compensation.

## Budget a probe's reads before running it — see [probes.md](probes.md)

An emulator's script host charges per call across a managed boundary, so a scan that reads trivially
as an expression is thousands of calls per frame. It does not error: it stalls, and **you get no log
at all**, which reads as "the probe found nothing" rather than "the probe never ran". Found live
2026-08-18 on a patched Crystal ROM, costing a repeated live test. The section in
[probes.md](probes.md) has what to do instead, cheapest first.

## Read the working adapter for the same host before writing a new script

**If another adapter already runs on the host you are targeting — the same emulator, mod loader or
scripting runtime — open it and copy its shape before writing anything.** Not its game logic, which
will not transfer, but its loop structure, its lifecycle handling and its cleanup. Those are
properties of the *host*, and the existing adapter has already paid for getting them right.

**Found live 2026-08-18.** Four new BizHawk Lua scripts for Crystal were written using
`event.onframeend` to drive their per-frame work. It appears to function, and then: a callback
registered that way is owned by the **emulator**, not by the script, so stopping the script does
not unregister it. The console kept spamming while the Lua Console reported `0 active`, start and
stop did nothing, and each reload stacked another copy. The shipped Emerald adapter had used the
correct idiom — `while true do ... emu.frameadvance() end`, which dies with the script — since the
day it was written. Nobody looked.

Two follow-on traps in the same area, both worth knowing before you meet them: an exit handler must
be **registered before** a loop that never returns, and **nothing in a teardown handler may throw**,
because host resources may already be invalid. Full symptom-to-fix write-up in
[agent_docs/pitfalls.md](../../agent_docs/pitfalls.md).

**The general form**: host-lifecycle questions — how does my code start, stop, and clean up — have
already been answered once per host in this repo. Re-deriving them is how you find the answer by
breaking something instead of by reading.

## Every adapter starts the client, and stops it again

**This is expected of a new adapter, not optional.** MeshGhost should feel like part of starting
the game, not a second program to remember. All four shipped adapters do it as of 2026-08-18 --
Pseudoregalia since 2026-08-16, TEVI, Emerald and Crystal added the same day this was written.

The rule has two halves and the second is the one people forget:

- **Start**: if no core answers, spawn one — with no window.
- **Stop**: the core must die with the game, including when the game crashes.

**Auto-close is `-exit-with-pid=<the game's own pid>`.** The core watches that process and exits
when it goes, so a crash cannot leave an orphan holding the bridge port. Kill the child on a clean
shutdown too, where the host gives you a hook: that makes the player's ghost leave the room
immediately instead of when the relay's idle timeout notices.

**Spawn on a port the walk found EMPTY, never a fixed one.** This is the bug worth stealing the
fix for: Emerald's first version spawned on `BRIDGE_BASE_PORT`, which is correct alone and wrong
with two copies of the game running — the walk correctly reported the base port busy, the launcher
spawned there anyway, that core could not bind and exited instantly, and the second copy was left
with nothing. Record the first port where *nothing answered* during the sweep, spawn there, and
refuse to spawn at all if every port in the range is somebody else's core. A port that answered
and then rejected you is not free.

**Only spawn after a full sweep found nothing.** A core that is already running — started by hand,
by a dev script, or by another copy of the game — must be used as-is. That ordering is the whole
reason autostart cannot produce a pile of processes.

**How to spawn with no window depends on the host:**

| Host | Mechanism |
| --- | --- |
| C++ (UE4SS) | `CreateProcessW` with `CREATE_NO_WINDOW` |
| C# (BepInEx) | `ProcessStartInfo` with `UseShellExecute=false`, `CreateNoWindow=true` |
| Lua (BizHawk) | `luanet` → the same `ProcessStartInfo`. **Not `os.execute`/`io.popen`** |

That last row is worth the detail, because the obvious route is the wrong one. `os.execute` and
`io.popen` both run `cmd /c ...`, so the console window that flashes belongs to the *shell doing
the launching* — which is why `start /b`, `powershell -WindowStyle Hidden` and a hidden-`Run`
`.vbs` all still flash, the PowerShell one longest. `luanet` skips the shell entirely.
`Process.GetCurrentProcess().Id` from the same bridge gives you the pid for `-exit-with-pid`.
Method and evidence: `agent_docs/environment.md`, probe in `dev-scripts/bizhawk-spawn-probe.lua`.

**Always support `MESHGHOST_NO_AUTOSTART`.** An antivirus objecting to one program starting
another is a real thing that happens to real players, and the documented answer is to set this and
run the client by hand. Register it in the adapter's `FLAGS.md`.

**Say which happened, once per connection** — "started a core" versus "using a core that was
already running". With no console window anywhere, that log line is the only way to answer "why
are there two processes" or "why is it running the old build".

**Packaging**: the client is NOT shipped inside mod folders (9 MB each, per game). A mod that
installs into the game's own tree ships its `config.json` and the player copies `meshghost.exe` in
once — see the folder-convention section above. An adapter loaded from the release folder itself
reaches the root copy with no copy at all.

## Hard rule: ship the bare minimum, and nothing else

**A release contains exactly what the adapter needs to run, and not one file more.** TEVI is the
model — it ships a single DLL. If a modding framework, runtime or SDK comes with extras, stage the
parts your adapter actually loads and leave the rest behind.

This is not tidiness or download size. Anything bundled is something **installed into a stranger's
game by someone who only asked for a visual ghost overlay**, and it is your responsibility whether
or not you wrote it.

**Found live 2026-08-17, in Pseudoregalia**: a blanket `xcopy` of RE-UE4SS's stock `Mods` folder
shipped a cheat manager, a console, keybind hooks and an actor dumper — **enabled**, and used by
nothing. Three costs worth knowing in advance: players believed the extras came with the game and
**our package was the source with nobody able to tell**; the input hooks and the actor enumerator
became **live suspects in a later crash hunt**, a cost paid repeatedly; and a cheat manager landed
in a speedrunner's game uninvited, which for some users is worse than a bug.
[packaging/README.md](../../packaging/README.md) and `agent_docs/verified.md` have the full account.

**The same rule has a second half: install ADDITIVELY.** A package should go on top of whatever
the player already has, never through it. Two failure modes, and the first is easy to miss:

- **Never ship a framework's mod list or registry.** If the framework keeps a central list of
  enabled mods, shipping your own copy overwrites the player's and silently unlists everything else
  they had. Check whether your mod even needs an entry — a C++ UE4SS mod does not, because the
  loader discovers it by scanning for a `dlls` folder — and if it does not, ship no list at all.
- **Be explicit about what you DO overwrite.** Bundling the framework runtime so a fresh install
  works in one drag also means replacing that runtime, and its settings file, for someone who
  already had it. That is a fair trade only if it is stated: say which files those are, and give
  the one folder a player with an existing setup can copy instead.

**And a third half, at runtime rather than install time: work whether you load before or after
anything else.** Coexistence is not only about files. An adapter must not depend on being first,
last, or alone:

- **Do not rely on load order.** If the framework has one, your mod must behave the same at any
  position in it. Needing a particular slot means needing every other mod to cooperate, which they
  will not.
- **Do not assume you are the only thing touching the game.** Another mod may already have hooked
  the function you want, spawned actors into the world you enumerate, or changed the very menus and
  values you read. Read defensively and fail quietly rather than asserting the world is untouched.
- **Restore anything you temporarily change**, in the same call if possible. Pseudoregalia clears
  `AutoPossessPlayer` on a class default object to stop a spawned ghost stealing the controller,
  and puts it straight back — the whole window is one synchronous call — precisely so any other mod
  spawning that class is unaffected.
- **Leave no trace when removed.** Deleting your folder should return the game to how it was.

The test to apply: *if a player installs a randomiser tomorrow, does anything I did stop it
working — and does anything it does stop me working?* Both directions matter, and the second is the
one that gets discovered by a confused user rather than by you.

Practical checks when packaging a new game:

- **Whatever the framework's own installer or `assets/` folder gives you is a starting point, not a
  manifest.** Copy deliberately, file by file, never `xcopy /e` over a directory you did not audit.
- **Work out how your own mod is actually loaded**, and ship only that path. If it loads without
  being listed in a config, do not ship the framework's populated config — ship an empty one with a
  comment saying why.
- **Turn off developer-facing defaults.** Frameworks ship consoles and overlays enabled because
  their audience is mod developers; your audience is players.
- **State what you did NOT stage, in the staging script**, so the next person does not "fix" the
  omission by restoring a blanket copy.
## Hard rule: never write a save, and never write game state

**Read the game; do not change it.** No save writes, no save-state editing, no writing values back
into the running game to "make the ghost work". That holds for your own player and for every peer,
and it holds for features not yet imagined.

Two reasons, and the second is the one that will actually be tested:

1. **It is the promise players judge a mod on.** "Will this corrupt my save" is the first question
   anyone asks about installing something into a game they care about, and a single incident is
   unrecoverable reputationally in a way a crash is not.
2. **The temptation arrives with capability, not with intent.** The relay now offers reliable
   ordered events, exclusive locks, both-or-neither exchanges, and — since 2026-08-17 — **custody
   of a room's world**: it holds the latest opaque blob per entity and hands the whole set to
   whoever takes the authority lease next
   ([agent_docs/beyond-cosmetic.md](../../agent_docs/beyond-cosmetic.md)). The moment an adapter
   wants a trade, "the exchange committed, so just write the item into the save" looks like the
   obvious last step. It is the exact step this rule forbids. **Custody is the sharper form of it,
   and the one to watch**: the relay hands a new host a *canonical* world, so "I am the host now, so
   write it in" reads less like cheating than like correctness — and it is the same forbidden step.
   An exchange committing, or a world being adopted, is a fact about the *relay*; what a game does
   with that fact is a per-game decision that has to pass the memory-write gate in
   [agent_docs/plans.md](../../agent_docs/plans.md), on its own, with an ADR.

Reading is unrestricted, and so is drawing: spawn actors, draw overlays, pose clones, play
animations. The line is at persistence and at authoritative game state, not at pixels.

### The one carve-out: dev-only test tooling may cheat

**The rule above governs what SHIPS. It does not govern a probe.** Added 2026-08-18, on the user's
call — *"this is during dev/testing i don't care about my save files. its fine/expected. but a
release should obviously still never touch/affect a save file"* — because without it stated, the
"never, ever" reading blocks the tooling that makes testing affordable, and a future session would
correctly refuse to build it.

Reaching a state the adapter cannot yet handle — surfing, a bike, the far side of the map, eight
badges — costs an hour of play per attempt otherwise. A dev probe may write whatever it takes,
including save data (`adapters/emulator/pokemon/emerald/probes/testkit.lua` is the worked example).

The carve-out is narrow, and each clause is load-bearing:

- **A probe, never an adapter.** It lives in `probes/`, it is never imported by the adapter, and it
  is never copied into a release. The adapter's own writes stay cosmetic.
- **The tester's own save, knowingly.** It is their file and their call. Say plainly, in the script
  and when handing it over, that it persists if the game is saved — the difference between this and
  the adapter's live-RAM writes is exactly that these survive a reset.
- **Verify the address, do not trust a code.** Published cheat codes are untrusted input; decode
  them and look the address up in the decomp first. Two live traps are recorded in
  `agent_docs/pitfalls.md` — a Gold/Silver code that writes into the object array Crystal spawns
  ghosts into, and BizHawk accepting a GBA code it could not decrypt and running the garbage.

**Nothing here relaxes the shipped rule by one inch.** If a probe's capability starts looking
useful to the adapter, that is the memory-write gate in `agent_docs/plans.md`, with an ADR — not a
file move.

## Hard rules, restated (unchanged from [agent_docs/contract.md](../../agent_docs/contract.md))

Root `CLAUDE.md` is always loaded and already carries the bridge-only rule and the
`area_id`/`anim` opacity rule, so they are not restated here. The one that lives only in the
contract:

- Coordinate systems (Y-up vs Z-up, tile vs world units, pixel origins) are normalized inside
  the adapter, never in the core.

## Anything a renderer must draw SMOOTHLY has to ride in `position` — not in `extras`

**The single most expensive lesson of Crystal's phase 9, and it is not Crystal-specific.**

`position` is `[]float64`, **variable length by design** — two components for Emerald, three for
Pseudoregalia, up to eight — and the core interpolates **every component** (`core/interp.go`,
`for i := range pos`). `extras` is **opaque by contract** and is not interpolated at all: it passes
through latest-wins.

So a renderer that combines an interpolated value with an `extras` value is mixing two terms that
describe **different instants**, once per frame. That is a stutter by construction, and no amount of
filtering downstream can remove it — the two inputs disagree.

**Crystal shipped exactly that and nobody saw it**, because the dev rig
runs `-interp=0ms` (deliberately, so 1:1 can be judged) and **with interpolation off the two terms
agree**. The fault only exists at the shipped interpolation delay, which is the one configuration
nobody was testing. Measured when it was finally looked at: of 1911 messages at shipped settings,
**1838 carried no movement at all** and the 72 that did jumped 4–6px.

**So, for a new adapter:**

- **Sub-tile position, sub-pixel position, orientation angles — anything continuous — goes in
  `position`.** Add components; that is what variable length is for. Send absolute quantities, not
  offsets: a tile index plus an offset-from-destination cancel at a boundary when interpolated
  independently, because the tile rises by one exactly as the offset falls by a tile's width.
- **`extras` is for facts that are already discrete** — a sprite id, an action byte, a stride index.
  Something that changes once per step is fine there; something that must change every frame is not.
- **Do not ask the core to interpolate `extras` instead.** That would make the core inspect
  game-specific payload, which is the exact thing the adapter/core split exists to prevent, and it
  would change every game to fix one.

## Judge a renderer at the SHIPPED settings, not only at the dev rig's

The corollary, and it cost a whole session. `-interp=0ms` and a fast send rate exist so a
side-offset ghost can be judged 1:1 against the player — that is a real and necessary mode. But it
**removes the mechanism the shipped configuration relies on**, so a class of fault is invisible in
it. A tier confirmed perfect at `-interp=0ms` was independently described as *"really really bad"* at
the shipped 250ms, with no code change in between.

**Give every game a dev core script per mode** (`dev-scripts/run-core-<game>.bat`), and say in the
handover which one is running. Crystal had none, so every session silently got shipped defaults from
an autostarted core while everyone assumed otherwise — and two rounds of renderer work were spent
chasing what turned out to be the interpolation delay. **Before judging a renderer, print what the
rig is actually running and read it.**

## When a renderer looks wrong, measure THE WIRE before touching the renderer

Both faults above presented as "the drawn ghost looks bad", and both were fixed without the drawing
code changing at all. The order that works:

1. **What arrives?** Count how the peer's position changes between consecutive messages, at the point
   they arrive, unconditionally. Smooth motion that is not on the wire cannot be drawn.
2. **What is derived from it?** Each term the renderer builds, per frame.
3. **What reaches the screen?** Only then the painted result.

Measuring (3) first is the natural instinct and it cannot distinguish any of the three.

## Hard rules: ghost speed, and the tier handover — moved

Both in [../CLAUDE.md](../CLAUDE.md). In one line each: **never move a ghost faster than the game
moves, or in units the game does not use**; and **a tier handover is a POSITION handover** — it
needs the two tiers to agree on where the ghost is, plus a one-frame overlap.

## Send the QUESTION, not the engine's own byte — and let the engine generate the answer

Two rules that arrived together (Crystal's ledge hop, 2026-08-26) and are the same idea twice.

**When a state has a step function, hand the ghost that step function rather than copying the
fields it produces.** Crystal's hop was reproduced by walking the ghost and copying the peer's
sprite Y offset over the wire. Writing one byte — the engine's own jump step type — instead gave
both tiles, both halves of the arc, the correct pace and the ledge actually crossed, generated on
the receiver's clock. **A transmitted animation can arrive late, be sampled at the send rate, and
freeze on a dropped packet. A generated one has none of those failure modes**, because they exist
only as properties of the copy.

**Then the copy must STOP**, or you have two writers on one field — see the hard rule above. And
condition the stand-off on *both* the peer reporting the state and the ghost's own field, because
the two are not simultaneous: the peer enters the state several frames before its ghost is issued
the equivalent, and copying in that window is visible.

**Make the wire field a QUESTION rather than the peer's raw value, whenever the two sides need
different values.** Crystal's player hops on step type 9, which drives the camera; a ghost needs
step type 8. Had the wire carried the raw step type, copying it across would have been the obvious
thing to do and would have dragged the view around. Sending "is this peer hopping?" makes the
copy-the-byte bug *unavailable* rather than merely discouraged. Reserve raw opaque bytes for the
cases where both sides genuinely want the same value.

## A flag that GROUPS things is not a flag that IDENTIFIES one of them

Before using any flag as an identity test, grep the table that assigns it and ask **"what else sets
this?"** Crystal's `EMOTE_OBJECT` reads as "this is an emote" and is set by the emote, the jump
shadow and the screen shake alike — it means "attached decoration object". Scanning on it put a
"!" over every hopping ghost.

**Prefer a field the engine MAINTAINS to one it merely initialises.** The discriminator here was
the action byte, rewritten every tick by each object's own movement function, so it cannot drift —
unlike anything written once at spawn.

## Ask the CARTRIDGE what it can do, not the build's name

A patch may add a capability the base game lacks, so the wire carries a state no single-player
session can reach: **a peer whose game can do something yours cannot.** Read the ROM for the thing
itself — find the game's own table by its content signature and count it — never branch on the
build's name, which cannot answer for a build nobody has measured. **Ask it of YOUR ROM on behalf of
the PEER**, beside the write. **What the engine cannot do, a renderer above it usually can** — a
tier-decision term, not a clamp. And **an index is not portable**: hash the table, send that with
the index, honour it only on equality. Crystal: `crystal/UNVERIFIED.md`, 2026-08-26.
