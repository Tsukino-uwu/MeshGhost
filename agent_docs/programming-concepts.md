# Programming concepts behind a game mod, in plain words

Written for the project's author, to learn the ideas an agent uses when it builds or explains an adapter or a mod.
The concepts, not this project's decisions; the examples come from Unity games modded with BepInEx (TEVI here, and
the author's Bug Fables Archipelago mod), because that is where they came up (2026-09-27). Game names below are field
and class names read from the game's own assembly, never its code.

- [Words the rest leans on](#words-the-rest-leans-on)
- [Fields, and public versus private](#fields-and-public-versus-private)
- [Reflection: reaching a private field by name](#reflection-reaching-a-private-field-by-name)
- [Class and object](#class-and-object)
- [Static: one shared copy](#static-one-shared-copy)
- [The frame loop](#the-frame-loop)
- [Coroutines: code that pauses](#coroutines-code-that-pauses)
- [Hooks: prefix and postfix](#hooks-prefix-and-postfix)
- [Threads: why received things wait for a safe moment](#threads-why-received-things-wait-for-a-safe-moment)
- [Null: nothing is there](#null-nothing-is-there)
- [Magic numbers](#magic-numbers)

## Words the rest leans on

- **Method:** a function that belongs to a class and works on that object's fields. `PlayerControl.DoJump()` makes
  *this* player jump.
- **Compile:** translating the code we write into what the computer runs (C# into the mod's `.dll`), checking it on
  the way. That check is where "private" is enforced and a misspelled public name fails. *Build* is compiling plus
  packaging the result.
- **State machine:** something that is always in exactly one state from a fixed list, with rules for moving between
  them: a game's title screen, overworld, battle and menu; a boss's attack pattern. A coroutine is turned into one.
- **Garbage collector:** frees memory nothing uses any more, automatically, so nothing is "forgotten". Two catches:
  holding on to things still leaks (a list that only grows), and a collection takes time, which can show as a stutter.
- **Throwing an exception:** an error that **stops the current code on the spot** and jumps out until something
  catches it (`try`/`catch`); nothing after it in that method runs. Unity logs it and carries on next frame, so it
  *looks* like "log and continue", but the work was left half done. One thrown every frame means that work never
  finishes.

## Fields, and public versus private

A **field** is a variable that belongs to a class: the player's speed, a menu's current page, a battle's turn.
Each field has an access level:

- **public:** any code may read and change it.
- **private:** only the class's own code may. Anyone else writing it gets a compile error.

It is not about what kind of data a field holds. The programmer chooses per field, as a promise the compiler then
enforces. Bug Fables, one class (`PlayerControl`):

| Field | What it is | Access |
|---|---|---|
| `basespeed` | movement speed | public |
| `dashing` | is the leader dashing | public |
| `dashtarget` | where the dash is steering | private |
| `idletime` | how long the player has stood still | private |

**Why not everything public?** Then anything could change anything. If `dashtarget` were public, a cutscene or a
menu could change it by mistake mid-dash, and the bug could come from anywhere in the game. Private means "only this
class touches it", so when the developer reworks the dash, one file is all there is to check.

**Why not everything private?** Classes have to share: the save needs the story flags, the battle needs the party's
HP. Those are public on purpose. The usual habit is **private by default, public only for what others genuinely
need**, like a console's buttons (public) and its circuits (private).

**Why Unity games are often mostly public:** in Unity's editor, public fields show in the Inspector, where a developer
tweaks values while building levels; private ones don't unless marked. So many Unity games, Bug Fables among them,
make most fields public, which is part of why they are easy to mod.

**Not the same as Rust's memory safety.** Rust's ownership and borrowing are about *when memory is freed* (no use
after it's gone); C# has a garbage collector for that. Private fields are about *which code may touch a value*: how
the program is organised ("program handling", as the TEVI randomizer's developer put it). Rust has private fields
too: a struct's fields are private unless marked `pub`, the same idea with the safer default. What the two share is
that the compiler checks them before the program runs.

**Private is not hidden.** A Mono game's `Assembly-CSharp.dll` keeps every field's name and type, private ones
included, so ILSpy shows them all. Private only stops *our* code from naming them directly.

## Reflection: reaching a private field by name

A mod can't compile `player.dashtarget` when the field is private, so it asks for the field **by its name, as text,
while the game runs**. That is reflection. With Harmony it is one line, `AccessTools.Field(typeof(StartMenu),
"menuid")`, or a patch parameter with three underscores, `int ___menuid`, which Harmony fills from the private field.

The cost: a name in quotes isn't checked when the mod is built. A wrong public name fails the build; a wrong private
name fails only in the game, or quietly returns nothing. That's why every name is looked up in the decompiled
assembly first. A Unity/Mono mod is ordinary C# almost everywhere and uses reflection only for the private fields it
needs (TEVI's randomizer, by its developer's account, is the same).

The word means something bigger on a game with no readable code: Pseudoregalia's adapter (Unreal, UE4SS) asks the
running game which classes and properties exist at all, with nothing to check the answers against
([access-models.md](access-models.md), approach 5).

## Class and object

A **class** is the blueprint (`PlayerControl`); an **object**, or instance, is one real thing built from it (the
player walking around right now). Fields belong to each object: two enemies built from the same class each have their
own HP.

## Static: one shared copy

A `static` field belongs to the class itself, not to any object, so there is exactly one. Games often keep one big
"everything" object in a static field, like Bug Fables' `MainManager.instance`, so any code can reach
`MainManager.instance.flags`. That pattern is a **singleton**, and it is how a mod reaches most game state.

## The frame loop

A game is a loop. Every frame (60 or more times a second) Unity calls each object's `Update()`: read the input, move
things, draw. That's why speeds are multiplied by the frame's time, so movement doesn't depend on the frame rate, and
why a scene can be sped up by making each frame count for more time (`Time.timeScale`).

## Coroutines: code that pauses

A cutscene is a function that runs a little, waits (`yield return`) for a text box or a few seconds, and carries on
next frame. Unity calls these **coroutines**. Under the hood each is a small state machine the engine advances one
step at a time (`MoveNext`), which is why a mod can hook a coroutine's very first step.

## Hooks: prefix and postfix

A mod can't edit the game's code, so it attaches to the game's methods with Harmony:

- a **prefix** runs before the method and can cancel it (return `false`): refusing a jump until an item arrives;
- a **postfix** runs after it and can change what it did or returned.

`__instance` in a patch is the object the method was called on. Nearly every feature of a Unity mod is one of these
two.

## Threads: why received things wait for a safe moment

A **thread** is code running at the same time as other code. A network connection (Archipelago's, or MeshGhost's
bridge) receives on its own thread, but Unity allows its objects to be touched only from the main game thread. So
whatever arrives is queued, and the game's own loop hands it out later, one at a time, when nothing else is happening
(no map change, menu or cutscene).

## Null: nothing is there

A field that points to an object can be `null`: no battle running, no menu open, the player not spawned yet. Using it
anyway throws `NullReferenceException`, the most common error there is. Much of a mod's checking is "is this actually
there right now?"

## Magic numbers

Games often name things by bare numbers: a story flag by its index, a pose by an animation number, a cutscene by an
event number. The code never says what a number means, which is why every number a mod relies on is written down
with its evidence, never guessed (each adapter's `VERIFIED.md`; Bug Fables' `MEASURED.md`).

**If you keep two:** hooks (prefix and postfix) and the frame loop. Together they explain most of how a mod changes a
game.
