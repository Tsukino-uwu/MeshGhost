# Changing a mod without restarting the game

<!-- line-cap: none -- written for people, not for an agent's instruction budget. Why: agent_docs/claude-md-cap.md. -->

MeshGhost supports several games, and each one is reached by a small piece of code — an
**adapter** — that runs *inside* that game: a Lua script in an emulator, a plugin in Unity, a mod
in Unreal. Nothing in this file is something a player installs or runs. It is here because the
answer to "how do you develop that?" turned out to be more interesting than expected, and because
each host (BizHawk, BepInEx, UE4SS) needed a different answer, for reasons worth knowing.

**The one-line version:** on all three, a code change reaches the running game in about two
seconds, with the game never closing and nobody pressing anything.

If you want the rule and the checklist rather than the story, they live in
[`adapters/CLAUDE.md`](../adapters/CLAUDE.md) and
[`adapters/_template/README.md`](../adapters/_template/README.md). This file does not repeat them.
The individual scripts are documented in
[`dev-scripts/README.md`](../dev-scripts/README.md).

---

## The problem

An adapter is not a program we launch. It is a guest: it loads into a host that somebody else
wrote — BizHawk, BepInEx, UE4SS — and it lives and dies with that host's idea of when to load
things. Which is, by default, once, at startup.

### The loop, before

So the ordinary loop for changing one line of adapter code is:

1. Close the game.
2. Rebuild.
3. Launch the game.
4. Get past the title screen, load a save, and walk back to wherever the interesting thing was.
5. Look at it for four seconds.
6. Discover you need to change one more line.

Step 4 is the expensive one, and it is expensive in *someone else's* time — the person holding the
controller, who did not ask to be sent back to the main menu because a number was wrong. One
investigation into how a character gets spawned in Pokémon Crystal went through seven revisions of
the same test script, which under this loop is seven relaunches.

### The same loop, after

1. Change the line.
2. Deploy — one command, or one line written into a text file.
3. Look at it for four seconds.
4. Discover you need to change one more line.

Then back to 1, about two seconds later.

Steps 1, 3 and 4 of the old list are simply gone. Not shortened — **gone**, and the one that
mattered most is the fourth: nobody went back to the title screen, so nobody had to walk anywhere.
The game is still running, the character is still standing exactly where the interesting thing
happens, and the person holding the controller never noticed that anything was rebuilt.

That is the whole difference, and it is easiest to see stacked up:

| | **Before** | **After** |
| --- | --- | --- |
| Close the game | yes | — |
| Rebuild | yes | yes |
| Launch the game | yes | — |
| Get back to the interesting spot | yes, by hand, every time | — |
| Look at it | yes | yes |
| **Cost per attempt** | a relaunch and a walk | about two seconds |
| **Who pays** | whoever is holding the controller | nobody |
| **Seven revisions costs** | seven relaunches | ~15 seconds of waiting, spread out |

Two things follow from that which are easy to miss when you only look at the clock.

**Cheap attempts change what you are willing to try.** When a guess costs a relaunch and a walk,
you think hard before spending one, and you tend to spend it on the guess you are most confident
in — which is exactly the guess least likely to teach you anything. When a guess costs two
seconds, you can afford to test the boring possibility, the one you are sure about, and the
control case. Several real bugs in this project were found by the run nobody would have bothered
with at the old price.

**The human is left with the half only a human can do.** What survives in the loop above is step
3 — a person watching the screen and saying what looks wrong. That is not a leftover; it is the
measurement. A wrong memory address returns a plausible number instead of crashing, and a log full
of correct-looking fields sat next to a ghost rendering as scrambled garbage more than once here.
Only looking settles it. So the loop was not automated to remove the person: it was automated to
stop spending them on relaunching a game, which is the one part of it a computer can do.

1. Rebuild.
2. Look at it for four seconds.
3. Discover you need to change one more line.

---

## The three answers, side by side

| | **BizHawk** (Pokémon Emerald / Crystal) | **TEVI** (Unity + BepInEx) | **Pseudoregalia** (Unreal + UE4SS) |
| --- | --- | --- | --- |
| **What reloads** | the adapter itself, and test scripts | the adapter itself | **test scripts only** — not the adapter |
| **Built by** | us, from scratch | mostly the host — BepInEx ships a tool for it | us, on top of a function the host exposes |
| **The mechanism** | a loader attached once at launch, watching a text file | ScriptEngine reloads plugins dropped in a folder | a small resident mod that restarts other mods on request |
| **How you trigger it** | write a script's path into that file | build and copy — a file watcher notices | write a line into a trigger file |
| **Anything to press?** | no | no | no |
| **Game disturbed?** | no | no | no |
| **Several at once?** | yes — the adapter and a test script together | one, deliberately | one restart per request |

All three end up in the same place. The interesting part is that they had to get there so
differently, and that one of them still does not fully arrive.

### BizHawk — build the whole thing yourself

BizHawk (the emulator behind both Pokémon adapters) will happily accept a script on the command
line when it starts. What it will not do is let anything *outside* the emulator attach, swap or
stop a script while it is running — that is a button in a window, and a button in a window is not
something another program can reliably press.

So the answer was to stop asking. A single loader script is attached once, at launch, and from
then on it does nothing but read a plain text file over and over. Whatever script paths that file
names get loaded and run; change the file, and on the next check it swaps to the new set. Writing
one line into a text file became the entire attach/detach cycle.

Because we own the loader, it also got the one thing the others do not have: it can run
**several** scripts at once. That was added after one turned out to be a false limit — a test
script that holds a game state has to do a little work every frame, so keeping it alive meant
unloading the adapter, and each swap quietly undid the other's work.

### TEVI — the host already had one

Unity mods here load through BepInEx, and BepInEx's own developer tools include ScriptEngine: drop
a plugin in a particular folder and it will reload it in a running game. Most of the work was
already done.

What our wrapper actually contributes is a rule: the adapter must be in the normal folder **or**
the reloadable one, and never both. In both, it loads twice — two connections, two ghosts for
every other player, and a set of measurements that all agree with each other while being wrong.
That failure is far easier to create than to diagnose, so the tool enforces the exclusivity rather
than documenting it.

TEVI is also the closest thing this project has to a controlled experiment on whether any of this
is worth doing. It relaunched for every single change from the day its adapter was started until
**2026-08-28**, when it got this loop — and shipped three features in the one session afterwards.

### Pseudoregalia — the honest partial

Unreal mods load through UE4SS, which does support hot reload. For **Lua** mods. The MeshGhost
adapter for Pseudoregalia is a compiled C++ mod, and nothing reloads that: changing it still costs
a rebuild and a relaunch, exactly as before.

This is not something better tooling fixes; it is what compiled native code is. What it changes is
how you work on that game — while you are chasing a question, put the logic in a Lua test script,
which *does* reload instantly, and move it into the adapter once you know the answer. Since
iterating is mostly measuring, that covers most of the pain.

**The first version of this one also failed in a genuinely funny way.** UE4SS exposes hot reload
only as a keyboard shortcut pressed at the game window, so the first attempt sent that keystroke
to the window from outside. Windows, reasonably, refuses to let one program steal focus from
another while you are typing — so on 2026-08-29 three reloads in a row went nowhere at all, each
one reporting success, because the user happened to be typing a message at that moment. The fix
was to stop pressing keys: a tiny resident mod sits inside the game watching a trigger file and
restarts whichever mod that file names. No focus, no keystroke, nothing to steal. That watcher is
deliberately kept dumb and is never edited while iterating, so a typo in the script being worked
on cannot take the reload machinery down with it.

---

## The catch — three of them

Speed like this makes it easy to believe you have tested something you have not.

**A hot reload is not a fresh start.** Anything that only breaks when the game launches cold —
load order, values that are null on the first frame, a stale config file — is invisible in this
loop, by construction. So nothing counts as confirmed until it has survived a real launch.

**A reload leaves its litter behind.** A ghost is a clone parented into the game world, not a child
of the code that made it. Reload the code and the old ghost stays exactly where it was while the
new copy makes another. Left unhandled you gain one extra ghost per reload — and, worse, every
measurement after that is consistent with itself and wrong. Each adapter cleans up what it spawned
when it is torn down, specifically for this.

**"Deployed" is a claim about the copy, not about the game.** The tool that copies a file can only
tell you it copied a file. Whether the game *loaded* it is a question only the game can answer, in
its own log. A reload that hits a syntax error says so quietly and keeps running the **old** code —
which on screen is perfectly indistinguishable from a change that did nothing at all.

---

## Was it worth it?

The developer's own summary, the day the emulator loader started working (2026-08-18), comparing
it to how the first adapter had gone:

> *"when we started emerald it took forever, then we did the crystal probes and it was
> easier/faster, and now when you are handling the load/deload/reload on your own its almost
> feeling fully automatic and super fast"*

Worth quoting for what the speed-up is **not**: nobody got better at Pokémon Emerald in between.
What changed is that a person stopped being required for the mechanical half of the loop. The half
that still needs them — looking at the screen and saying "that's wrong" — is the half that was
always doing the real work.

Which is why this is now the first thing built for any new game, before the first feature:

> *"this should probly be done before starting any adapter, on any kind of engine. it speeds up
> development a lot"* — 2026-08-28
