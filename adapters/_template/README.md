# Adapter template

**First written 2026-08-11**, at the end of Phase 5, and kept current since with what the three
shipped adapters learned the hard way (last swept 2026-08-17, against `agent_docs/contract.md`,
`internal/bridge`, and the three shipped adapters' own docs). The core was proven to run against a fake
adapter (`cmd/meshghost-fakeadapter`, a ghost that walks in a circle, driven by
`core.RunAdapter` — see [agent_docs/verified.md](../../agent_docs/verified.md)'s Phase 5 entry)
with no game attached and no import of anything under `adapters/`. This folder is what that
phase promised to leave behind: a reusable starting point for the next game's adapter, not code
to run as-is.

## Hard rule: this folder is the gold standard, and it is never allowed to go stale

**Anything a shipped adapter learns belongs here too.** A new rule, a new file convention, a hard-won
trap, a new per-adapter document — when it lands in `pokemon/emerald/`, `tevi/` or `pseudoregalia/`,
back-port it to `_template/` in the same pass, not "later". The next game starts from this folder,
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
- [FLAGS.md](FLAGS.md) — the compile-time flag register: every switch sorted into shipped
  **behaviour**, **probe**, or **dormant** negative. Write it once you have more than a handful of
  flags; Pseudoregalia reached 56 without one and paid for it. It is the tie-breaker when a flag's
  comment and its value disagree, and the place where flags that only work as a *set* are marked.
- [PROTOCOL.md](PROTOCOL.md) — the three-function contract (`get_local_state` /
  `render_remote` / `despawn_remote`) and the tick model, written language-agnostically
  (pseudocode, wire envelope examples), because the game it was written for next (TEVI,
  Phase 6) was Unity/C#, not BizHawk Lua — a Lua-specific stub would not have transferred, and
  Pseudoregalia's UE4SS C++ mod after it proved the point twice. Every real adapter, in any language,
  implements this same shape by speaking the bridge wire protocol (`internal/bridge/bridge.go`);
  nothing here is Go-specific.
- The `core.Adapter` Go interface (`internal/core/core.go`) is a *different* thing: an
  in-process shortcut used only by `cmd/meshghost-fakeadapter` and Go tests
  (`internal/core/core_test.go`'s `TestRunAdapterInProcess`) to drive the core without a socket
  at all. A real adapter — including TEVI's — never implements it; it dials the bridge and
  speaks NDJSON, exactly like `adapters/pokemon/emerald/meshghost_emerald.lua` does. See
  [PROTOCOL.md](PROTOCOL.md) for why this distinction matters and where to look for a worked
  example of each.

## Folder convention

One folder per game, named after the game itself (`emerald`, `tevi`, `pseudoregalia`). Games
in the same franchise are grouped under a shared subfolder — `adapters/pokemon/emerald/`, and
a future `adapters/pokemon/platinum/` would go alongside it — purely for browsability as more
games get added; it's not a code-sharing boundary. A hypothetical Platinum adapter (NDS, a
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

**`README.md`, `BANDAGES.md` and `documentation.md` are expected of EVERY adapter, with no
exceptions.** Create all three when the folder is created.

**Probes and their logs go in a `probes/` subfolder, not at the top level.** Only what ships
lives beside the `.md` files — the adapter script itself and anything a release copies. A mature
adapter accumulates dozens of probe scripts and hundreds of log files, and at the top level they
bury the documentation that a reader actually came for: Crystal reached 25 scripts and 72 logs
within a day of being started, at which point its four `.md` files were genuinely hard to find in
the listing. **The probes themselves are committed and kept** — they are the record of how each
fact was established, and several have been re-run months-equivalent later against a patched ROM
to chase the same class of bug. **Their logs are not**: `.gitignore` covers
`adapters/**/*.log`, because once a run has been read its conclusions belong in `verified.md`,
not in a megabyte of raw text. Convention adopted 2026-08-18, on the user's ask, and applied to
Emerald and Crystal together.

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
months later. `_template/documentation.md` carries it as a `## Before adding anything to this file`
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
   loop), read `adapters/pokemon/emerald/meshghost_emerald.lua`. Its game-reading parts are
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
   content in the repo, and the rest of the file is the log of what the three existing adapters
   got wrong so you don't have to.
7. Follow this project's verification standard ([CLAUDE.md](../../CLAUDE.md)): no address,
   hook, or API call from memory — everything traceable to a source, and nothing in
   [agent_docs/verified.md](../../agent_docs/verified.md) until it's been watched happening on
   screen.
8. Do not modify `internal/core` or `internal/relay` for game-specific reasons. If something
   about the new game seems to require that, stop — it means either the contract needs a real,
   ADR'd revision (rare), or the adapter is trying to do something the boundary doesn't allow
   (much more likely).
9. When the adapter is actually ready to ship, add it to the release: give it its own step in
   `.github/workflows/release.yml`'s "Assemble release package" step, under
   `packaging/release/games/<game>/` (or `games/<franchise>/<game>/` if the game is grouped, as
   `games/pokemon/emerald/` is — the layout mirrors `adapters/`) — nothing
   under `adapters/` is picked up automatically. See
   [packaging/README.md](../../packaging/README.md)'s "Adding a game to the release" for the
   pattern (and its TEVI section if the adapter needs a build step, not just a file copy,
   before it's shippable). A *compiled* adapter is four things, not one: a
   `dev-scripts/build-<game>.bat` that stages its output into `packaging/release/games/...` and
   writes a `built-from.txt` SHA-256 record, the build output committed to the repo (CI can't
   build these), its own staleness-verification step in `release.yml`, and a hand-written
   `README.txt` for the game folder that nothing generates.
   **If the adapter autostarts a core** (see [PROTOCOL.md](PROTOCOL.md)), check where it installs
   first: a mod that drag-and-drops *into the game's own directory tree* has nothing pointing back
   at the unzipped release folder, so `meshghost.exe` and a client-only `config.json` have to ride
   along in the mod folder — TEVI and Pseudoregalia both do. An adapter loaded from the release
   folder itself (Emerald) reaches the root exe and config with no second copy. The duplication is
   forced by the install model, not chosen; don't copy it to an adapter that doesn't need it.

## First, work out what you will be able to READ

Do this before estimating anything. The three shipped adapters differed enormously in difficulty,
and the best predictor was not the engine, the language or the modding framework — it was **how much
readable source existed about the game before work started.**

| Adapter | Access model |
| --- | --- |
| Emerald | External source decompilation (`pokeemerald`) |
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

The most expensive lesson in this repo is that **a probe can break the effect it is measuring**,
and that four metrics agreeing with each other proves only that they share a blind spot. It applies
directly to the enumeration and spawn-detection work above, which is exactly the shape that got
costly. It lives in [probes.md](probes.md) with the rest of the probe method, and the full incident
is in [../../agent_docs/pitfalls.md](../../agent_docs/pitfalls.md), "The diagnostics were the bug".

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
   state — not evidence that the problem is unsolvable.** This one wrong inference parked the feature
   for days.
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
  core's default interpolation buffer (`core.DefaultInterpolationDelay`, 100ms) smooths over real
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
  your own character — all three adapters do this (Emerald 2 tiles, TEVI 160 units,
  Pseudoregalia 150). Offset for judging render quality, zero for verifying exact tracking;
  either way it never touches what goes on the wire.
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
  stale copy has invalidated whole test sessions twice.

## Writing the new adapter's own README

Give the game's folder a `README.md` with a **"How this adapter was built"** numbered list — the
short, readable version of the story, one step per thing that happened, ~2-4 lines each, in plain
language. See `adapters/pseudoregalia/README.md` for the worked example. Keep the detail
(field names, dump sizes, failed attempts, dated evidence) in `agent_docs/phases/phaseN.md`,
`verified.md`, and `pitfalls.md`, and link to them — a step that has grown into paragraphs of
caveats belongs there with a one-line pointer left behind. See [CLAUDE.md](../../CLAUDE.md)'s
hard rule on this.

**Also state the access model up top**, as a bullet alongside platform and adapter language:
**"How the game is read: ..."** — decompilation, self-documenting artifact, runtime reflection,
modding API, and so on, per the section above. All three shipped adapters carry this bullet. It is
the single fact that best explains why an adapter is the size and shape it is, it tells a reader
immediately how much of the code is discovery scaffolding versus feature work, and it sets
expectations for anyone picking the adapter up later.

**If the game is emulated, also carry a one-line bullet naming the exact roms or isos confirmed
working.** Use this layout verbatim — user-facing and direct, quoted names, nothing else:

```markdown
- Confirmed working roms: "Vanilla", "Archipelago 0.6.7".
```

(`isos` where that is what the platform uses.) `adapters/pokemon/emerald/README.md` carries the live
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
  confirmation was and when. All three shipped adapters open this way, and it is the line a reader
  checks first.
- **"Further work past 'good enough'"** — what is still open, with `agent_docs/status.md` named as
  the authoritative list. This is the section that stops the numbered story turning into a status
  file: anything still open goes here, not into a step. All three carry it.
- **"Custom features"** — anything this adapter does that isn't required of an adapter (TEVI and
  Pseudoregalia both have one). Keeps game-specific extras out of the build story.
- **"Dev tools"** — an index of the probe scripts the adapter accumulated. Emerald's dozen-plus
  probes are only findable because its README lists them; write this the moment you have more
  than two.

## Hard rule: a bandage fix is not a finished feature

**Default: no.** If the fix compensates for a value instead of causing it, forces state back after
something else changes it, or leans on a constant tuned until the screen looked right, it is not
done — however good it looks. **"Almost" and "good enough" are the words to watch for in your own
reasoning**; they are usually the moment the real mechanism stopped being investigated.

**The tell is mechanical, so you can check it without judgement:** does the fix *prevent* the wrong
thing, or *correct* it afterwards? Correcting afterwards means the cause is still running, and
something else will eventually read the state you patched.

**Why this is a hard rule and not a preference — two worked examples, one day apart:**

- **The camera fight-back outlived its cause and became the bug.** A ghost spawn made the game
  re-pick its camera, so the mod forced the view target back. It worked for that case and blocked
  every legitimate camera change forever after; players saw it as the ghost stealing the camera.
  The real fix, once measured, was one line: refuse a switch to a rig whose `OwningActor` is a
  ghost. Deleted 2026-08-16 — `verified.md`.
- **Bandages spread.** The slide floor-sinking fix moved the ghost's render Z by +43 because the
  ghost never ran the player's crouch logic, and `Plugin.cpp` went on to describe a *second* bug,
  the thrown weapon, as "structurally the same bug as the slide floor-sinking fix". One
  compensation taught the next one to exist. Replaced 2026-08-17 by driving the game's own crouch
  path on the ghost, which is what the ending makes this worth reading: the proper fix existed the
  whole time and the bandage is what stopped anyone looking for it.

**The narrow exception, and its price.** A temporary fix is allowed when it unblocks something else
that must be tested now — early bring-up, or getting a camera usable so a different feature can be
watched at all. When you take it:

1. **Say it is temporary in the code**, in the comment, where the next person reads it. Not in a
   commit message.
2. **Record the measurement that would replace it.** The slide entry in `ideas.md` is worth copying
   as a shape: it survived scrutiny because the comment already recorded what a slide does to the
   capsule, so the real fix starts from evidence instead of a fresh investigation. A bandage with
   *no* measurement behind it is the expensive kind — there is nothing to build the real fix on.
3. **Log it as an open item**, not as a finished one. A feature resting on a compensation is not
   done. It goes in this adapter's own `BANDAGES.md` (copy this folder's), and `status.md` should
   say so.

**You will not always know at the time**, which is why the register is a living file rather than a
thing you fill in once. `BANDAGES.md` in this folder lists the tells that only surface afterwards —
a fix whose cause got fixed elsewhere, a second bug described as "structurally the same bug as X",
a compensation that outlived its purpose and became the bug. Read it when auditing, not just when
writing.

**What this rule is not.** It does not mean every constant is suspect. A number measured from the
game and documented (the loopback ghost's deliberate sideways offset; a reconnect interval chosen
to match an observed cadence) is a design decision with evidence behind it. The difference is
whether the number came from *measuring the mechanism* or from *trying values until it looked
right*.

## Hard rule: find out how the GAME does it before you work around it

**Before writing anything that overrides, forces, corrects, or fights the game, observe what the
game itself does — read-only — and prefer using its own mechanism.** A workaround written without
that observation is a guess about a system you have not looked at, and in this project those have
consistently held up in the one case they were written for and broken everything adjacent.

The rule is not "never work around anything". It is: **the observation comes first, and the
workaround has to be aimed at what you actually saw.** Sometimes the answer really is a targeted
override — but you cannot target what you have not measured.

**Three times this was paid for here, all recoverable from `agent_docs/`:**

- **The Pseudoregalia camera.** Spawning a ghost made the game re-pick its camera. The fix forced
  the view target back to a remembered "known good" one. It worked for the case it was written for
  and nothing else: the game switches camera rigs *routinely* (three within milliseconds of
  entering an area — `phase7.md`), so once a ghost exists the mod fights every legitimate change
  the game makes, forever. Cutscenes and in-game resets were where it finally showed. The probe
  that broke the ORIGINAL bug open was read-only — a hook that logged what the game chose without
  overriding it — and that is the step that should have shaped the fix too.
- **The ultra-hop trail.** Predicting when the game would trail, and spawning our own, produced
  five rounds of nearly-right behaviour. What worked was giving up on predicting and letting the
  game's own spawns drive it — see the adapter README's steps 38-41.
- **`landed?` / `jumped?` vs `moveState`.** Mirroring these as if they were continuous state
  produced a ghost stuck in an airborne pose. They are one-shot pulses; the continuous fields are
  something else entirely. Nothing about the names said so — only watching the values did.

### Watch it before you PLAN against it, not just before you work around it

The rule above is usually stated as "observe before you override". It applies just as much to
**designing**, and that is easier to miss, because planning does not feel like changing anything.

**If a plan rests on a model of how the game behaves, capture the behaviour first — it is almost
always cheaper than the plan.** A read-only frame-by-frame capture of the game doing the thing
costs one live run. Building on a wrong model costs the implementation, the debugging, and the
correction of everything reasoned from it.

**The live case, 2026-08-18 (Crystal).** Moving a ghost was planned around an assumed model: that a
character's map coordinate updates when a step *completes*, so a ghost would be moved by writing
coordinates and letting animation follow. One read-only capture of an NPC taking a real step showed
the opposite — **the map coordinate is the destination and is set at the START**, in the same frame
as everything else, and the sprite then slides to catch up over the following ~16 frames. Every
frame after the first is the engine's own work. The plan built on the wrong model would have
produced a character that teleported while looking like it was walking, and the bug would have been
blamed on smoothing.

**The tell that you are planning on an assumption**: you can describe what the game does, but you
cannot point at the run where you watched it. That is the moment to spend one capture.

And when the capture contradicts you, **say so plainly in the write-up** rather than quietly
adopting the new model — the wrong assumption is worth recording, because the next person will
arrive with the same intuition.

**What "observe first" looks like in practice**, cheapest first:

1. **Log what the game does, changing nothing.** A read-only hook on the function you were about
   to override, printing what it was called with and what it chose.
2. **Ask whether the game already has a mechanism** that does what you want (`README.md`'s "Ask the
   game what it has, before you guess at what it might have").
3. **Only then decide** whether to use its mechanism, or to override — and if you override, aim at
   the specific condition you observed rather than at the symptom.

**The tell that you are about to write a bandage:** the fix restores, forces, or remembers a value
rather than preventing the thing that changed it. That is not automatically wrong, but it means you
are treating a symptom, and it should be a deliberate choice you can defend — with the observation
that justifies it — rather than the first thing that made the screen look right.

### Did the game make this, or did you take it? — the question that decides what you may do to it

The same object can arrive two ways, and which one it was determines what is safe to do with it
later. This is worth deciding **explicitly and writing down**, because the answer silently becomes
a constraint on every operation you perform on that object afterwards.

- **You asked the engine for it** — the game's own creation call, with the game's own class
  (in Unreal, `world->SpawnActor(pawn_class, …)`; the equivalent elsewhere is whatever the game
  itself calls to make one). It exists because you asked. It is a real instance of a real class,
  so **the game's own systems drive it for free** — animation, physics, state machines — which is
  usually the whole reason to want it.
- **You took something that already existed** and repurposed it. Nothing was created; a thing the
  level placed for its own reasons is now doing your job.

**Repurposing is the bandage, and its cost is not where people look for it.** The obvious cost is
appearance — a scenery object cannot animate and does not look like a character. The one that
bites is that **the object is still the game's**, so destroying it destroys part of the level,
hiding it leaves a hole where it used to be, and moving it may break whatever referenced it. You
inherit a permanent "never do X to this" rule, and the reason for that rule lives far away from
the code that eventually wants to do X.

That is exactly how this project acquired one. Pseudoregalia's ghost was first a hijacked
`StaticMeshActor`; the resulting "never destroy the ghost" rule long outlived the design, and when
the adapter later switched to spawning a real pawn clone, **nobody re-tested the constraint** — a
workaround was still running against a premise that had stopped being true. See
`agent_docs/pitfalls.md`.

**There is a third option, and an emulator adapter usually starts there: draw over the top.** You
never touch the game's world at all — you paint on the frame from outside, and the game does not
know anything is there. Ranked by how much the game does for you:

| Tier | What it is | You get for free | You pay |
|---|---|---|---|
| **Create** | ask the game to make one, with a class it already ships | animation, collision, layering, occlusion, lifetime | you own the lifetime and must not leak it |
| **Borrow** | repurpose an object the level already placed | it exists and is valid | it is still the game's: no animation, cannot destroy, cannot hide |
| **Draw over** | paint on the frame from outside | nothing | you reimplement everything, permanently |

**"Draw over" is not automatically the wrong answer** — and this is the part worth getting right,
because the tiers are not a quality ranking. It is the correct answer when the tiers above are
blocked by something real, and the way to tell is whether you can name the blocker.

This project has one of each. Pseudoregalia's ghost moved **borrow → create** and should have
moved sooner; the constraint that kept it borrowing had quietly gone stale and nobody re-checked
it, which is the bandage described above. Emerald draws its ghost with overlay primitives and
**stayed there on purpose**: the create tier needs a spawn path that writes game state, which this
project refused outright, and the middle tier (sprite/VRAM injection) has a cited fragility —
a reference implementation's own comments show its fixed address needing manual re-tuning between
*vanilla* versions of the same game, before any ROM patch. See `agent_docs/ideas.md`.

**Updated 2026-08-17 — that blocker's premise has since changed, and this is the worked example of
the rule two paragraphs down.** The refusal was never absolute: `agent_docs/plans.md` phrased it as
the current posture, liftable per-feature by an ADR. Crystal's adapter did exactly that and moves
to **create** — spawning a real object event via the engine's own path (`architecture.md`,
2026-08-17). Note what did and did not change: the template's "never write game state" rule below
already permits *spawning* — the line is persistence and authority, not pixels — so what the ADR
actually bought was the cruder **mechanism** an emulator forces, writing RAM from outside the
process rather than calling an engine API from within it.
**So Emerald now has the stale assumption, not the stated blocker.** Nothing about its overlay is
wrong today, and it is shipping and proven; but "we cannot create, because writes are refused" has
stopped being true, and per point 4 below the constraint is due a re-test rather than continued
inheritance. Whoever picks Emerald up next should decide that deliberately instead of assuming.

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
   is still borrowed, and the bill arrives as an unexplained constraint months later.
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
rule** — an over-broad first draft of this section said "menus, intros, warps, cutscenes and
battles", and the user's correction (2026-08-18) is the version that is actually true:

- **ALWAYS blocked, no exceptions: anything before the player is in the world at all.** Title
  screen, main menu, file select, intro, the loading step itself. Here the world does not exist yet
  or is mid-construction — the object tables an adapter writes into are being built, and the data
  it reads is stale from before. **This is the case that is guaranteed for every game, and the one
  the gate exists for.**
- **Everything else is per-state judgment, and "hide it" is often the wrong answer.** In-game but
  not free-roaming covers a wide range: a pause menu, dialogue, a shop, a cutscene, a battle. The
  useful questions are *does the game still render the overworld in this state* and *is the object
  table stable*. A pause menu drawn over a still-visible overworld is a state where leaving the
  ghost alone looks right and removing it looks like a bug. A battle that replaces the screen
  entirely makes the question moot. **Decide per state, with a reason you can state**, rather than
  blanket-hiding because it feels safer.

> **Two different questions, and this section only answers the first.** They are easy to conflate
> and the wording above did until it was caught, 2026-08-18:
>
> 1. **"*I* am not in the overworld"** — a menu, battle or cutscene on **this** machine. Then no
>    peer's ghost may be drawn or spawned here, full stop. That is this section.
> 2. **"*a peer* is not in the overworld"** — they entered a battle or a menu in **their** game.
>    That is a **design decision, not a safety rule**, and it belongs with the adapter's presence
>    semantics rather than here. Their ghost is not dangerous; the question is what it should
>    honestly represent.
>
> **Question 2 has a known failure mode already shipped in this repo**, so decide it deliberately:
> if a peer simply stops sending while unavailable, the last thing you drew stays exactly where it
> was, forever, looking like a player standing still. That is `status.md`'s TEVI FullMap entry —
> the marker only refreshes on a `render_remote`, so a peer who stops sending leaves it frozen.
> **A frozen ghost is a lie about where someone is**, and in a game with frequent multi-minute
> battles it is a lie told often.
>
> Options, none of which is automatically right: keep the ghost where it was (simple, and honest
> enough if peers stay in the same area), hide it while they are away (truthful, but ghosts
> flickering in and out is its own annoyance), or keep it and mark it as away — which needs the
> peer to *say* they are unavailable rather than merely going quiet. **Whichever you choose,
> "stopped sending" must be distinguishable from "standing still"**, because the two look
> identical to the receiver and only one of them is true.

**It is not only cosmetic, which is the part that gets underestimated.** In those states the game
is frequently *rebuilding* the very structures an adapter touches — object tables, sprite slots,
the map. Writing into them mid-rebuild corrupts rather than merely embarrasses, and an adapter that
only draws can still read half-initialised data and render nonsense from it.

**Ask the game what state it is in. Do not infer it from whether the data looks plausible.** This
is [CLAUDE.md](../../CLAUDE.md)'s "a wrong read returns a plausible number" applied to program
state: on a menu, the position and object data are usually just *stale*, so they look perfectly
reasonable and a data-shape check sails through. The signal you want is the game's own state
machine or mode variable.

Worked examples, both real:

- **Emerald** reads the current callback pointer (`gMain.callback2`) and compares it against
  `CB2_Overworld` — literally "which state machine is the game running right now". Its
  `inOverworld()` gate exists because reading save-block pointers outside the overworld returned
  plausible garbage.
- **Crystal** has `wMapStatus` (`START`/`ENTER`/`HANDLE`/`DONE`), plus `wMapEventStatus`,
  `wScriptRunning` and `wGameLogicPaused` — a map state machine and separate "is the player free to
  act" flags. Characterised with a dedicated probe rather than assumed
  (`adapters/pokemon/crystal/probes/ingame_gate_probe.lua`).

**How to establish it for a new game:**

1. **Write a change-only probe and start it on the title screen**, before loading anything. That
   state is the one you most need characterised and the one you cannot return to without a reset.
2. **Walk the whole lifecycle in one run**: menu → load → intro → overworld → open a menu → change
   area → battle → back. A gate is only trustworthy once you have seen it *refuse* correctly, not
   just accept correctly.
3. **Log what the proposed gate WOULD have decided at each moment**, alongside the raw values. That
   turns "does my gate work?" into something readable rather than something argued about.
4. **Prefer several cheap signals combined** over one clever one, and state what each is for.
5. Note this is *related to but distinct from* `get_local_state()` returning "don't send this
   frame" (see [PROTOCOL.md](PROTOCOL.md)). That one suppresses your own outbound state; this one
   governs whether a peer's ghost may exist locally at all. **You need both**, and they can differ:
   it is reasonable to stop sending the moment a menu opens while leaving an already-spawned ghost
   alone until something more disruptive happens.

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

## Hard rule: ship the bare minimum, and nothing else

**A release contains exactly what the adapter needs to run, and not one file more.** TEVI is the
model — it ships a single DLL. If a modding framework, runtime or SDK comes with extras, stage the
parts your adapter actually loads and leave the rest behind.

This is not tidiness or download size. Anything bundled is something **installed into a stranger's
game by someone who only asked for a visual ghost overlay**, and it is your responsibility whether
or not you wrote it.

Found live 2026-08-17, in Pseudoregalia. Its packaging staged RE-UE4SS's whole stock `Mods` folder
with a blanket `xcopy`, which shipped — **enabled** — a cheat manager, a console, console commands,
keybind hooks, an actor dumper, a line-trace tool. None were used by the adapter, which is a C++
mod loaded from its own folder and listed in neither loader file. Three costs, in increasing order
of seriousness:

1. The user believed those mods came with the game. They did not; the game ships no modding
   framework at all. **Our package was the source, and nobody could tell** — including, for a
   while, the person who packaged it.
2. Two of them hook keyboard input and one enumerates actors, so when a hard crash was investigated
   they were live suspects that had to be ruled out. **Bundled extras become confounders in every
   later bug hunt**, and you pay that cost repeatedly.
3. A cheat manager and a console went into a speedrunner's game uninvited. For some users that is
   worse than a bug.

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

## Hard rules, restated (unchanged from [agent_docs/contract.md](../../agent_docs/contract.md))

- The adapter may hold a socket to its own local core process (the bridge) and nothing else —
  never a relay address, never the relay protocol, never bytes off-machine directly.
- `area_id` and `anim` are opaque outside the adapter that produced them — compare by equality
  only, never build a cross-game vocabulary.
- Coordinate systems (Y-up vs Z-up, tile vs world units, pixel origins) are normalized inside
  the adapter, never in the core.
