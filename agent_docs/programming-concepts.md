# Programming concepts behind a game mod, in plain words

Written for the project's author, to learn the ideas an agent uses when it builds or explains an adapter or a mod.
The concepts, not this project's decisions; the examples come from Unity games modded with BepInEx (TEVI here, and
the author's Bug Fables Archipelago mod), because that is where they came up (2026-09-27). Game names below are field
and class names read from the game's own assembly, never its code.

- [Class and object](#class-and-object)
- [Words the rest leans on](#words-the-rest-leans-on)
- [DLLs: how one is made, what's inside, how it runs](#dlls-how-one-is-made-whats-inside-how-it-runs)
- [Fields, and public versus private](#fields-and-public-versus-private)
- [Reflection: reaching a private field by name](#reflection-reaching-a-private-field-by-name)
- [Static: one shared copy](#static-one-shared-copy)
- [The frame loop](#the-frame-loop)
- [Coroutines: code that pauses](#coroutines-code-that-pauses)
- [Hooks: prefix and postfix](#hooks-prefix-and-postfix)
- [Threads: why received things wait for a safe moment](#threads-why-received-things-wait-for-a-safe-moment)
- [Null: nothing is there](#null-nothing-is-there)
- [Magic numbers](#magic-numbers)

## Class and object

A **class** is the blueprint (`PlayerControl`); an **object**, or instance, is one real thing built from it (the
player walking around right now). Fields belong to each object: two enemies built from the same class each have their
own HP. Almost everything below builds on this.

## Words the rest leans on

Each of these came up as a question (2026-09-27); where the first guess was close, the difference is kept.

**Code in general**

- **Variable:** a named box holding a value. `int` is the *kind* (type) of value it holds: in `int speed = 5;`,
  `speed` is the variable, `int` its type, `5` its value. A **field** is a variable that belongs to a class.
- **Types:** what *kind* of value a variable holds. `int` a whole number (`5`, `699`); `float` a number with
  decimals (`2.5f`); `bool` true or false; `string` text (`"Kabbu"`); an **enum** one option from a fixed, named
  list (`enum Weather { Sunny, Rain, Snow }`), a readable name for a number underneath, so code says `Weather.Rain`
  instead of a magic `1`. `var` is not a type: it means "work the type out yourself" (`var speed = 5;` is an `int`).
  `[]` after a type makes a list of it: `bool[] flags` is a list of true/false, `flags[699]` item 699. A class name is
  a type too: `PlayerControl player` holds (a reference to) a player.
- **Function:** a named piece of code that does something. A **method** is a function that belongs to a class and
  works on that object's fields: `PlayerControl.DoJump()` makes *this* player jump.
- **Parameter:** an *input* given to a function inside its brackets: `Jump(5)` passes 5 as the height. (Not a limit.)
- **Return:** the result a function hands back to whoever called it. A prefix returning `false` hands back "don't
  run the game's method".
- **Reference ("points to"):** like a desktop shortcut. The variable holds *where* the object is, not the object:
  two variables can point to the same one, and `null` is a shortcut to nothing. (Not about code running elsewhere.)
- **Memory:** the computer's working space (RAM), holding everything the game has *right now*: variables, objects,
  the map. Gone when the game closes. Saves and files live on the **disk** and are loaded into memory to be used.
- **Dots and brackets:** `.` means "go inside" (`MainManager.instance.flags`: in MainManager, its instance, its
  flags), like slashes in a folder path. `()` calls a function, parameters inside. `[]` picks one item of a list by
  number (`flags[699]`). `{}` wraps a block of code.
- **Compile:** translating the code we write into what the computer runs, checking it on the way. That check is where
  "private" is enforced and a misspelled public name fails. *Build* is compiling plus packaging the result.
- **State machine:** something that is always in exactly one state from a fixed list, with rules for moving between
  them: a game's title screen, overworld, battle and menu; a boss's attack pattern. A coroutine is turned into one.
- **Garbage collector:** frees memory nothing uses any more, automatically, so nothing is "forgotten". Two catches:
  holding on to things still leaks (a list that only grows), and a collection takes time, which can show as a stutter.
- **Throwing an exception:** an error that **stops the current code on the spot** and jumps out until something
  catches it; nothing after it in that method runs. Unity logs it and carries on next frame, so it *looks* like "log
  and continue", but the work was left half done. One thrown every frame means that work never finishes.
- **`try` / `catch`:** `try` runs some code; if an exception is thrown inside, it lands in `catch` instead of
  crashing out, and the code decides what happens (log it, fall back). It catches the error afterwards; it doesn't
  prevent it.
- **Struct:** a bundle of fields grouped together, like a small class (a position is `x, y, z`). Rust has no classes,
  so structs are what it uses.
- **Property:** in C#, looks like a field from outside but runs a little code when read or written. In Unreal,
  "properties" just means an object's fields.
- **`typeof`:** the class itself as a thing to pass around: `typeof(StartMenu)` tells Harmony which class to look in.
- **`IEnumerator`:** not related to enums. An *enumerator* hands things out one at a time ("next… next…"), and C#
  reuses it for coroutines: each `MoveNext` runs to the next `yield`. An **enum** is a named list of options.

**Languages**

- **Machine code (binary):** the CPU's own instructions, just numbers. Nobody writes it by hand.
- **C:** low level, close to the machine; you manage memory yourself. Very fast and in full control, but easy to crash
  or leak. Compiles straight to machine code, so decompiling it gives back little.
- **C#:** high level, with a garbage collector and safety checks: easier and safer, a little more overhead. Compiles
  to a middle step, **IL**, which keeps names and structure; that's why a C# game decompiles back to nearly its source.
- **IL (Intermediate Language):** instructions for an imaginary computer rather than a real CPU. Building turns C#
  into IL, stored in the `.dll`; when the game runs, the runtime (Mono) turns the IL into machine code for the actual
  CPU just before each piece runs. So one `.dll` runs on any machine, and because IL keeps class names, field names,
  types and each method's structure, ILSpy can turn it back into nearly the original C#. Machine code keeps almost
  none of that, which is IL2CPP's situation. It reads like `ldfld basespeed` ("read the field basespeed").
- **Lua:** a small *scripting language*, built to be embedded in other programs so they can be scripted without
  rebuilding them; the program reads a script and runs it directly, no compile step. Not an acronym: Portuguese for
  "moon", written Lua, not LUA (lua.org, checked 2026-09-27; created at PUC-Rio, Brazil, in 1993). MeshGhost meets it
  in BizHawk (the Emerald and Crystal adapters) and in UE4SS (Pseudoregalia).

**Tools and engines**

- **Runtime:** two meanings. (1) *The time the program is running*, the opposite of compile time: a wrong public
  name fails at compile time, a wrong private name looked up by reflection only at runtime. (2) *A runtime*: the
  software a program needs underneath it, as a music file needs a player. A .NET DLL is IL, not machine code, so a
  runtime translates it for the CPU, manages memory (the garbage collector), handles exceptions and loads DLLs.
  "Install the .NET runtime" or "the Visual C++ Redistributable" is this meaning. Mono is Bug Fables' runtime, shipped
  with the game: Unity starts Mono, and Mono runs `Assembly-CSharp.dll` and, through BepInEx, the mod.
- **.NET:** a whole *platform* rather than just a framework: the languages (C# mostly) that compile to IL, a
  *runtime* that runs IL (turns it into machine code, collects garbage, throws exceptions), and a big standard library
  (lists, text, files, networking). The names: **.NET Framework** is Microsoft's original, Windows-only, ending at
  4.8; **.NET** (5 and later, once ".NET Core") is the modern cross-platform one; **Mono** is an independent,
  open-source runtime, the one Unity uses; **.NET Standard** runs nothing, it is a list of library features all of
  them promise. A BepInEx 5 mod targeting `netstandard2.0` (Bug Fables' does) uses only those, so its DLL loads in
  Unity's Mono: C# → IL in the mod's DLL → loaded by BepInEx → run by Mono.
- **Unity / Unreal:** game engines: rendering, physics, sound, input and an editor, so a game writes only its own
  logic on top. Unity games are written in C#, Unreal games in C++. Unity itself is C++, running the game's C# on
  Mono, which is why a Unity game has an `Assembly-CSharp.dll`.
- **Inspector:** the Unity editor's panel showing the selected object's fields as boxes to edit.
- **DLL (Dynamic Link Library):** a file of *compiled* code that a program loads while it runs: a *library* of
  ready-made functions and classes, *linked* in when needed rather than baked in. It can't run by itself; an `.exe`
  loads it (so BepInEx can get a game to load a mod's DLL beside its own `Assembly-CSharp.dll`). Unlike `.txt`,
  `.md` or `.bat`, which are all plain text (a `.bat` is commands read line by line), a DLL is binary: Notepad shows
  gibberish, and renaming a text file to `.dll` makes nothing loadable, because only a compiler produces the format.
  The extension is only a label: a **.NET DLL** (C#) holds IL and reads back cleanly; a **native DLL** (C, C++,
  IL2CPP's `GameAssembly.dll`) holds machine code.
- **Assembly:** a compiled .NET package; in practice, the `.dll` itself. (Unrelated to *assembly language*, a text
  form of machine code.)
- **Mono:** the *runtime* that runs C# while the game plays, turning IL into machine code as it goes. A Mono game
  keeps its code as IL in `Assembly-CSharp.dll`, which is why it reads so cleanly. Nothing is scrambled.
- **IL2CPP:** Unity's other option: the IL is turned into C++ and compiled to machine code (`GameAssembly.dll`),
  mainly for speed and platforms like consoles, not to hide anything. The logic is no longer readable; the names
  survive in `global-metadata.dat` ([access-models.md](access-models.md)).
- **BepInEx:** a *mod loader*: it gets itself loaded when a Unity game starts, then loads mods into it and gives them
  settings and a log. It doesn't read or change DLL files.
- **Harmony:** changes the game's *methods while it runs* (prefix and postfix), in memory, never the DLL file.
  BepInEx gets a mod in; Harmony lets it change the game.
- **UE4SS:** roughly Unreal's BepInEx: a mod loader and toolkit, with Lua scripting and reflection, hooking the
  game's executable (an Unreal game has no C# DLL).
- **Decompile:** turn compiled code back into readable source, approximately.
- **ILSpy:** a *tool* (a program used) rather than a framework (code built on): it opens .NET DLLs and shows them as C#.
- **Patch:** a change applied on top of something. In Harmony, a prefix or postfix attached to a game method.
- **Adapter:** in MeshGhost, the per-game piece connecting one game to it: it reads the player from the game and
  shows the ghosts there. The word is general programming vocabulary: something that translates between two sides,
  like a travel plug adapter. `core` and `relay` are the shared client and the server.

**Game words**

- **`Update()`:** the method Unity calls on every object once per frame (see the frame loop). Not "change a value".
- **`Time.timeScale`:** Unity's game clock: 1 normal, 2 double speed, 0 paused. Tying game speed to the *frame rate*
  is bad practice (faster PCs run the game faster); the good way multiplies movement by each frame's time, and then
  `timeScale` speeds everything evenly.
- **Trigger:** an invisible area in the world that fires something when the player walks into it; how a cutscene
  starts.

## DLLs: how one is made, what's inside, how it runs

**Readable, obfuscated, native.** A normal .NET DLL (Bug Fables', a BepInEx mod's) is readable by nature: IL keeps
the names and structure, so ILSpy shows near-original C#. An **obfuscated** one had a tool run over it on purpose:
everything renamed to `a`, `b`, `c`, junk added, parts sometimes encrypted; it still works, it is just miserable to
read. A **native** DLL (C, C++, IL2CPP) isn't scrambled, only machine code, with the names and structure never kept.

**Made:** `.cs` files (plain text) go through the **compiler**, which checks them (types, private access, names),
translates them into IL and writes one `.dll`. Inside it: a header (the same Windows container a `.exe` uses),
**metadata** (tables of every class, method and field with names and types, and which other DLLs it needs; a
Bug Fables mod lists `Assembly-CSharp`, BepInEx and Harmony), and each method's IL.

**Run, for a BepInEx mod:**

1. **Load:** BepInEx asks Mono to load the mod's DLL into the running game.
2. **Link:** the mod's code mentions `MainManager.instance`, but its DLL holds only a note: "the field `instance` of
   class `MainManager`, in `Assembly-CSharp`". Mono matches the note to the real thing already loaded. That is the
   *link* in Dynamic Link Library, done at runtime.
3. **Start:** BepInEx finds the plugin class (marked `[BepInPlugin]`), creates it, and its setup code runs.
4. **Run:** the first time a method runs, Mono translates its IL to machine code and runs it.

After that the mod's code and the game's live in one running program and call each other directly, as if built
together.

**Why DLLs exist:** sharing (many programs, one library), updating one part without rebuilding everything, and
plugins: adding code to a program after it was built, which is exactly what a mod is.

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

## Static: one shared copy

A `static` field belongs to the class itself, not to any object, so there is exactly one. Games often keep one big
"everything" object in a static field, like Bug Fables' `MainManager.instance`, so any code can reach
`MainManager.instance.flags`. That pattern is a **singleton**, and it is how a mod reaches most game state.

## The frame loop

A game is a loop. Every frame (60 or more times a second) Unity calls each object's `Update()`: read the input, move
things, draw. That's why speeds are multiplied by the frame's time, so movement doesn't depend on the frame rate, and
why a scene can be sped up by making each frame count for more time (`Time.timeScale`).

## Coroutines: code that pauses

A **coroutine** is a function that can pause partway and pick up where it left off later, while the game keeps
running.

**Why games need them:** a normal method runs start to finish within one frame. A cutscene written that way ("show
text, wait for a button, walk over there, wait 2 seconds") would freeze the whole game while it waits: nothing
drawn, no input read. So a coroutine says "pause me here" with `yield return`:

```csharp
IEnumerator Cutscene()
{
    ShowText("Vi: Let's go!");
    yield return WaitForButton();          // pause; the game keeps running
    WalkTo(kabbu, door);
    yield return new WaitForSeconds(2f);   // pause 2 seconds
    OpenDoor();
}
```

(An illustration, not the game's code.) Each frame Unity checks whether the coroutine may go on, runs it to the next
`yield`, and gets back to the rest of the game.

**In Bug Fables:** every cutscene is one. The spider scene is `IEnumerator Event6()`, and "scene, scripted fight,
scene, second fight, scene" is one coroutine pausing at each fight. Kabbu's horn slash waits a few frames for a
second tap before it becomes a dash (`DoActionTap`), and ending the dash waits a quarter second (`StopDash`).

**Think of it as a scene's script**, acted out line by line. Walking into an invisible trigger on the map makes the
game *start* that scene's coroutine; it moves characters, shows text and waits for a button, starts a battle and
waits for it to end, sets story flags and gives items, then stops by itself. So it does two kinds of things: what you
*watch* (walking, text, a bridge falling), and what *changes the game* (flags, items, party members), which the rest
of the game checks later (a door opens only once a flag is set).

**Not a queue.** A queue is a line of separate things waiting their turn (received items wait in one until play is
safe). A coroutine is *one* job spread out over time: code that has started, is paused partway, and remembers where.
Like a recipe: mix the dough, put it in the oven and go do other things for 20 minutes (the game keeps running),
then come back to the *next* step, not the first (that's `MoveNext`), and ice it.

**That's why a mod has two ways to shorten a scene:**

- **Skip: never start the script.** Nothing plays, and nothing in it happens either, so the mod must make its game
  changes itself ("set flag 11, as the scene would have"). Safe only for a simple scene, talk and a flag or two.
  Where the script itself does the work (the bridge falling), a skip would leave the bridge standing.
- **Speed up: let the script play in full, faster.** Every step still happens the game's own way; the mod runs time
  at 8x and answers the text boxes. Safe for a complicated scene, because the mod never has to repeat what it does.

Hence the Bug Fables rule: only dialogue is skipped; anything that happens is sped up.

**Under the hood** each `yield` splits the coroutine into numbered steps, a small state machine that `MoveNext`
("run the next step") advances. So a mod can hook the very first step: the Bug Fables mod gates the attack items
that way (pressing attack starts a short coroutine, `DoActionTap`; without the item, its first step ends it and the
attack never happens). Jump is a plain method, gated with a plain prefix.

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
