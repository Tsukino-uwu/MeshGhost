# Adapter template

**First written 2026-08-11**, at the end of Phase 5, and kept current since with what the three
shipped adapters learned the hard way (last swept 2026-08-16). The core was proven to run against a fake
adapter (`cmd/meshghost-fakeadapter`, a ghost that walks in a circle, driven by
`core.RunAdapter` — see [agent_docs/verified.md](../../agent_docs/verified.md)'s Phase 5 entry)
with no game attached and no import of anything under `adapters/`. This folder is what that
phase promised to leave behind: a reusable starting point for the next game's adapter, not code
to run as-is.

## What's here

- [PROTOCOL.md](PROTOCOL.md) — the three-function contract (`get_local_state` /
  `render_remote` / `despawn_remote`) and the tick model, written language-agnostically
  (pseudocode, wire envelope examples), because the next game (TEVI, Phase 6) is Unity/C#, not
  BizHawk Lua — a Lua-specific stub would not transfer. Every real adapter, in any language,
  implements this same shape by speaking the bridge wire protocol (`internal/bridge/bridge.go`);
  nothing here is Go-specific.
- The `core.Adapter` Go interface (`internal/core/core.go`) is a *different* thing: an
  in-process shortcut used only by `cmd/meshghost-fakeadapter` and Go tests
  (`internal/core/core_test.go`'s `TestRunAdapterInProcess`) to drive the core without a socket
  at all. A real adapter — including TEVI's — never implements it; it dials the bridge and
  speaks NDJSON, exactly like `adapters/pokemon/emerald/phase4_multiplayer.lua` does. See
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
   `.github/workflows/release.yml`'s assemble job, under `games/<publisher>/<game>/` — nothing
   under `adapters/` is picked up automatically. See
   [packaging/README.md](../../packaging/README.md)'s "Adding a game to the release" for the
   pattern (and its TEVI section if the adapter needs a build step, not just a file copy,
   before it's shippable). A *compiled* adapter is four things, not one: a
   `dev-scripts/build-<game>.bat` that stages its output into `packaging/release/games/...` and
   writes a `built-from.txt` SHA-256 record, the build output committed to the repo (CI can't
   build these), its own staleness-verification step in `release.yml`, and a hand-written
   `README.txt` for the game folder that nothing generates.

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
- **A shortlist, not everything.** 58 effects at 3s each is three minutes of mostly level dressing,
  and a person cannot track that. Filter by name substring to something under about a dozen. The
  filter should be widenable, not a hardcoded list of names you already picked — the entire point
  is finding things nobody has named.
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
short of spawns at all — see the cost warning below for what was actually wrong. *"This mechanism
is real"* and *"this mechanism explains my bug"* are separate claims and need separate evidence.

### The cost warning: a probe can break the effect you are measuring

This is the single most expensive lesson in this repo, and it belongs here because it is a *method*
failure, not a game-specific one. Full incident in
[agent_docs/pitfalls.md](../../agent_docs/pitfalls.md), "The diagnostics were the bug".

A per-tick enumeration of live objects, with a name lookup or string conversion per object, is far
more expensive than it looks — and if the engine spawns the effect you are studying as a *countdown
across ticks*, stalling the game thread truncates the very bursts you are trying to count. In
Pseudoregalia that produced an intermittently missing trail while **four separate metrics reported
exact parity**, because every object that survived was correct and only the destroyed ones were
absent. A second probe made it worse by *spawning* the same kind of object it measured.

So, when instrumenting an effect:

- **Compare by pointer, not by name.** The enumeration itself was affordable; the per-object
  `GetFullName()` and UTF-8 conversion were not. Comparing an object reference against a known
  component pointer is nearly free.
- **Keep probes off by default and re-test with them off** before believing any result. Never leave
  a probe that *spawns* the effect enabled while judging that effect.
- **Prefer edge-triggered logging** to per-tick, and treat any figure gathered while a heavy probe
  was live as suspect afterwards.
- **If a human keeps reporting a difference your metrics deny, suspect the metrics.** Agreement
  between two sides measured by one instrument is not correctness — a shared blind spot makes them
  agree and describes neither.

### Two more probe traps

- **A probe that returns nothing is a result, not a malfunction.** Ask what a genuine zero would
  mean before widening the net. Here, "no object ever disappeared" *was* the finding.
- **A sampling window that is too narrow produces a false negative indistinguishable from a real
  one.** One probe reported "0 new objects" every run and concluded the effect was pooled; the
  objects were in fact created slightly later than the sample and then persisted. What caught it
  was the *totals* printed beside the diff, climbing by exactly two each time. So: always print a
  **total**, not only the difference; diff **across** probes so anything appearing in a gap is
  still attributed; and never let a probe write its conclusion into the log ("likely pooled") —
  log the observation and conclude outside it, because a wrong conclusion in a log file outlives
  the run and gets believed later.

### If you are about to start effect work, read the playbook first

The two sections above tell you *what to build*: enumerate before guessing, mirror the decision
rather than the rule. They do not tell you how to run the hunt — what order to do things in, how to
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
inventing your own. Three things about it are worth knowing up front, because each was learned
the expensive way:

- **Give each game a `run-core-<game>.bat`, and test with `-interp=0ms -min-send=10ms`.** The
  core's default 200ms interpolation buffer smooths over real local timing bugs — treat "looks
  fine with the buffer on" as untested, not confirmed. (If you also start a relay locally, it
  needs `-send-hz=100` or it silently overrides every core's fast `-min-send`.)
- **Solo-test through `run-relay-loopback.bat`**, which echoes your own state back as
  `<id>-ghost`, and give loopback ghosts a **render-only** offset so you can tell the ghost from
  your own character — all three adapters do this (Emerald 1-2 tiles, TEVI 160 units,
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

## Hard rules, restated (unchanged from [agent_docs/contract.md](../../agent_docs/contract.md))

- The adapter may hold a socket to its own local core process (the bridge) and nothing else —
  never a relay address, never the relay protocol, never bytes off-machine directly.
- `area_id` and `anim` are opaque outside the adapter that produced them — compare by equality
  only, never build a cross-game vocabulary.
- Coordinate systems (Y-up vs Z-up, tile vs world units, pixel origins) are normalized inside
  the adapter, never in the core.
