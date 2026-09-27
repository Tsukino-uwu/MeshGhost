# Programming concepts behind a game mod, in plain words

Written for the project's author, to learn the ideas an agent uses when it builds or explains an adapter or a mod.
The concepts, not this project's decisions; the examples come from Unity games modded with BepInEx (TEVI here, and
the author's Bug Fables Archipelago mod), because that is where they came up (2026-09-27). Game names below are field
and class names read from the game's own assembly, never its code.

**Read it in order.** It goes from the ground up, and each part mostly uses words explained before it (where it
can't, it points ahead): the machine, then code, then how code becomes a running program, then how a game runs, then how a mod changes one.

1. [The machine](#part-1-the-machine): transistors, CPU and GPU, bits and bytes, memory, files
2. [Code](#part-2-code): variables and types, functions, class and object, references, static, public and private,
   exceptions
3. [From code to a running program](#part-3-from-code-to-a-running-program): languages, compiling, the runtime, DLLs
   and EXEs, reading compiled code, other systems
4. [How a game runs](#part-4-how-a-game-runs): engines, frames, game state, coroutines, threads
5. [Modding it](#part-5-modding-it): BepInEx, Harmony, reflection, magic numbers, UE4SS and adapters

## Part 1: The machine

### Transistors and logic gates

A **transistor** is a microscopic switch that lets electricity flow or stops it, switched by electricity itself: a
small voltage on its control connection (literally called the *gate*) decides whether current flows between the other
two, so one transistor can switch the next. Transistors make **logic gates** (AND: on only if both inputs are; OR: if
either is; NOT: flips it), gates make adders and one-bit memory cells, and those make a CPU.

### CPU and GPU

The **CPU** (Central Processing Unit) is the chip that runs a program's instructions, billions a second, built from
billions of transistors. The **GPU** (Graphics Processing Unit) takes work off it, of a different kind: a CPU has a
few powerful cores for complicated step-by-step work (game logic, loading); a GPU has thousands of simple ones doing
the *same* small task on lots of data at once (one colour sum for ~2 million pixels), which is also why GPUs are used
for AI. One expert versus a stadium of people with calculators.

### Bits, bytes and hex

Everything is **bits**, each 1 or 0: **binary**, strictly. Inside a CPU a bit is a voltage, high or low, held by a
tiny circuit of a few transistors;
storage keeps bits other ways (a tiny electric charge in RAM, magnetism on a hard drive, trapped charge in an SSD).

**Bit versus byte:** a bit is one 1 or 0, two possibilities; a **byte** is 8 bits, 256 possibilities, the numbers 0
to 255 (one letter, one small number, one hex pair). Computers work in bytes: each has its own address in memory, and
sizes count them. A kilobyte (KB) is about a thousand bytes, a megabyte (MB) about a million, a gigabyte (GB) about a
billion (some programs count 1,024 instead of 1,000, which is why a "1 TB" drive shows as about 931 GB). Internet
speeds are in *bits*, small **b** (100 Mbps), file sizes in *bytes*, big **B** (12 MB), so 100 Mbps downloads at most
about 12.5 MB a second.

**Hexadecimal** ("hex": Greek *hexa*, six, plus *decimal*, from Latin *decem*, ten, so sixteen; often written with `0x`)
is a shorter way for people to *write* the same bits: it counts in 16s (`0-9`, then `A-F` for 10 to 15), and one hex
digit is exactly 4 bits, so two are exactly one byte. That's why memory and addresses (a GBA's `0x02024284`) are shown
in hex. Its letters aren't there because *numbers* run out but because *digits* do: normal counting has ten single
digits, hex needs sixteen, so it borrows A-F. In hex they are digits, not letters.

| Binary | Hex | Decimal |
|---|---|---|
| `1110 0110` | `E6` | 230 |
| `0100 0001` | `41` | 65, the letter `A` |
| `0100 1101 0101 1010` | `4D 5A` | the letters `MZ`, the start of every Windows `.exe` and `.dll` |

### Memory and addresses

**Memory** is the computer's working space, **RAM** (Random Access Memory): very fast, temporary, emptied when the
power goes off. It holds everything a program has *right now*: variables, objects, the map. Saves and files live on
the **disk** and are loaded into memory to be used. RAM is one enormously long street of bytes, each with a house
number, its **address** (`0x02024284` is the byte at that number, in hex). *Random access* means jumping straight to
any address, instead of reading from the start like a tape.

### Files, text and encoding

**Every file is bytes underneath**, a `.txt` included. The disk stores bytes; a **file** is a named run of them; a
**format** is the agreement on what they mean (PNG, MP3, DLL), and the extension only hints which agreement to use.
That's why renaming changes nothing inside.

**Encoding** is the agreement for turning something into bytes and back (not compressing: compression is one kind of
encoding, meant to shrink). For text: **Unicode** gives every character in every language a number (`A` 65, `é` 233,
`あ` 12354, `😀` 128512), and **UTF-8** (Unicode Transformation Format, 8-bit) stores those numbers as bytes, 1 for
plain English letters, 2 to 4 for others. The wrong encoding is why `é` sometimes shows as `Ã©`.

**Text versus binary:** a text file's bytes are *letter codes* (in UTF-8, 65 is `A`), so any editor shows them as
letters. A **binary file**, loosely, is one whose bytes aren't meant as letters (a DLL, an image), so Notepad's attempt
at letters is gibberish. A text file is 1s and 0s too; the difference is only what the bytes are meant as.

**Text formats:** `.json`, `.md`, `.yaml`, `.csv`, `.html` and `.cs` are all text underneath, like `.txt`; each only
adds rules. JSON's (`{"name": "Kabbu", "hp": 7}`: braces, quotes, commas) let a program read it reliably as *data*,
which is called **parsing**. Archipelago's messages and `slot_data` are JSON, as is MeshGhost's `config.json`.

- **Header:** the start of a file, saying what it is and how to read the rest: its type, the CPU it's for, where
  each part begins. Many formats open with fixed *magic bytes* as an ID badge: every Windows `.exe` and `.dll` starts
  `MZ`.
- **Metadata:** data *about* the data. A photo's is its date and camera, the pixels being the data; a .NET DLL's is
  the list of classes, names and types, the code being the content.
- **Archives:** a `.tar` ("tape archive") bundles many files into one, keeping each one's name, size and permissions,
  without shrinking anything; `.tar.gz` is that bundle compressed with gzip; `.zip` does both in one format.

## Part 2: Code

### Variables and types

A **variable** is a named box holding a value. Its **type** is the *kind* of value it holds: in `int speed = 5;`,
`speed` is the variable, `int` its type, `5` its value.

- `int` a whole number (`5`, `699`); `float` a number with decimals (`2.5f`); `bool` true or false; `string` text
  (`"Kabbu"`).
- An **enum** is one option from a fixed, named list (`enum Weather { Sunny, Rain, Snow }`), a readable name for a
  number underneath, so code says `Weather.Rain` instead of a magic `1`.
- `var` is not a type: it means "work the type out yourself" (`var speed = 5;` is an `int`).
- `[]` after a type makes an **array**, a fixed-length list: `bool[] flags` holds true/false values, `flags[699]` is
  item 699 (counting from 0).

### Functions

A **function** is a named piece of code that does something.

- **Parameter:** an *input* given to a function inside its brackets: Bug Fables' `Jump(5f)` passes 5 as the upward
  speed the jump starts with. (Not a limit.)
- **Return:** the result a function hands back to whoever called it.
- **Dots and brackets:** `.` means "go inside" (`MainManager.instance.flags`: in MainManager, its instance, its
  flags), like slashes in a folder path. `()` calls a function, parameters inside. `[]` picks one item of a list by
  number (`flags[699]`); but on a line of its own above a class or method, like `[BepInPlugin(...)]`, it is a
  *label* (an **attribute**) that other code can look for. `{}` wraps a block of code, or a list of items (as in the
  enum above).

### Class and object

A **class** is the blueprint (`PlayerControl`); an **object**, or instance, is one real thing built from it (the
player walking around right now). A **field** is a variable that belongs to a class, and fields belong to each object
(except *static* ones, below): two enemies built from the same class each have their own HP. A **method** is a
function that belongs to a class and works on that object's fields: `PlayerControl.DoJump()` makes *this* player jump.

A class is also a **type**, one the programmer defines, built from fields (each with its own type) plus the methods
that work on them, where `int` is built into the language: `PlayerControl player` holds (a reference to) a player.

- **Struct:** a bundle of fields grouped together, like a small class (a position is `x, y, z`). Rust has no classes,
  so structs are what it uses.
- **Property:** in C#, looks like a field from outside but runs a little code when read or written. In Unreal,
  "properties" just means an object's fields.
- **State machine:** something that is always in exactly one state from a fixed list, with rules for moving between
  them: a game's title screen, overworld, battle and menu; a boss's attack pattern.

### References and null

A **reference** ("points to") is like a desktop shortcut. The variable holds *where* the object is, not the object,
working in effect as an address: two variables can point to the same object. (Not about code running elsewhere.)

A reference can be **`null`**, a shortcut to nothing: no battle running, no menu open, the player not spawned yet.
Using it anyway throws `NullReferenceException`, one of the most common errors there is. Much of a mod's checking is
"is this actually there right now?"

### Static: one shared copy

A `static` field belongs to the class itself, not to any object, so there is exactly one. Games often keep one big
"everything" object in a static field, like Bug Fables' `MainManager.instance`, so any code can reach
`MainManager.instance.flags`. That pattern is a **singleton**, and it is how a mod reaches most game state.

### Fields: public versus private

Each field has an access level:

- **public:** any code may read and change it.
- **private:** only the class's own code may. Any other code that even mentions it, to read or to change it, gets an
  error when the code is built (see compiling, part 3).

It is not about what kind of data a field holds. The programmer chooses per field, as a promise the compiler then
enforces. Bug Fables, one class (`PlayerControl`):

| Field | What it is | Access |
|---|---|---|
| `basespeed` | movement speed | public |
| `dashing` | is the leader dashing | public |
| `dashtarget` | where the dash is steering | private |
| `idletime` | how long the player has stood still with no key pressed (it drops the HUD down) | private |

**Why not everything public?** Then anything could change anything. If `dashtarget` were public, a cutscene or a
menu could change it by mistake mid-dash, and the bug could come from anywhere in the game. Private means "only this
class touches it", so when the developer reworks the dash, one file is all there is to check.

**Why not everything private?** Classes have to share: the save needs the story flags, the battle needs the party's
HP. Those are public on purpose. The usual habit is **private by default, public only for what others genuinely
need**, like a console's buttons (public) and its circuits (private).

**Not the same as Rust's memory safety.** Rust's ownership and borrowing are about *when memory is freed* (no use
after it's gone); C# has a garbage collector for that (part 3). **Ownership:** every value has exactly one owner, and
when the owner goes away the memory is freed right then, no collector needed. **Borrowing:** other code may use a
value for a while without owning it, either many readers at once or exactly one writer, never both. Like owning a
car: friends may look at it together or one may drive it, never both, and it can't be scrapped while lent out.
Neither is about private or public. Private fields are about *which code may touch a value*: how the program is
organised ("program handling", as the TEVI randomizer's developer put it). Rust has private fields too: a struct's
fields are private to their module unless marked `pub`, the same idea with the safer default. What the two share is
that the compiler checks them before the program runs.

### When things go wrong: exceptions

- **Throwing an exception:** an error that **stops the current code on the spot** and jumps out until something
  catches it; nothing after it runs until a `catch` is reached (only `finally` blocks, cleanup code written to
  run whatever happens, run on the way). Unity logs it and carries on next frame, so it *looks* like "log
  and continue", but the work was left half done. One thrown every frame means that work never finishes.
- **`try` / `catch`:** `try` runs some code; if an exception is thrown inside, it lands in `catch` instead of
  crashing out, and the code decides what happens (log it, fall back). It catches the error afterwards; it doesn't
  prevent it.

## Part 3: From code to a running program

### Languages

- **Machine code:** the CPU's own instructions, just numbers; hardly anyone writes it by hand. Not the same as a
  binary file (part 1): a .NET DLL is a binary file, yet it holds IL, not machine code.
- **C:** low level, close to the machine; you manage memory yourself. Very fast and in full control, but easy to crash
  or leak. Compiles straight to machine code, so a decompiler gives back only a rough C-like version, most names gone.
- **C#:** high level, with a garbage collector and safety checks: easier and safer, a little more overhead. Compiles
  to a middle step, **IL**, which keeps names and structure; that's why a C# game decompiles back to nearly its source
  (not its comments, nor the names of variables inside a method: ILSpy invents those, like `num` in Bug Fables).
- **IL (Intermediate Language):** instructions for an imaginary computer rather than a real CPU. Building turns C#
  into IL, stored in the `.dll`; when the game runs, the runtime (below) turns the IL into machine code for the actual
  CPU just before each piece runs. So one `.dll` runs on any machine that has a runtime, and because IL keeps class,
  method and field names, types and each method's structure, it can be turned back into nearly the original C#. Machine
  code keeps almost none of that. It reads like `ldfld basespeed` ("read the field basespeed").
- **Lua:** a small *scripting language*, built to be embedded in other programs so they can be scripted without
  rebuilding them; no separate build step: the program compiles the script itself as it loads it, then runs it. Not an
  acronym: Portuguese for "moon", written Lua, not LUA (lua.org, checked 2026-09-27; created at PUC-Rio, Brazil, in
  1993). MeshGhost meets it in BizHawk (the Emerald and Crystal adapters) and in UE4SS (Pseudoregalia's probes; that adapter
  itself is C++).

The others, by two questions (what the code becomes; who cleans up memory):

| Language | Becomes | Memory | Where you meet it |
|---|---|---|---|
| C | machine code | by hand | systems, speed |
| C++ | machine code | by hand, with helpers | Unreal; Unity's engine core |
| C# | IL, run by a runtime | garbage collector | Unity games, BepInEx mods |
| Java | bytecode (like IL) | garbage collector | Android, Minecraft |
| Go | machine code | garbage collector | MeshGhost's relay and core |
| Rust | machine code | its compile-time rules | speed with safety |
| Python | bytecode, made as it loads, run by the interpreter | garbage collector | Archipelago and its worlds |
| Lua | bytecode, made as it loads, run by the interpreter | garbage collector | BizHawk, UE4SS |

### Compiling

A `.cs` file is text: **source code** that does nothing until a compiler reads it. To **compile** is to translate the
code we write into what the computer runs, checking it on the way. That check is where "private" is enforced and a
misspelled public name fails. **Compile time** is while it's built; **runtime** is the whole time it runs, not only
its start. **Build** is compiling plus packaging the result.

### The runtime, .NET and Mono

- **Runtime**, the second meaning: the software a program needs underneath it, as a music file needs a player. A .NET
  DLL is IL, not machine code, so a runtime translates it for the CPU, manages memory, handles exceptions and loads
  DLLs. "Install the .NET runtime" or "the Visual C++ Redistributable" is this meaning.
- **Garbage collector:** the part of a runtime that frees memory nothing uses any more, automatically, so nothing is
  "forgotten". Two catches: holding on to things still leaks (a list that only grows), and a collection takes time,
  which can show as a stutter.
- **.NET:** a whole *platform* rather than just a framework: the languages (C# mostly) that compile to IL, a runtime
  that runs IL, and a big standard library (lists, text, files, networking). The names: **.NET Framework** is
  Microsoft's original, Windows-only, ending at 4.8.1; **.NET** (5 and later, once ".NET Core") is the modern
  cross-platform one; **Mono** is a separate, open-source runtime, the one Unity uses (its own copy); **.NET
  Standard** runs nothing, it is a list of library features all of them promise (`netstandard2.0` is version 2.0 of
  that list, not a version of one framework).
- **Mono** in a Unity game: shipped with the game, it runs C# while the game plays, turning IL into machine code as it
  goes. Unity starts Mono, and Mono runs the game's `Assembly-CSharp.dll`. A BepInEx 5 mod targeting `netstandard2.0`
  (Bug Fables' does) uses only features on the promised list, so its DLL loads in any Mono that supports the list, as
  Bug Fables' does.

### DLLs and EXEs

A **library** is mostly *code*, not data: ready-made functions and classes other programs use, like a toolbox.
**Sharing** is many things using one thing (many programs, one library).

A **DLL** (Dynamic Link Library) is a file of *compiled* code that a program loads while it runs: a library *linked*
in when needed rather than baked in. It can't run by itself; an `.exe` loads it. Unlike `.txt`, `.md` or `.bat`,
which are all plain text (a `.bat` is commands read line by line), a DLL is binary, and renaming a text file to
`.dll` makes nothing loadable, because only a compiler produces the format. An **assembly** is a compiled .NET
package: the `.dll` (or `.exe`) itself. (Unrelated to *assembly language*, a text form of machine code.)

**Made:** `.cs` files go through the compiler, which checks them (types, private access, names), translates them into
IL and writes one `.dll`. The IL becomes machine code only later, while the game runs. Inside it, organised like a
book whose header is the table of contents: a header (the same Windows container a `.exe` uses), **metadata** (tables
of every class, method and field with names and types, and which other DLLs it needs; a Bug Fables mod lists
`Assembly-CSharp`, BepInEx and Harmony among others), and each method's IL.

**Run, for a BepInEx mod** (BepInEx is in part 5):

1. **Load:** BepInEx asks Mono to load the mod's DLL into the running game.
2. **Link:** the mod's code mentions `MainManager.instance`, but its DLL holds only a note: "the field `instance` of
   class `MainManager`, in `Assembly-CSharp`". Mono matches the note to the real thing already loaded. That is the
   *link* in Dynamic Link Library, done at runtime. (*Static* linking would copy the library's code into the program
   at build time instead: one big file, fixed forever.)
3. **Start:** BepInEx finds the plugin class (marked `[BepInPlugin]`), creates it, and its setup code runs.
4. **Run:** the first time a method runs, Mono translates its IL to machine code and runs it.

After that the mod's code and the game's live in one running program and call each other directly, as if built
together.

**An EXE** (*executable*) is the same container, marked in its header as a program rather than a library, with an
**entry point**, "start here", so Windows can start it: it
reads the header, loads the file and the DLLs it needs, and jumps to the entry point. A native `.exe` holds machine
code; a .NET one holds IL and a small starter for the runtime. A Unity game's `.exe` is mostly a launcher: it loads
Unity's engine DLL, which starts Mono, which runs `Assembly-CSharp.dll`. It is compiled like a DLL, only marked as
runnable. (A DLL can have an entry point too, code run when it loads; the header's mark is what makes a program.)

**Why DLLs exist:** sharing (many programs, one library), updating one part without rebuilding everything, and
**plugins**: add-ons loaded into a program *while it runs*, not built into it, usually a DLL, sometimes a script.
Programs are usually designed to take them. A mod is exactly that.

### Reading compiled code

To **decompile** is to turn compiled code back into readable source, approximately. **ILSpy** is a *tool* (a program
used) rather than a framework (code built on): it opens .NET DLLs and shows them as C#.

- **Readable:** a normal .NET DLL (Bug Fables', a BepInEx mod's) is readable by nature: IL keeps the names and
  structure, so ILSpy shows near-original C#. A Mono game keeps its code as IL in `Assembly-CSharp.dll`; nothing is
  scrambled.
- **Obfuscated:** made hard to read *on purpose* by a tool (everything renamed `a`, `b`, `c`, junk added, parts
  sometimes encrypted), to slow down cheaters, crackers or copiers. Not real encryption: the code still runs as it is,
  so it can still be worked out. Security by obscurity: a speed bump, not a lock.
- **Native:** a native DLL (C, C++, IL2CPP) isn't scrambled, only machine code, with most names and all the structure
  gone (only the functions it offers to others keep theirs, unless the developer shipped debug symbols with it).
- **IL2CPP:** Unity's other option: the IL is turned into C++ and compiled to machine code (`GameAssembly.dll`),
  mainly for speed and platforms like consoles, not to hide anything. The logic is only machine code now (a native
  decompiler gives a rough C-like version, far harder to read); the names survive in `global-metadata.dat`
  ([access-models.md](access-models.md)).

**Private is not hidden.** A Mono game's `Assembly-CSharp.dll` keeps every field's name and type, private ones
included, so ILSpy shows them all. Private only stops *our* code from naming them directly.

### Programs on other systems

Not just an EXE with another header. Each system has its own container (Windows PE, magic `MZ`; Linux ELF, magic
`0x7F` then `ELF`, usually no extension; macOS Mach-O, an app's inside a `.app` folder), the machine code must suit
the CPU (an Intel/AMD PC and an Apple Silicon Mac differ), and each system is asked for files, windows and the network
its own way. So a program is built once per system and CPU, one download each; Go builds them all from the same code.
A .NET DLL is the exception: IL runs wherever a runtime does. On Linux a file runs if it is *marked* runnable (a
permission), which a `.tar` keeps and a plain zip can lose.

## Part 4: How a game runs

### Engines

**Unity** and **Unreal** are game engines: rendering, physics, sound, input and an editor, so a game writes only its
own logic on top. Unity games are written in C#, Unreal games in C++ and Blueprints (Unreal's visual scripting).
Unity itself is C++, running the game's C# on Mono, which is why a Unity game has an `Assembly-CSharp.dll`.

**Blueprints** are Unreal's *visual scripting*: instead of typing code, a developer joins boxes (*nodes*: "when the
player jumps", "play a sound", "add 1 to the score") with wires in the editor. A Blueprint is also a file, a
`.uasset`, that can define a class, often built on a C++ one, holding its behaviour and default values. Unreal
compiles it to its own bytecode, run by the engine (not IL, not machine code), and a shipped game packs these files
into `.pak` archives (or Unreal 5's newer containers). That bytecode doesn't read back the way C# does, which is why
an Unreal mod usually learns names by asking the running game (reflection, part 5), and why MeshGhost's Pseudoregalia
work could read which Blueprints exist but not what they do ([access-models.md](access-models.md)).

The **Inspector** is the Unity editor's panel showing the selected object's fields as boxes to edit. Public fields
show there and private ones don't unless marked, which is likely why many Unity games, Bug Fables among them, make
most fields public, and part of why they are easy to mod.

### Frames and the frame loop

A **frame** is one full screen, drawn. **Frame time** is how long one takes; **frame rate** (FPS) is how many per
second (at 60 FPS each frame has about 16.7 ms). **Rendering** is the process of drawing a frame: the game says where
models, lights and the camera are, and the engine and GPU work out every pixel's colour.

A game is a loop. Every frame (often 60 times a second, but it varies) Unity calls **`Update()`** on every active
script that has one (read the input, move things), then draws the frame. (`Update()` is that method's name, not "change a value".)
Tying game speed to the frame rate is bad practice (faster PCs run the game faster), so well-made games multiply
speeds by the frame's time. **`Time.timeScale`** is Unity's game clock: 1 normal, 2 double speed, 0 frozen (`Update()`
still runs, but no time passes, and timed waits like `WaitForSeconds` stop); it changes how much time each frame counts for, which is how a scene can be sped up evenly.

### Game state

**Game state** is everything describing the game at this moment: which map, the player's position, HP, berries,
story flags, what is open. Flags are part of it; a save file is a snapshot of part of it.

### Coroutines: code that pauses

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
`yield`, and gets back to the rest of the game. **`IEnumerator`** is not related to enums: an *enumerator* hands
things out one at a time ("next… next…"), and Unity reuses C#'s enumerators for coroutines.

**In Bug Fables:** every cutscene is one. The spider scene is `IEnumerator Event6()`, and "scene, scripted fight,
scene, second fight, scene" is one coroutine pausing at each fight. Kabbu's horn slash waits a few frames for a
second tap before it becomes a dash (`DoActionTap`), and ending the dash waits a quarter second (`StopDash`).

**Think of it as a scene's script**, acted out line by line. Something makes the game *start* that scene's coroutine,
often a **trigger**, an invisible area in the world that fires something when the player walks into it (others:
talking to someone, entering a map). It moves characters, shows text and waits for a button, starts a battle and
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

Hence the rule the Bug Fables mod is moving to (planned, not built yet, 2026-09-27): a scene that only talks is
skipped, a scene where something happens is sped up, and tutorials and scripted fights are always cut.

**Under the hood** each `yield` splits the coroutine into numbered steps, a small state machine (part 2) that
`MoveNext` ("run the next step") advances. So a mod can hook the very first step: the Bug Fables mod locks the field
attacks that way until their items arrive (pressing attack starts a short coroutine, `DoActionTap`; without the item,
its first step ends it and the attack never happens). Jump is a plain method, gated with a plain prefix (part 5).

### Threads: why received things wait for a safe moment

A **thread** is code running at the same time as other code. A network connection often works on threads of its own
(the Bug Fables mod's Archipelago connection does), but most of Unity may be touched only from the main game thread.
So whatever arrives is queued, and the game's own loop hands it out later, one at a time, when nothing else is
happening (no map change, menu or cutscene).

## Part 5: Modding it

### BepInEx: getting a mod in

**BepInEx** is a *mod loader*: it gets itself loaded when a Unity game starts, then loads mods into it and gives them
settings and a log. A normal mod through it never edits the game's DLL files. Bug Fables wasn't built to take
plugins, so BepInEx adds that, and a mod is a "BepInEx plugin" (how its DLL is loaded and linked: part 3).

### Harmony: prefix and postfix

A mod can't edit the game's code, so it attaches to the game's methods with **Harmony**, which changes them *while
the game runs*, in memory, never the DLL file. BepInEx gets a mod in; Harmony lets it change the game. Each attached
change is a **patch**:

- a **prefix** runs before the method and can cancel it (return `false`, which hands back "don't run the game's
  method"): refusing a jump until an item arrives;
- a **postfix** runs after it and can change what it did or returned.

`__instance` in a patch is the object the method was called on. Nearly every feature of a Unity mod is one of these
two.

### Reflection: reaching a private field by name

A mod can't compile `player.dashtarget` when the field is private, so it asks for the field **by its name, as text,
while the game runs**. That is reflection. With Harmony it is one line, `AccessTools.Field(typeof(StartMenu),
"menuid")`, or a patch parameter with three underscores, `int ___menuid`, which Harmony fills from the private field.
**`typeof`** gives a value *describing* a class (or any type) that can be passed around: `typeof(StartMenu)` tells
Harmony which class to look in.

The cost: a name in quotes isn't checked when the mod is built. A wrong public name fails the build; a wrong private
name fails only in the game, or quietly returns nothing. That's why every name is looked up in the decompiled
assembly first. A Unity/Mono mod is ordinary C# almost everywhere and uses reflection only for the private fields it
needs (TEVI's randomizer, by its developer's account, is the same).

The word means something bigger on a game with no readable code: Pseudoregalia's adapter (Unreal, UE4SS) asks the
running game which classes and properties exist at all, with nothing to check the answers against
([access-models.md](access-models.md), approach 5).

### Magic numbers

Games often name things by bare numbers: a story flag by its index, a pose by an animation number, a cutscene by an
event number. The code never says what a number means, which is why every number a mod relies on is written down
with its evidence, never guessed (each adapter's `VERIFIED.md`; Bug Fables' `MEASURED.md`).

### UE4SS and adapters

- **UE4SS:** roughly Unreal's BepInEx: a mod loader and toolkit, with Lua scripting and reflection, hooking the
  game's executable (an Unreal game has no C# DLL).
- **Adapter:** in MeshGhost, the per-game piece connecting one game to it: it reads the player from the game and
  shows the ghosts there. The word is general programming vocabulary: something that translates between two sides,
  like a travel plug adapter. `core` and `relay` are the shared client and the server.

**If you keep two:** hooks (prefix and postfix) and the frame loop. Together they explain most of how a mod changes a
game.
