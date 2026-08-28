# Access models: how each adapter reads its game

<!-- line-cap: 550 -- enforced by dev-scripts/preflight.ps1. Over it? Something comes out first. -->

**What this is for.** Before writing an adapter you have to answer one question: *what can I actually
read about this game?* The answer sets how the work will go more than the engine, the language or
the modding framework does — and the four shipped adapters differ enormously because they sit in
three different places on this list (the two BizHawk Pokémon adapters share one).

This file is the reference. [`adapters/_template/README.md`](../adapters/_template/README.md) links
here rather than repeating it, and each adapter's own README states its model in a
**"How the game is read:"** bullet at the top.

## What each adapter used

| Adapter | Engine / platform | Access model | What it meant in practice |
| --- | --- | --- | --- |
| [Emerald](../adapters/emulator/pokemon/emerald/README.md) | GBA, via BizHawk | **External source decompilation** — [`pokeemerald`](https://github.com/pret/pokeemerald) | Player X/Y, map bank/number and camera offset were *looked up*, not reverse engineered. Addresses cited to the decomp. 37 build-story steps, and the first adapter the user has called feature complete (2026-08-21). |
| [Crystal](../adapters/emulator/pokemon/crystal/README.md) | GBC, via BizHawk | **External source decompilation** — [`pokecrystal`](https://github.com/pret/pokecrystal), built locally and hash-verified byte-identical to the ROM | Same model as Emerald with one difference that mattered: Crystal's RAM labels live in the assembly rather than in C, so the *build* is the source of addresses, not a header. That authority is what made writing (spawning) defensible rather than guessing. Archipelago's build gets its own separately measured table. 6 build-story steps. |
| [TEVI](../adapters/tevi/README.md) | Unity (Mono), BepInEx | **Self-documenting artifact** — `Assembly-CSharp.dll` decompiled locally with ILSpy | Real class and field names, and the adapter *compiles against them*, so a wrong name is a build error. Fastest adapter by a wide margin: ~1 hour to a following ghost, 9 steps, ~1,200 lines. |
| [Pseudoregalia](../adapters/pseudoregalia/README.md) | Unreal Engine 5, UE4SS | **Runtime reflection only** — plus a Blueprint-only reference mod for scattered facts | No readable source exists anywhere. Every property, class and function is a name string resolved live; a wrong name returns nothing or something plausible. 44 steps, ~12,000 lines, and the most `pitfalls.md` entries of any game. |

The size difference between TEVI and Pseudoregalia — roughly 10x the code — is mostly **not** the
engine being harder. It is having nothing to read. Most of that extra code is discovery scaffolding:
enumeration probes, reflection dumps, and the instrumentation described in
[effect-investigation.md](effect-investigation.md).

## The full range, best to worst

> **Provenance, because it differs by entry.** The entries marked **Used here** are what this
> project has actually done, and the pros/cons for those are from experience. **The rest are general
> industry approaches written from background knowledge, not from experience on this project** —
> recorded so a new game is not forced into the hard tier by default, but treat their details as
> unconfirmed until a real game is checked against them. That is the standard
> [CLAUDE.md](../CLAUDE.md) applies to addresses and APIs: a tidy-looking list is a starting point
> for research, not a finding. Nobody here has yet worked against a modding API or a shipped `.pdb`.

| # | Approach | Used here |
| --- | --- | --- |
| 1 | Official modding API / SDK | — |
| 2 | External source decompilation | **Emerald** |
| 3 | Self-documenting artifact (managed bytecode) | **TEVI** |
| 4 | Debug symbols | — |
| 5 | Runtime reflection | **Pseudoregalia** |
| 6 | Community artifacts | Pseudoregalia, partly |
| 7 | Static RE + pattern scanning | Indirectly (inside UE4SS) |
| 8 | Blind memory scanning | — |

### 1. Official modding API / SDK

The developer ships documented, supported extension points.

- **Pros** — Documented and intended to be used, so no reverse engineering at all. Stable across
  patches, which nothing else on this list is. Usually has real event hooks rather than polling.
  Existing examples and a community to ask. Legally the clearest by far.
- **Cons** — You only get what the developer chose to expose; the state you need may simply not be
  reachable. Often sandboxed or performance-limited. Can lag behind the game itself after an update.
- **Here** — Not yet seen. Would be the easiest possible starting point and worth checking for first
  on any new game, because it changes the shape of the whole project.

### 2. External source decompilation

Someone else has reverse engineered the game to readable source.

- **Pros** — The most complete picture available: names, types, data layouts, *and the actual logic*,
  so you can read why the game does something rather than inferring it. Facts are citable, which
  makes them auditable later.
- **Cons** — Only exists for old or much-loved titles. Licensing is usually unclear or absent, so it
  is facts-only (see [licensing.md](licensing.md)). May target a different version or region than
  the copy you are running, and it drifts if the game is patched.
- **Here** — **Emerald**, via `pokeemerald`. Player X/Y, map bank/number and camera offset were
  looked up rather than discovered, and every address in [verified.md](verified.md) cites it.
- **The Pokémon family is one org, and one posture covers all of it.** `pret` maintains
  `pokered`, `pokecrystal`, `pokeemerald`, `pokefirered`, `pokeplatinum` and more; all carry **no
  licence file at all**, so a new title needs a date-check rather than a fresh assessment
  ([licensing.md](licensing.md)).
- **GB/GBC differs structurally from GBA: the decomp must be BUILT to yield any address.** Emerald
  could be read as C; Crystal cannot be read for addresses at all, because its RAM labels sit in
  *floating* sections (`SECTION "More WRAM 1", WRAMX`) that only get addresses at link time.
  Confirmed 2026-08-17 by building `pokecrystal` — see [environment.md](environment.md) for the
  toolchain and its one non-obvious trap, and [verified.md](verified.md) for the addresses. Budget
  a decomp build as a required first step for any Game Boy title, not an optional one.
- **A WIP or partial decompilation still beats no decompilation, and by a wide margin.** The
  user's framing, 2026-08-17, and it is right — but the reasons are worth stating so the
  expectation is calibrated rather than optimistic:
  - **For a C decomp, the source is useful immediately, unbuilt.** Struct layouts, field names and
    function names all read straight off. Only *absolute addresses* need the link step. (This is
    where GB differs — see the bullet above — because its RAM labels carry no layout information in
    the source at all.)
  - **Partial naming is partial, not uniform.** Expect properly-named subsystems sitting directly
    beside undecompiled ones. `pokeplatinum` shows both in the same headers: `FieldSystem`,
    `BerryPatchManager` and `TownMapContext` are named, while `sub_0209BA18` is not.
  - **The unnamed functions are themselves a source of addresses.** A `sub_<address>` name embeds
    the very thing you would otherwise be hunting for. An undecompiled region is a *labelled* gap,
    which is far better than an unlabelled one — you know where it is and can watch it directly.
  - **What it costs you is the top row of the pain table below**: the guarantee that a wanted fact
    exists at all. A complete decomp answers "where is player position" definitionally; a WIP one
    might not, so **check coverage for the specific fields an adapter needs before treating the
    game as tier 2**, rather than after committing to a toolchain install.
- **Approved pattern — do not read the strictness above as discouragement.** Consulting a
  decompilation for facts is explicitly fine and is how Emerald was built. The unclear licence
  constrains what may be *committed*, not whether it may be *read*. Read it, cite the fact, write
  your own implementation, keep none of its source. That is settled, and proven by a shipped adapter.

### 3. Self-documenting artifact — managed bytecode

The shipped binary is .NET/Mono, Java or Python bytecode, which decompiles back to source.

- **Pros** — Derived from the exact build you are running, so it cannot be out of sync. Real class
  and member names. **You can compile against it, so a wrong name is a build error** — the single
  biggest practical advantage on this list. Excellent free tooling (ILSpy, dnSpy, JADX).
- **Cons** — Only applies to managed runtimes. Obfuscation can strip names to nonsense. IL2CPP/AOT
  compilation removes the whole advantage. Decompiled output is still the game's copyrighted code,
  so it is read for facts and never committed. A game update changes the assembly and needs re-checking.
- **Here** — **TEVI**, `Assembly-CSharp.dll` via ILSpy. The easiest model the project has used, and
  the direct reason that adapter took about an hour to a following ghost.
- **Approved pattern.** Decompiling the user's own local copy to read names, and referencing that
  local DLL via a gitignored `HintPath`, is fine and is how TEVI was built. Neither the DLL nor the
  decompiled output is committed; only our own code is. The one consequence to accept going in is
  that CI cannot build it — see the cost note below.

### 4. Debug symbols — shipped `.pdb`, or a public symbol server

Native code, but with the developer's own names attached.

- **Pros** — Real function and type names without reverse engineering. Works directly with
  debuggers. Much better than nothing on a native binary.
- **Cons** — Rarely shipped with retail builds. Public symbols are often partial — function names
  but no locals or full types. Tightly version-specific. You still need native RE skills to act on
  them; symbols tell you *what* something is called, not what it does.
- **Here** — Not yet seen.

### 5. Runtime reflection — the engine enumerates itself

A mod loader asks the running game what classes, properties and functions exist.

- **Pros** — Always matches the running build. Shows things no static source can: live objects,
  actual instances, real current values. **Enumeration means you can discover names you would never
  have guessed** — the technique that rescued Pseudoregalia. Often the only option that exists.
- **Cons** — **No compile-time checking: a wrong name returns nothing, or something plausible.**
  You see structure but not logic — Blueprint bytecode is not readable this way, so *why* the game
  does something stays hidden. Enumeration costs real time on the game thread, which has caused this
  project's worst regression. Names can change between game versions with no warning.
- **Here** — **Pseudoregalia**, via UE4SS: 276 name-string lookups, and no readable source anywhere
  to check them against.

### 6. Community artifacts — other mods, wikis, cheat tables, speedrun tooling

Facts other people already worked out, in whatever form they left them.

- **Pros** — Cheap, and often the fastest route to one specific fact. Someone may have already
  solved the hard part. Shows what is possible at all in a given game.
- **Cons** — Unverified, usually undated, and possibly for a different version. Licenses must be
  checked before reading anything. Scattered and partial. Can encode someone else's wrong
  assumption, which you then inherit and trust.
- **Here** — **Pseudoregalia**, partly: a Blueprint-only reference mod, read for which Blueprints
  exist. Being Blueprint-only, there was no source text in it to read even in principle.

### 7. Static RE + pattern scanning — Ghidra/IDA, AOB signatures

Reverse engineer the stripped native binary yourself, and locate code by byte-pattern.

- **Pros** — Works on anything, including fully native stripped builds, with no cooperation from the
  game. Well-chosen signatures can survive minor game updates.
- **Cons** — Slow and skill-intensive. A wrong match yields plausible garbage rather than an error.
  Brittle across updates and expensive to maintain. No names — you invent your own for everything.
- **Here** — Only indirectly: UE4SS uses `patternsleuth` internally to find engine functions, so
  Pseudoregalia benefits without the adapter doing any of it (confirmed 2026-08-16 against the
  pinned RE-UE4SS submodule — see [licensing.md](licensing.md); its pattern coverage is
  engine-version-specific, so a pin bump can change what resolves).

### 8. Blind memory scanning / black box

Find values by scanning for them changing, with no names or types at all.

- **Pros** — Needs nothing whatsoever: no symbols, no source, no mod loader. Fast for simple scalars
  like position or health.
- **Cons** — No names, types or structure. Addresses move between runs, so you need pointer chains
  to get anything stable. You can read values but not call functions, so triggering the game's own
  behaviour is off the table. Rework for every version. The floor of this list.
- **Here** — Not used. Worth noting Emerald *looks* like this from the outside — raw addresses in a
  Lua script — but is not: every address came from the decompilation and is cited, which is what
  makes it authoritative rather than a guess.

## What any of this means for a PUBLIC repo

> Not legal advice — this is the rule this project already follows, written down so it is checkable.
> The authority is [licensing.md](licensing.md); `.gitignore` is where it is enforced.

**The governing rule: nothing goes in this repo that could not be published.** The test is not "does
a license permit this?" but **"is this fine sitting in a public repo forever?"** Anything that is no
— or merely unclear — stays out, even where a license would arguably allow it. That is
**deliberately stricter than the licenses require**, so the repo never rests on a judgement call
about someone else's terms holding up later.

**The second half of the rule: the public repo must also WORK.** Clean is not enough — a user who
has only this repo plus **what they legitimately own** (their own game, ROM, emulator, Steam copy)
must be able to run MeshGhost. Nothing disallowed may be *required* to install or use it, and the
release must never depend on an artifact that cannot be published.

This is already what the committed mod DLLs are for, and it is the neatest resolution in the
project: building TEVI's adapter needs the user's own `Assembly-CSharp.dll`, which cannot be in the
repo — so the **build output** is committed instead, and an end user never needs that DLL at all.
The unpublishable artifact is required only by a developer rebuilding from source, who owns the game
anyway. Legally clean and fully functional, at the price of a staleness gate and the CLAUDE.md rule
about rebuilding after a source edit. Apply the same shape to any future approach with this problem.

**What that does *not* restrict is what you may read.** The approach is not the constrained thing;
the artifact is. All eight above are ways of *learning* about a game, and copyright restricts
*copying expression*, not knowing things. So the question is never "may we use decompilation?" but
**"what ends up in the repo?"** — and the answer is the same for every row on the list:

- **Facts may be used and recorded**: a memory offset, a field or function name, a struct layout, a
  colour value, an enum meaning. Record them with a citation ([verified.md](verified.md)) so the
  boundary stays auditable.
- **Expression may never be committed**: source text, data tables, decompiler output, disassembly,
  game assets, or structurally-identical code — **regardless of the licence, with no exception for
  a permissive one.** An earlier version of this line carved out "unless that licence explicitly
  permits redistribution and you attribute per its terms", which quietly reopened the door
  [CLAUDE.md](../CLAUDE.md) closes: the test there is not "does a licence permit this?" but **"is
  this fine sitting in a public repo forever?"**, and no-or-unclear means it stays out even where a
  licence would allow it. A permission is not a reason, and a carve-out is exactly what gets
  reached for at the moment copying looks convenient. Removed on the user's call, 2026-08-18.

That is [licensing.md](licensing.md)'s "facts and addresses, never code", and it is what makes all
four shipped adapters publishable despite two of them being built on unlicensed reference material.

### Per approach: what you may keep

| Approach | Safe to commit | Must never be committed |
| --- | --- | --- |
| 1 Modding API | Your own code against the public API; SDK headers only if its licence allows | Anything the licence does not permit redistributing |
| 2 External decompilation | Your own implementation, plus cited facts | Any of its source text or data tables. `pokeemerald` has **no licence at all** — strictest handling |
| 3 Managed bytecode | Your own code; a `HintPath` reference to a local file | **The decompiled output, and the game DLL itself.** TEVI's `Assembly-CSharp.dll` is the user's own local copy and is gitignored |
| 4 Debug symbols | Cited facts | The `.pdb`; it is the developer's material |
| 5 Runtime reflection | Your code, and summarised findings — e.g. `PLAYER_FIELDS.md` | Wholesale verbatim dumps; summarise instead |
| 6 Community artifacts | Facts, once the licence is checked **first** | Their source or assets. Several referenced here have no licence |
| 7 Static RE | Cited facts | Disassembly or decompiled listings. Byte signatures are a grey area — prefer describing what is matched |
| 8 Memory scanning | Addresses and layouts | Nothing much to copy; this is the cleanest by construction |

### Choosing an approach: does it need anything unpublishable to WORK?

The rule is not only a filter on commits — it is a filter on **which approaches to adopt at all**.
Before picking one for a new game, ask: *does making this work require the repo to contain something
that cannot be public?* If yes, either keep that artifact out (local, gitignored, user-supplied) or
do not take the approach.

| Approach | Needs anything unpublishable present? | Verdict |
| --- | --- | --- |
| 1 Modding API | No, unless the SDK itself cannot be redistributed | **Fine** — check the SDK's terms if vendoring it |
| 2 External decompilation | No — read it, take cited facts, keep none of it | **Fine** (Emerald, proven) |
| 3 Managed bytecode | **Yes, at build time** — the game DLL is needed to compile against | **Fine with care** — see the cost below (TEVI, proven) |
| 4 Debug symbols | No — read them, keep the facts | **Fine** |
| 5 Runtime reflection | No — everything happens at runtime on the user's own install | **Fine, and the cleanest** (Pseudoregalia, proven) |
| 6 Community artifacts | No — facts only, licence checked first | **Fine** |
| 7 Static RE + signatures | **Possibly** — byte signatures copied from the game would live in the repo | **Avoid, or describe the match rather than embedding bytes** |
| 8 Memory scanning | No — addresses are facts | **Fine** |

**The one real cost, already paid twice.** Approach 3 needs the user's own game DLL at build time, so
that DLL stays out of the repo and **CI cannot build the adapter**. The resolution here was to commit
the *build output* instead and add a staleness gate — which is exactly why TEVI's and Pseudoregalia's
mod DLLs are committed, why `dev-scripts/build-*.bat` exist, and why CLAUDE.md has a hard rule about
rebuilding them after a source edit. See [`packaging/README.md`](../packaging/README.md). Worth
knowing before choosing that approach: it is fine, but it buys a permanent maintenance obligation.

**Approach 7 is the only one on this list that can genuinely conflict with the rule**, because an AOB
signature is a literal byte sequence taken from the game binary. Nothing here uses it directly —
UE4SS does its own pattern scanning internally, which is its code and its problem, not ours.

**Assets are absolute, and separate from all of the above.** No ROMs, sprites, audio, models, `.pak`
or game binaries, ever — `.gitignore` blocks `*.dll`, `*.rom` and `*.gba` with a deliberate
allow-list for only our own build outputs, the MIT-licensed UE4SS runtime files, and Emerald's
vendored MIT-licensed Lua/LuaSocket pair (see [licensing.md](licensing.md) for each). Emerald's adapter *decodes*
the real Brendan/May sprite out of the player's own ROM at runtime; it does not ship one.

### The part that is genuinely unsettled

Two things sit outside copyright and are worth knowing rather than assuming:

- **EULAs frequently prohibit reverse engineering** even where copyright would allow the analysis.
  That is a contract question, not a copyright one, and it varies by jurisdiction — some
  interoperability-related reverse engineering is protected by statute regardless of EULA terms.
- **Anti-circumvention rules** (e.g. DMCA §1201) are a separate matter again, and bite if getting at
  the code means defeating DRM. None of the four games here required that.

Neither has been a live issue for this project — every game is owned by the author, nothing ships
game content, and no protection has been circumvented — but a new game could differ, so check rather
than assume.

### The mildly surprising conclusion

**Legal cleanliness and technical difficulty are not the same axis, and they partly run opposite.**
Runtime reflection and memory scanning are the hardest to work with and among the *cleanest* to
publish, because you are observing a running program rather than copying anything. Decompilation is
far easier to work with and needs the most care about what you keep. Pseudoregalia was the most
painful adapter to build and is the least legally fraught — nothing about it could have been copied,
because there was nothing to copy.

## The axis that actually predicts pain

More useful than the ranking above, because it is what makes a mistake cheap or expensive:

| Model | A wrong input produces | Cost |
| --- | --- | --- |
| Typed assemblies | A build error | Free — you cannot ship the mistake |
| Decompilation / symbols | A mis-transcription, re-checkable against a citation | Cheap, and auditable |
| Runtime name lookup | **Silence, or a plausible value** | Expensive — looks like the feature simply not working |
| Pattern / blind scan | Plausible garbage, and it re-breaks on every patch | Worst — can also look fine and be wrong |

This is the same hazard as [CLAUDE.md](../CLAUDE.md)'s rule that a wrong memory address returns a
plausible number rather than crashing. The bottom two rows are where it bites.

**It is the real explanation for Pseudoregalia's difficulty** — not UE5, not C++, not reflection as
such. Nothing ever told us we were wrong. Emerald's addresses are *unknowable but authoritative*:
you cannot invent one, and once the decomp gives it to you, you are right. Pseudoregalia's names are
the opposite — *discoverable but unverifiable*: anything is reachable by typing a plausible guess,
and nothing reports the mistake.

That is also why enumerating what a game contains is not a debugging technique on games like this.
**It is the substitute for having source.**

## How to find out, for a game you have not started

The list above does not need to be complete for this to work — you only need to know what *this*
game offers. Half an hour of checking beats guessing, and every answer is a citable fact.

1. **Does it have official mod support?** The game's own docs, its store page, whether it ships a
   mod folder or workshop integration. Best possible answer and the cheapest to check.
2. **What kind of binary is it?** Look in the install folder. `Assembly-CSharp.dll` means managed
   Mono (decompilable — TEVI). `GameAssembly.dll` means Unity IL2CPP (native; needs unhollowing).
   `*-Win64-Shipping.exe` plus `.pak` files means Unreal. A `.jar` means Java. This single detail
   largely determines everything else.
3. **Are there symbol files?** A `.pdb` beside the executable, or a public symbol server.
4. **Has someone already reverse engineered it?** A decompilation project, a modding Discord or
   wiki, existing mods, speedrun/practice tooling. **Check the license before reading any of it** —
   [licensing.md](licensing.md).
5. **Does a reflection-capable mod loader exist for the engine?** BepInEx for Unity, UE4SS for
   Unreal. This is the fallback that made Pseudoregalia possible at all.

Record the answers in the adapter's README as its **"How the game is read:"** bullet, and in
[environment.md](environment.md) with dates — installed tools and game builds drift, so an old
answer is a fact about that date, not a guarantee.

## What a hard access model predicts

If a game has no decompile and no symbols, expect this shape, based on Pseudoregalia:

- **The discovery phase dominates.** Budget for it as real work rather than treating it as overhead
  on the way to features.
- **Build the enumeration tooling early.** It was found late here, and the user's own conclusion
  afterwards was that doing it sooner would have saved a lot of time. It is the one investment that
  pays back on every subsequent feature.
- **Guessing names is seductive and expensive**, because a plausible name makes you confident while
  you are wrong, and each wrong guess costs a full build → deploy → play → watch cycle.
- **The tooling is the compensation, and it transfers.** The catalog probe, the world diff, the
  reflection dumps and the log-design discipline are all game-agnostic and would apply to the next
  Unreal title on day one — see [effect-investigation.md](effect-investigation.md).

## Emulated platforms — a category of their own, and the halves swap over

**Scoped 2026-08-17 in conversation. Nothing here is built or scheduled, and every API named
below needs confirming against its project's own documentation before anyone relies on it** — per
`CLAUDE.md`, an API from memory is not a fact.

Emulators do not fit the tier table above cleanly, because they split the problem in two and the
two halves have different answers.

**Reading is tractable on all of them, and that is a property of emulation itself.** The guest
machine's RAM is a contiguous buffer inside the host process — 32 MB for PS2, 24 MB MEM1 (+64 MB
MEM2 on Wii), 288 KB for GBA. No ASLR chase inside it, no GC moving objects, no packers. Compared
with scanning a native modern game this is the easy case.

**But what the bytes MEAN is still the ordinary tier question**, decided by the specific game's
reverse-engineering scene, not by the emulator. Emerald is tier 2 (looked up in `pokeemerald`,
every address cited). A well-studied GameCube title with a decomp could be equally cheap. An
obscure one is tier 8 and a differential hunt.

### The inversion worth knowing before picking one

**BizHawk solves both halves. The others solve only reading.**

| Emulator | Platform | Reading | Drawing | Licence note |
|---|---|---|---|---|
| **BizHawk** | GBA etc. | Lua memory API | **`gui.*` primitives** | Why Emerald exists at all |
| **PCSX2** | PS2 | **PINE** IPC — sanctioned external read/write (verify) | no equivalent API | GPL — a distributed fork carries obligations |
| **Dolphin** | GC / Wii | proven by **Dolphin Memory Engine** (separate open-source tool) | no mainline equivalent (verify) | GPL |
| **Cemu** | **Wii U**, not Switch | route unknown (verify) | unknown | open-sourced 2022, MPL (verify) |

So for anything but BizHawk, **the adapter's hard problem is rendering, not finding data** — the
opposite of every adapter this project has written. Options are hooking the emulator's renderer
(PCSX2 and Dolphin draw their own ImGui overlays, so there is something to hook), an external
transparent overlay window, or a fork. All three are real work, and the fork option collides with
GPL in a way the MIT/permissive tools we bundle today do not. `licensing.md`'s rule applies first:
read the licence before the source.

### One upside of the external route, added 2026-08-28

**An adapter that lives OUTSIDE the emulator gets its live-reload loop for free.** That matters more
than it sounds: `adapters/CLAUDE.md` makes building that loop a hard rule before the first feature,
and for every adapter so far it has been real work, because the adapter runs INSIDE its host — a
Lua script in BizHawk, a plugin in BepInEx, a mod in UE4SS — so reloading depends on what that host
offers. An external process reading memory over IPC has no such problem: it is our own program, so
restarting it is free and the emulator needs to support nothing at all.

It also sidesteps the host-scripting constraints this repo has already paid for elsewhere — Lua's
200-local ceiling, the per-line console cost, one shared Lua environment across every script.

**This does not change the ordering above.** Reading was never the hard half here; **drawing is**,
and an external process is no closer to drawing than anything else. Take it as a reason the
reading half is cheaper than it looks, not as a reason the adapter is.

### Dolphin has a wrinkle none of the others do: netplay already exists

Dolphin ships deterministic-lockstep netplay. That is the alternative `beyond-cosmetic.md` §7
describes, and §7 notes it is plausible *specifically* for emulated games because they are
deterministic where a modern engine is not. So for GC/Wii, "multiplayer" is not an open problem —
and a MeshGhost adapter there would be a **different product**, not a better one:

| | Dolphin netplay | MeshGhost |
|---|---|---|
| Worlds | one shared session, lockstep | independent copies |
| Requires | everyone in the same game, in sync | nothing; desync is expected and fine |
| Delivers | real co-op / versus | presence — where a friend is in *their own* run |

Two people doing separate single-player runs who want to see each other is something netplay
cannot do at all, because it is one session. That is the honest pitch, and it should be made in
those words rather than as "GameCube multiplayer", which sounds solved and is.

### Switch emulation fails this repo's own test, and not on difficulty

Yuzu shut down in 2024 after legal action, and Ryujinx was taken down later the same year. Forks
circulate; there is no maintained upstream in the sense BizHawk, Dolphin and PCSX2 have one.

The blocker is `CLAUDE.md`'s standing test — **"is this fine sitting in a public repo forever?"**
An adapter targeting an actively-litigated emulator with no upstream fails it twice: built against
something that can vanish, and it ties a public repo to a dispute it has no part in. The RE-scene
advantage also inverts — Switch titles are newer and less documented, so the per-game half lands
nearer blind scanning, the expensive tier.

### If an emulator adapter is ever picked up

**Dolphin looks strongest**: openly developed, long-lived, external memory access already proven
by a real tool, and genuinely deep per-game documentation for the titles anyone would want. PCSX2
next. Cemu plausible once its API question is answered. Switch: no.

Order of work, cheapest question first:

1. **Licence check** on the emulator, before reading any of its source (`licensing.md`).
2. **Confirm the memory API** exists and is supported — PINE, or whatever the equivalent is.
3. **Answer the drawing question before anything else**, because it is the hard half here and the
   one with no precedent in this repo. An adapter that can read perfectly and cannot draw is not
   an adapter.
4. Only then the per-game tier question: does this title have a decomp or documented addresses?

## See also

- [`adapters/_template/README.md`](../adapters/_template/README.md) — what to build, and the
  enumeration technique this file argues for.
- [effect-investigation.md](effect-investigation.md) — how to search, told through the investigation
  that a hard access model made expensive.
- [licensing.md](licensing.md) — what may and may not be read from a reference project.
- [environment.md](environment.md) — the dated record of which tools and builds were actually used.
