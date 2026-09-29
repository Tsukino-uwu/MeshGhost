# Programming concepts behind a game mod, in plain words

Written for the project's author, to learn the ideas an agent uses when it builds or explains an adapter or a mod.
The concepts, not this project's decisions; the examples come from Unity games modded with BepInEx (TEVI here, and
the author's Bug Fables Archipelago mod), because that is where they came up (2026-09-27; the author's second round
of words and questions, each one met while working on Bug Fables or simply wondered about, added 2026-09-29). Game
names below are field and class names read from the game's own assembly, never its code.

**Read it in order.** It goes from the ground up, and each part mostly uses words explained before it (where it
can't, it points ahead): the machine, then code, then how code becomes a running program, then how a game runs, then
how a mod changes one, then the tools around the code, then how to read and judge it.

1. [The machine](#part-1-the-machine): transistors, CPU and GPU, bits and bytes, memory, files, invisible characters
2. [Code](#part-2-code): variables and types, strings, decisions, functions, class and object, references, static,
   public and private, logs, namespaces, exceptions, algorithms and the data around them
3. [From code to a running program](#part-3-from-code-to-a-running-program): languages, compiling, the runtime, DLLs
   and EXEs, packages, reading compiled code, other systems, ROMs and ISOs
4. [How a game runs](#part-4-how-a-game-runs): engines, frames, game state, positions and maths, coroutines, threads
5. [Modding it](#part-5-modding-it): BepInEx, Harmony, reflection, magic numbers, UE4SS and adapters
6. [Around the code](#part-6-around-the-code-scripts-git-and-checks): scripts, sed and its relatives, heredocs, git
   under the hood, checks and tests, CI and releases
7. [Reading and judging code](#part-7-reading-and-judging-code): whose name it is, what makes code good or bad,
   AI-written code, styles

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

**Alignment and padding:** a CPU reads a number fastest when its address is a multiple of its size (a 4-byte number
at an address divisible by 4), and some CPUs can't read it any other way. So a compiler places each field on such a
boundary and fills the gap before it with unused bytes, **padding**: a 1-byte value followed by a 4-byte number
usually takes 8 bytes, not 5 (Wikipedia, "Data structure alignment", checked 2026-09-29). Reading a game's memory
from outside means knowing where those gaps fall. (Padding text out to a width is part 2.)

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

**Encode and decode:** to *encode* is to put something into an agreed form, to *decode* is to take it back out. The Bug
Fables mod's scripts do both: `json.dumps(table, indent=1)` encodes a table of door connections as JSON text before
`door-graph.py` writes it to a file, and the commit-message hook's `.decode('utf-8')` turns the bytes it is handed back into letters, so it
can count characters rather than bytes (`é` is one character but two bytes).

### Invisible characters: whitespace and line endings

**Whitespace** is every character that shows as empty space: the space (byte 32), the tab (9) and the line break.
Invisible, but still bytes. Most languages don't care how much of it there is; Python does, because its indentation
*is* its structure (how far a line is pushed in says which `if` it belongs to). Spaces left at the end of a line
("trailing whitespace") do nothing but show up as changes in git, so the Bug Fables repo's `.editorconfig`, a file
most editors read, has them removed on save (`trim_trailing_whitespace = true`).

**Line endings (EOL, "end of line"):** a line break is itself one or two bytes, and systems disagree which. Linux and
macOS use **LF** ("line feed", byte 10, written `\n`); Windows uses **CRLF**, **CR** ("carriage return", byte 13,
`\r`) then LF. The names are from typewriters and teleprinters: return the carriage to the left edge, then feed the
paper up one line (Wikipedia, "Newline", checked 2026-09-29). Usually harmless, until a program reads the `\r` as
part of the text: MeshGhost's `.gitattributes` records both directions.

- A bash script (part 6) must be LF: on a Linux machine, a CRLF copy fails with `$'\r': command not found`. Git
  Bash on Windows tolerates CRLF (checked 2026-08-16, and again 2026-09-29), so a broken script looks healthy
  locally and fails only on the Linux machine that runs the checks.
- A Windows `.bat` must be CRLF: `cmd` misreads its labels in an LF file, and one of MeshGhost's ran straight past its
  own checks (2026-08-25). On 2026-09-07 a one-word sed edit (part 6) to a comment in that file rewrote every line
  ending in it, which is why the rule is now pinned.

Git can convert endings as files go in and out, per file type: `.gitattributes` holds the rules. The Bug Fables repo's
says `* text=auto` (git decides which files are text and normalises their endings) and `.githooks/* text eol=lf`
(the hooks are shell scripts, so always LF). Relatives worth knowing: a **BOM** ("byte order mark"), three invisible bytes
some Windows programs put at the start of a UTF-8 file, which some other programs then read as part of the first line;
**tabs versus spaces** for indenting (a tab is one byte that each editor shows at its own width); and **control
characters**, the codes below 32, which have no business in a text file except tab, LF and CR (MeshGhost's preflight
refuses the rest).

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
- `void` is not a kind of value but the lack of one: a function marked `void` hands nothing back (the mod's
  `internal static void Init(ManualLogSource logger)` only stores the logger it is given).
- **`const` and `readonly`** both say "this never changes", which is also a note to the reader. A `const` is fixed
  when the code is built, a compile-time constant: `internal const int MaxLength = 100;`, the most characters the mod
  keeps of any text a server sends. A `readonly` field is set once while the program runs, where it is declared or in
  the constructor (below), and can't be replaced after (Microsoft's C# reference, checked 2026-09-29).
- **Case** is capital versus small letters. C# and Python are *case-sensitive*: `MainManager` and `mainmanager` are two
  different names. Naming styles are named after how they look: `PascalCase` (C# classes and methods), `camelCase`
  (C# local variables and parameters), `snake_case` (Python), `UPPER_CASE` (Python constants, like the apworld's
  `CLASSIFICATIONS`). Conventions, not rules: the compiler takes any (part 7). The `case` of a `switch` is another
  word, below.

### Strings: text in code

A **string** is text, written between quotes. Four things happen to strings all the time:

- **Interpolated** strings, with a `$` in front, have holes in `{}` that are filled with values: the mod's log line
  `$"[moves] {Name(id)} pressed without its item: refused (buzzer)"` prints the field move's real name where
  `{Name(id)}` stands. (Python's version is the f-string, `f"..."`.)
- **Escapes and verbatim strings:** inside quotes, `\` starts an *escape*, a code for a character that can't be typed
  there as it is: `\n` a line break, `\"` a quote mark. A **verbatim** string, with `@` in front, switches that off and
  keeps every `\` as written. The mod's check for "a colon and one to five digits at the end" (a port number after a
  server address) is `@":\d{1,5}$"`; without the `@` it would have to be `":\\d{1,5}$"`. That pattern language is the
  *regular expression* (part 6).
- **Padding and alignment:** filling text out to a fixed width so things line up. `.PadLeft(2, '0')` turns `3` into
  `03` for the medals screen's two-digit attack number; `'{0,6}  {1}: {2}' -f ...` in the apworld's test script
  right-aligns each count in 6 characters, and a negative width would align it left (.NET's composite formatting,
  checked 2026-09-29).
- **Parsing** (part 1) turns text into a value. JSON's keys are always text, so the seed's per-location tables arrive
  keyed by strings like `"1234"`, which `long.Parse(p.Name)` turns back into numbers. `Parse` throws an exception
  (below) on text that isn't a number; `int.TryParse` returns false instead, and hands the number back through `out`
  (under functions), as the mod's shop code does with a price.

### Deciding: if, else, switch, not in

- **`if` / `else`:** `if (condition) { ... } else if (other) { ... } else { ... }` runs the first block whose condition
  is true. Python writes `elif` for "else if": `elif choice == StartingPartyMember.option_all_three:` (the apworld,
  choosing the starting party).
- **Conditions** combine with `&&` (and), `||` (or) and `!` (not) in C#, spelled `and`, `or` and `not` in Python. `==`
  asks "equal?" and `!=` "not equal?"; a single `=` *sets* a value instead. Python's `in` asks "is it in this
  collection?": `if loc.category not in SHOP_CATEGORIES:` followed by `continue` on the next line skips every
  location that isn't a shop's.
- **`switch` / `case`:** one value compared against a list of cases, neater than a chain of `else if`: `switch
  (gameId)`, then `case 4: return "Progressive Dash";` gives the item's name for the game's ability 4.
- **Short forms:** `c ? a : b` is "a if c, otherwise b", as a value; `x?.y` is "x's y, or null if x is null" instead of
  a crash; `x ?? y` is "x, or y when x is null".
- **Loops** repeat: `for` counts, `foreach` takes each item of a list in turn, `while` goes on while a condition holds;
  `break` leaves the loop, `continue` skips to its next round.

**Precedence levels** decide which operator runs first when one line has several, like "multiplication before
addition" in maths (`2 + 2 * 2` is 6). C#'s order, highest first, shortened (Microsoft's operator reference, checked
2026-09-29):

| Level | Operators |
|---|---|
| 1 | `x.y`, `f(x)`, `a[i]`, `x?.y`, `new`, `typeof`, `nameof` |
| 2 | `!x`, `-x`, a cast `(int)x` |
| 3 | `*`, `/`, `%` (remainder) |
| 4 | `+`, `-` |
| 5 | `<`, `>`, `<=`, `>=` |
| 6 | `==`, `!=` |
| 7 | `&&` |
| 8 | `\|\|` |
| 9 | `??` |
| 10 | `c ? a : b` |
| 11 | `=`, `+=` and the other assignments |

So the mod's `op == OpCodes.Ldc_I4 || op == OpCodes.Ldc_I4_S ? Convert.ToInt32(operand) : (int?)null` does both `==`
first, then the `||`, then the `? :`: "if this instruction is either kind of number, that number, otherwise nothing".
Brackets always go first, and they tell the reader too: when in doubt, add them.

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
- **Signature:** a function's name plus its parameters' types, which is what tells it apart from others. **Overloads**
  are functions sharing a name but taking different parameters; the compiler picks the one that fits what is passed.
  The game has two `MainManager.ChangeParty`, one taking a list of ids and one true/false, one taking a list and two,
  so the mod's patch names the second by its types: `typeof(int[]), typeof(bool), typeof(bool)`. Unity's
  `Material.GetColor` likewise takes a shader property (such as a glow colour) either by its name, as text, or by an ID
  number, and the mod asks for the one that takes a `string` (`new[] { typeof(string) }`).
- **`out`:** a parameter the function fills in, a second way of handing a result back:
  `slotData.TryGetValue(key, out object raw)` returns whether the key was there, and puts its value in `raw`.
- **`ref`:** a parameter that is the caller's own box rather than a copy, so the function can change the caller's value
  (part 5 shows why a patch needs it).
- **`typeof` and `nameof`:** `typeof(X)` is a value describing the class `X` (part 5). `nameof(InputIO.ReadFile)` is
  just the text `"ReadFile"`, but "evaluated at compile time" (Microsoft's reference): misspell it and the build fails,
  where a name typed in quotes fails only in the game (reflection, part 5). It works only on names the code may use
  from where it stands: the mod's own, private ones included, and the game's public ones. `InputIO` itself is one of the game's own classes, not a
  programming word: its methods read the keyboard and controller (`GetKey`, `JoyStick`) and read and write the game's
  files (`ReadFile`, `CreateFile`, `Save`). **IO**, "input/output", is the general word for anything a program takes in
  or puts out: files, the network, the keys.

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
- **Constructor:** the code that runs once as an object is made, filling in its fields. In C# it carries the class's
  own name and no return type: `internal SeedData(Dictionary<string, object> data, int ownSlot)` builds the mod's
  record of a seed from what the server sent, and `new SeedData(...)` is what runs it. (Inside a compiled DLL an
  object's constructor is named `.ctor`, and a class's static one, which sets up its static fields, `.cctor`.)

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

A method can be static too: `Hooks.Init(...)` is called on the class itself, with no object, so it can use only static
fields (and a patch on a static method gets no `__instance`, part 5).

**`private static readonly`, word by word**, as in the mod's connection code, `private static readonly int[]
RetrySeconds = { 2, 4, 8, 15, 30 };`:

- `private`: only this class's own code may use it (next section).
- `static`: one copy, belonging to the class, made once before the class is first used; not one per connection.
- `readonly`: never replaced by a different list after that. It guards the box, not what's in it: the numbers inside
  a `readonly` array could still be changed (Microsoft's C# reference, checked 2026-09-29).
- `int[]`: an array of whole numbers, the seconds to wait before each new attempt to reconnect, growing each time.

So static and private are separate choices: static says *how many copies* there are, private says *who may touch it*.

### Fields: public versus private

Each field has an access level:

- **public:** any code may read and change it.
- **private:** only the class's own code may. Any other code that even mentions it, to read or to change it, gets an
  error when the code is built (see compiling, part 3).
- **internal:** any code in the same assembly, the same DLL (part 3), and none outside it (Microsoft's C# reference,
  checked 2026-09-29). The Bug Fables mod marks almost everything `internal`, classes too (`internal sealed class
  SeedData`): its own files share freely, while the game and other mods can't reach in, short of reflection (part 5).
  `sealed` means no other class may be built on this one.

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

### Logs and loggers

A **log** is a program's running diary: lines of text it writes as it goes, saying what it did and decided, so that
someone can read afterwards what happened. A **logger** is the object code writes those lines through; it marks each
line with where it came from and how serious it is, and sends it on, to a file or a console window. The Bug Fables mod gets one from
BepInEx (a `ManualLogSource`, kept in a field named `log`) and writes three levels of line: `log.LogInfo(...)` for
what happened, `log.LogWarning(...)` for something off, `log.LogError(...)` for something broken. BepInEx collects
every mod's lines in `BepInEx/LogOutput.log`, the first file to read when something goes wrong. The `[moves]` or
`[boost]` at the start of each of the mod's lines is its own habit, so one feature's lines can be searched for at
once.

### Namespaces and using

A **namespace** is a family name for classes, so two libraries can each have a `Logger` without a clash: the mod's
classes sit in `namespace BugFablesAP`, and BepInEx's logger's full name is `BepInEx.Logging.ManualLogSource`. A
`using BepInEx.Logging;` line at the top of a file says "by `ManualLogSource` I mean that one", so the file needn't
spell out the family name every time; the top of any of the mod's files is a short list of them (`using System;`,
`using HarmonyLib;`). Python's `import` does the same job. (A `using (...) { }` *inside* code is unrelated: it makes
sure something, like an open file, is closed when the block ends.)

### When things go wrong: exceptions

- **Throwing an exception:** an error that **stops the current code on the spot** and jumps out until something
  catches it; nothing after it runs until a `catch` is reached (only `finally` blocks, cleanup code written to
  run whatever happens, run on the way). Unity logs it and carries on next frame, so it *looks* like "log
  and continue", but the work was left half done. One thrown every frame means that work never finishes.
- **`try` / `catch`:** `try` runs some code; if an exception is thrown inside, it lands in `catch` instead of
  crashing out, and the code decides what happens (log it, fall back). It catches the error afterwards; it doesn't
  prevent it.

### Algorithms, and the data around them

- **Algorithm:** a recipe, a fixed list of steps that solves a kind of problem whatever the input: sorting a list,
  finding a path, or Archipelago's **fill**, which places every item in some location so that the seed can be
  finished. The algorithm is the method; code is one way of writing it down.
- **Table:** data laid out in rows and looked up by a key, instead of written as logic. The apworld's
  `CLASSIFICATIONS = {` maps the words its item list uses (`"progression"`, `"filler"`) to Archipelago's own values,
  and the mod reads tables built from the same apworld, so both sides agree. Adding a row is adding data, not code.
  (Python calls one a *dict*, C# a *Dictionary*.)
- **Hash:** a short fingerprint computed from any amount of bytes. The same bytes always give the same hash; one bit
  changed gives a completely different one; and the bytes can't be rebuilt from it. **SHA-256** (64 hex digits) is the
  usual one: the mod's release script builds the DLL again and compares its hash with the committed one's, and
  `copy-dev.ps1` prints the start of the copied DLL's, so "same hash" means "same file" without comparing every byte.
  Git names everything by its hash (part 6).
- **Seed:** a computer can't roll dice, so a *pseudo-random* generator makes numbers that only look random, worked out
  from a starting number, the **seed**: the same seed gives the same numbers in the same order. Archipelago starts its
  generator from the seed and gives each world a generator of its own drawn from it (`self.random`, in its
  `AutoWorld.py`), so the same seed, options and versions generate the same multiworld; the apworld's
  `self.random.randrange(len(items.MEMBERS))` picks a random starting party member that way. CI generates with
  `--seed 1`, `2` and `3`, the same games every run, so a failure can be repeated. In Archipelago talk, "a seed" also
  means the generated game itself.
- **Cache:** a kept copy of something slow to get, so the next time is fast: a field looked up by name (part 5) once
  and kept, instead of every frame; CI's `cache: pip`, which keeps downloaded Python packages between runs; the
  Archipelago client library keeping each game's data package on disk (the mod's `CachePaths.cs` keeps those files'
  names safe).
  "Cached" means served from the copy. The classic cache bug is a **stale** one: the copy no longer matches the real
  thing, and nothing notices, because everything reads the copy.

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
  code keeps almost none of that. It reads like `ldfld basespeed` ("read the field basespeed"). Each instruction is
  an **opcode** ("operation code": the number meaning *read a field*, *call*, *add*) plus, for some, an **operand**,
  what it works on (here `basespeed`). A transpiler (part 5) edits these: the mod's `code[read].opcode =
  OpCodes.Call;` turns one instruction into a call, and the line after it sets the operand, the method to call.
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

**Native imports:** a native program's header lists the functions it needs from other DLLs, its **import table**, and
Windows finds each of them as it loads the file. A .NET DLL like the mod's carries exactly one, `_CorDllMain` in
`mscoree.dll`, the
starter that hands it over to the runtime; everything else it calls is in its metadata and linked by the runtime
(step 2 above). So the Bug Fables mod's preflight (part 6) checks that its built DLL imports that one function and
nothing else: any other *native import* would mean code outside .NET. C# can call native code on purpose, with
`[DllImport]` ("P/Invoke"); the mod never does, and its preflight refuses a file that tries.

### Packages, NuGet and restore

A **package** is a library bundled for sharing: its DLLs plus a name, a version and a list of the other packages it
needs. A **package manager** fetches them: **NuGet** for .NET, **pip** for Python, Go's modules for Go. The Bug Fables
mod's project file lists what it needs, `<PackageReference Include="BepInEx.Core" Version="5.4.21" />`, and a
**restore** downloads each listed package, and the ones those need, before a build. Its **lock file**,
`packages.lock.json`, records the exact version and a hash of each package the restore picked, and the mod restores in
*locked mode*, which fails rather than quietly take anything different (NuGet's documentation, checked 2026-09-29).
Updating a package is a deliberate act, with the lock file committed alongside.

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
- **Synthesized (compiler-made) code:** the compiler also writes code nobody typed. A coroutine becomes a hidden class
  whose `MoveNext` method runs its steps (part 4); a short inline function (a *lambda*, like `p => long.Parse(p.Name)`)
  becomes a method with a name like `<Run>b__3_0`, in a class named `<>c`; constructors are `.ctor` and `.cctor`. Names
  with `<` and `>` can't be written in C#, so they never clash with a real one. ILSpy folds them back into the code
  they came from, which is why the decompiled game shows each cutscene as one ordinary method (seen 2026-09-29). The
  Bug Fables mod's preflight checks that every name in its built DLL comes from a source file or is one of these (its
  `dll_synthesized_members` list). Outside code, *synthesize* is plain English for "make from parts": a test that
  "synthesizes a walk" makes one up instead of recording one.

**Private is not hidden.** A Mono game's `Assembly-CSharp.dll` keeps every field's name and type, private ones
included, so ILSpy shows them all. Private only stops *our* code from naming them directly.

### Programs on other systems

Not just an EXE with another header. Each system has its own container (Windows PE, magic `MZ`; Linux ELF, magic
`0x7F` then `ELF`, usually no extension; macOS Mach-O, an app's inside a `.app` folder), the machine code must suit
the CPU (an Intel/AMD PC and an Apple Silicon Mac differ), and each system is asked for files, windows and the network
its own way. So a program is built once per system and CPU, one download each; Go builds them all from the same code.
A .NET DLL is the exception: IL runs wherever a runtime does. On Linux a file runs if it is *marked* runnable (a
permission), which a `.tar` keeps and a plain zip can lose.

### ROMs, ISOs and dumps

**ROM** is Read-Only Memory: a chip whose bytes were fixed at the factory, like the one inside a Game Boy cartridge. A
**ROM file** (`.gba`, `.gbc`) is those bytes copied off the chip into a file, byte for byte. Copying them off is
**dumping** the chip, and the file is a *dump*.

**How one is built:** like any program, compiled to machine code, but for one fixed machine. The game's code becomes
machine code for the console's CPU (an ARM chip, in the Game Boy Advance), then it is joined with the graphics, sound
and text into one image, each piece at the address where the game will look for it. There is no loading step: the
cartridge is wired in *as memory*, and the CPU reads the game straight off the chip. At its start sits a header that
the console checks before running anything; on the GBA, a copy of the Nintendo logo and a checksum, and the cartridge
won't start if either is wrong (GBATEK, checked 2026-09-29). The pret projects rebuild these games from reconstructed
source, and a correct build comes out byte-identical to the original: MeshGhost's Emerald build passed `make
compare`, which checks the result's SHA-1 hash against the original's ([environment.md](environment.md), 2026-08-11).

**An ISO** is a disc image: every sector of a CD or DVD in one file, *including the disc's file system*. The name comes
from ISO 9660, the standard file system of CDs, named after the International Organization for Standardization
(Wikipedia, "Optical disc image", checked 2026-09-29). So a disc game isn't one flat image like a cartridge but a file
system full of files, a program and its data, which the console loads into RAM, much as a PC loads a game from its
drive. An emulator treats a ROM file as the chip and an ISO as the disc.

**Archipelago and ROMs:** a ROM can't be handed out, so for a ROM game Archipelago gives each player a **patch** file
instead (`.apemerald` for Emerald): only the differences, which Archipelago's launcher applies to the player's own
ROM to make that seed's game.

**Other dumps:** any raw copy written out to look at. A *memory dump* is a program's RAM at one moment, a *crash dump*
its memory at the moment it crashed. The Bug Fables mod has dev dumps of its own (`EntityDump`, `MapDump` and others),
which write what the game holds, every entity in a room or every map, as a table (a `.tsv` file) that a script like
`door-graph.py` then reads to work out how the rooms connect.

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

### Positions and maths: vectors, Rect, Mathf

A **vector** in Unity is a few numbers treated as one: **`Vector3`** is x, y and z, a point in the 3D world or a
movement (a direction and a distance); **`Vector2`** is x and y. The mod lines the party up behind the leader with
`at + new Vector3(-0.6f * i, 0f, 0.1f * i)`: the leader's position, shifted a little further for each member (-0.6 on
x, 0.1 on z). (In C++, a `vector` is something else entirely: a list that can grow.)

A **`Rect`** is a rectangle: x, y, width and height. The mod's menus use one right beside a vector:
`Sprite.Create(pixel, new Rect(0f, 0f, 1f, 1f), new Vector2(0.5f, 0.5f))` makes a sprite out of the 1-by-1 square of a
one-pixel texture (the Rect, counted in the texture's pixels), with its **pivot**, the point it is placed and turned
by, in the middle (the Vector2, where `0, 0` is the bottom left and `1, 1` the top right). And the dev console draws
its box with `GUI.Box(new Rect(10, Screen.height - 70, Screen.width - 20, 60), ...)`: 10 pixels from the left, its top
70 pixels above the bottom edge, as wide as the screen less 20, and 60 tall, because on-screen GUI counts down from
the top left (Unity's scripting reference and manual, checked 2026-09-29).

**`Mathf`** is Unity's box of maths functions: `Mathf.Clamp(value, min, max)` keeps a number inside a range, so the
shop's `mm.money = Mathf.Clamp(mm.money - price, 0, 999);` can never take the berries below 0 or above 999. The mod
also uses `Mathf.Max` (the larger of two) and `Mathf.RoundToInt`. Plain .NET's own is `Math`.

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

**Hook** is the general word for attaching your own code to run when something else happens: every Harmony patch is a
hook (the Bug Fables mod installs its patches through a file called `Hooks.cs`), and so are git's hooks (part 6). A
**wrapper** is code whose job is mostly to call other code, adding a little around it: the game's `InputIO.ReadFile`
and its siblings each take a file name and do the file work, which is why the mod's save redirect patches those few
instead of every place that loads a save. A prefix plus a postfix *wrap* a method.

**The third kind of patch: the transpiler.** A prefix or a postfix is code that runs every time the method is called.
A **transpiler** runs once, when the patch goes in (and again whenever another transpiler is added to the same
method): Harmony hands it the method's IL instructions (the opcodes of part
3) as a list, and the list it hands back *becomes* the method from then on ("codes in, do something, codes out", in
Harmony's documentation, checked 2026-09-29). It can change one step in the middle of a method, where no prefix or
postfix reaches: the mod's `GlowGuard` swaps each colour read in the game's light code for a guarded one, so a light
without a glow colour stops logging an error, and its frame-rate work edits timings that way. The most powerful kind
and the most fragile: it finds its spot by matching instructions, so a game update that moves them breaks it, and two
mods rewriting the same method can clash.

**Two ways to install patches.** Most of the mod's patches are *declared* with attributes (part 2):
`[HarmonyPatch(typeof(NPCControl), "SetUp")]` names the target (in quotes, because `SetUp` is private), and
`[HarmonyPrefix]`, or simply naming the method `Prefix`, says which kind: "Harmony will find them by their name", or
by the attribute (its documentation). The mod then hands Harmony a whole class at a time to install. The other way is
**imperative**, giving the commands yourself, in order: `harmony.Patch(method, transpiler: new
HarmonyMethod(typeof(FrameSites), nameof(Transpile)))`, for targets known only once the game runs, like a list of
methods worked out at start-up, or a coroutine's compiler-made `MoveNext` (part 3), which the mod finds with
`AccessTools.EnumeratorMoveNext`. *Imperative* is a grammar word too, for a command, which is why commit subjects are
asked to be imperative: "Add the attack boost", not "Added".

**Patch parameters are matched by name.** Harmony fills a patch's parameters from the original method's parameters of
the same name, besides its special ones (`__instance`, `__result`, `___field`). So **`basevalue`** in the mod's attack
boost is not a programming word but *the game's own parameter name*: its private `BattleControl.CalculateBaseDamage`,
which runs for each hit, takes an `int basevalue`, the number that hit's damage is worked out from. The mod's prefix
declares `ref int basevalue`, and its `basevalue++` adds 1 to the game's own number before the method goes on with it.
The `ref` (part 2) is what lets the change reach the game; without it the prefix would only change its own copy
(Harmony's documentation, checked 2026-09-29).

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

## Part 6: Around the code: scripts, git and checks

### Scripts and shells

A **script** is a text file of commands that an **interpreter** runs as it reads them, with no separate build: change
it and run it again. A **shell** is the program that reads the commands you type, or a script holds: **PowerShell** on
Windows (its scripts end `.ps1`, like the Bug Fables mod's `copy-dev.ps1`, `build-release.ps1` and
`test-apworld.ps1`), the older **cmd** (`.bat`), and **bash** on Linux and macOS, on Windows too as Git Bash (`.sh`;
git's hooks are written for `sh`, bash's plainer ancestor, which bash also runs). Python files (`.py`) are scripts as well, run by Python, and that is where the heavier checks live
(the mod's `preflight.py`). The agent's two shell tools are exactly these: Bash and PowerShell.

### sed and its relatives

**sed** is a program, not anything in our code: the *stream editor*, a standard Unix tool (Git for Windows ships GNU
sed 4.9), which reads text line by line and applies editing rules to it. Its best-known rule is find-and-replace,
`s/old/new/`. By default it prints the edited text and leaves the file alone; `-i` edits the file **in place** (sed's
own `--help`).

A **sed edit**, or any **scripted edit**, is a file changed by running such a rule instead of by opening it: fast
across many files, but blind to what it touches, so the result must be read back. Two real ones:

- On 2026-09-24 the agent tried `sed -i` to add `EntityDump = true` to the Bug Fables mod's settings file inside the
  game folder. Claude Code refused it as "irreversible local destruction", and the project's rules now send every change
  in the game folder through `copy-dev.ps1`, which backs up what it replaces.
- In daily use, the Bug Fables commit-message hook finds a message's subject with
  `grep -v '^#' "$msg_file" | sed -n '1p'`: grep keeps every line that doesn't start with `#` (git's comment lines),
  and `sed -n '1p'` prints only the first of them (`-n` stops it printing everything, `1p` prints line 1).

That `|` is a **pipe**: one program's output becomes the next one's input. Its relatives are small programs that each
do one job on text, built to be chained that way:

| Program | Does |
|---|---|
| `grep`, and the faster `rg` (ripgrep) | prints the lines that match a pattern |
| `awk` | splits lines into columns and works with them |
| `head` / `tail` | the first or last lines |
| `wc -l` | counts lines (the Bug Fables `CLAUDE.md`'s line cap is checked with it) |
| `find` | lists files by name, size or date |
| `diff` | shows what changed between two files |
| `jq` | reads and edits JSON |
| `curl` | fetches a web address |

PowerShell has its own, longer-named versions (`Select-String` for grep, `Get-Content` for reading a file,
`Measure-Object -Line` for `wc -l`), which pass objects along instead of text. The pattern language grep and sed
share is the **regular expression** (*regex*), the same kind as the port check `@":\d{1,5}$"` in part 2.

### Heredocs

A **heredoc** ("here document") puts several lines of text straight into a shell command, up to a marker word of your
choice. This is how the agent writes a commit message from bash:

```bash
git commit -F - <<'EOF'
Add the attack boost

Why it was added, in a line or two.
EOF
```

Everything between `<<'EOF'` and the line `EOF` is handed to `git commit` as if typed into it (`-F -` means "read the
message from there"). The quotes around the first `EOF` mean "take it as written": no `$variables` are filled in. The
Bug Fables preflight's test lists a commit of this shape among the commands the agent must stay free to run, while
`git commit --no-verify` is refused. PowerShell's version is the **here-string**, `@'` on one line and `'@` at the very start of
the closing line.

### Git under the hood

Git is, underneath, a store of **objects**, each saved under the hash (part 2) of its own content in `.git/objects`:
"a content-addressable filesystem", as git's own book puts it. Three kinds matter:

- a **blob** is one file's content: just the bytes, no name;
- a **tree** is one folder: a list of names, each pointing to a blob (a file) or another tree (a folder) by its hash;
- a **commit** is a short note: "the project looked like *this tree*; before me came *this commit*; who, when, and
  why".

MeshGhost's latest commit, read with `git cat-file -p HEAD` on 2026-09-29 (the names, email addresses and times
replaced, the message cut):

```text
tree d44ce8649b24ef3b4d560c8ebee858349d3992c1
parent 0a07025e808f831289b0fdf0a8105397f32a95f4
author <name> <email> <time>
committer <name> <email> <time>

status.md: PINNED items never age out; ...
```

and three lines of the tree it points to (`git cat-file -p 'HEAD^{tree}'`; `100644` is an ordinary file, `040000` a
folder):

```text
100644 blob 4d38e26eb20416f2aeb557d06330ccec71c1c40a    .gitattributes
040000 tree 715b8a33d7f3f58d0b07f7a20ae463dbef2b5f31    .githooks
100644 blob 756e41a1512bdf9b6ada97fe1e803a4c72f4f515    CLAUDE.md
```

**What a commit does, step by step.** `git add` stores each changed file as a blob and notes it in the **index**
(also called the staging area: the list of files the next commit will hold). `git commit` then writes a tree for each
folder from the index, then a commit pointing at the top tree and at the commit before it, its **parent**, and
finally moves the branch to the new commit. From that:

- **A commit is a snapshot, not a list of changes.** A diff is worked out when you ask for one, by comparing two
  trees. An unchanged file costs nothing: its hash is the same, so the new tree simply points at the same blob.
- **A branch is a small file holding one commit's hash** (`.git/refs/heads/master`), and **HEAD** is a file naming the
  branch you're on (MeshGhost's reads `ref: refs/heads/master`). Committing writes the new hash into the branch file;
  that is all "moving the branch" means.
- **History is the chain of parents.** Each commit holds its parent's hash, and its own hash covers that, so changing
  any old commit changes every hash after it: history can't be quietly edited.
- **Merge:** a commit with two parents, joining two lines of work. When one side has nothing new of its own, git just
  moves the branch forward instead, a **fast-forward** (MeshGhost's rule `git merge --ff-only` allows only that).
- **Push and pull:** push sends the other side the objects it lacks, then moves its branch; pull fetches theirs and
  merges it into yours.
- **Storage:** each object is compressed (zlib, per git's book), and git later packs objects together into
  **packfiles**, storing similar files as differences from each other. MeshGhost on 2026-09-29: 886 loose objects
  and about 29,400 packed into 4 packs (`git count-objects -v`).

### Checks: lint, hooks, preflight, tests

- **Lint:** a **linter** reads code without running it and flags what looks wrong or breaks the style: an unused
  variable, an `import` in the wrong place. It is named after the fluff a clothes dryer's lint trap catches; the first
  was a 1978 Unix tool for C (Wikipedia, "Lint (software)", checked 2026-09-29). Python has ruff and flake8, C# has
  analyzers in its compiler. A line can silence one rule on purpose: `import dotnet_metadata  # noqa: E402` in the Bug
  Fables preflight says "yes, this import isn't at the top of the file (rule E402), and that's deliberate": it has to
  come after the line that tells Python where to find it.
- **Git hooks** are scripts git runs at fixed moments, and if one fails, git stops. The Bug Fables repo's
  `.githooks/pre-commit` runs its preflight before every commit, and `commit-msg` checks the message; MeshGhost's
  `pre-commit` runs a scan of its own, for home paths and stray files. A clone runs them only once told where they live
  (`git config core.hooksPath .githooks`), and `--no-verify` would skip them, which both projects forbid.
- **Preflight** is borrowed from pilots: the checklist before take-off. In both projects it is a script (the mod's
  `preflight.py`, MeshGhost's `preflight.ps1`) that refuses what must never be committed or released: a home path, a
  private name, a game's file, and more. Both run it in CI and before a release; the Bug Fables repo also runs it from
  its hooks.
- **Tests** are code that runs your code and checks its answers. An **assert** is one check: an apworld test's
  `self.assertEqual(self.world.fill_slot_data()["start"], {})` fails the test, and says so, if the two sides differ.
- A **fixture** is the prepared thing a test runs on (a known input, a sample file, a starting state), so every run
  starts the same. The Bug Fables preflight has a test of its own with 76 fixtures on 2026-09-29, most of them a known
  violation planted in a scratch copy of the repo, and it checks that preflight answers each one as expected (71 must
  fail it outright).
- A **harness** is the machinery around tests: it sets them up, runs each one and collects the results (in that same
  test, a class named `Harness` keeps the tally). The word is used for anything that runs something and controls its
  surroundings: the program that runs an AI agent, with its tools and permissions, is called its harness too.
- **Fuzzing** is testing with a flood of random input, to find the rare case nobody thought to write a test for. The
  Bug Fables apworld goes through the Archipelago fuzzer, which generates 10,000 seeds from random options on every
  test run and in CI (`test-apworld.ps1`); MeshGhost's Go code is fuzzed in CI, and a failing input comes back as an
  artifact (below) to be turned into a test.

### CI, artifacts and releases

**CI** (continuous integration) is a server that builds and tests every push, so a mistake is caught when it lands
rather than whenever someone next runs the tests. Both projects use GitHub Actions: each **workflow** is a `.yml` file
in `.github/workflows/`, a list of jobs and their steps, run on GitHub's machines. The Bug Fables repo has three:
`ci.yml` (the apworld's tests on three Python versions, a build of the apworld, the fuzzer), `preflight.yml`
(preflight over the commit and the whole history) and `release.yml` (builds, checks and publishes a release). A run
ends **green**, every job passed, or **red**.

An **artifact** is a file a run produces and keeps for download: the built apworld (`actions/upload-artifact`), or
the fuzzer's failures. `release.yml` downloads the apworld that CI built rather than building it again, so what is
released is exactly what was tested.

A **provenance attestation**: *provenance* is where something came from, an *attestation* a signed statement about
it. At release, GitHub signs a record that says "this file, with this hash, was built by this workflow, in this
repository, from this commit", signed through Sigstore so it can't be forged (GitHub's documentation, checked
2026-09-29). Anyone can then check a downloaded apworld with `gh attestation verify`: a file changed after the build,
or built anywhere else, fails.

**Merge** outside git means the same joining: `dict(json.loads(manifest), **BUILDER_FIELDS)` in the release check
merges two tables into one, the second one's values winning where both have the same key.

## Part 7: Reading and judging code

### Whose name is it?

Reading code starts with knowing where each word comes from. One line of the Bug Fables mod can hold five owners:

| Kind | Examples | Who decided it |
|---|---|---|
| The language's keywords | `private`, `static`, `void`, `if`, `return` | C#; fixed, and coloured by the editor |
| A library's names | Harmony's `Prefix`, `Postfix`, `__instance`, `AccessTools`; Unity's `Update`, `Vector3`, `Mathf` | the library; spelled exactly its way |
| The game's names | `MainManager`, `BattleControl.CalculateBaseDamage`, `basevalue` | the game's developer; read from its DLL |
| Our names | `SeedData`, `AttackBoost`, `RetrySeconds`, `BeforeBaseDamage` | us; could have been anything |
| Programs, not code | `sed`, `git`, `grep`, `dotnet`, `python` | separate programs, run from a shell |

So `Postfix` isn't a name the mod made up: a method named `Postfix` in a patch class is found by Harmony *because* of
that name, and a method named anything else can be marked `[HarmonyPostfix]` instead (the attack boost's prefix is
called `BeforeBaseDamage`). And `sed` is in no `.cs` file at all: it is a program, like `git`.

### Does it matter if it works?

Yes, though not for the computer's sake: it runs messy code as happily as clean code. It matters for the next person
to change it, often yourself: "code is read much more often than it is written" (Guido van Rossum, quoted in Python's
style guide, PEP 8). Bad code works *today*; its cost shows up at the next change: a fix in one place breaks another,
the same bug lives on in three copies, nobody can tell what a number means or whether a check is still needed. For a
mod, the next change often isn't chosen: the game updates, Archipelago updates, and the code must be understood again,
quickly.

It matters least for a throwaway script run once, or a probe deleted after one measurement; most for code others build
on, and for code where a mistake is expensive, like anything that writes a save.

### Spotting trouble at a glance

None of these proves a problem; each is a reason to look closer.

- **Names that say nothing:** `data2`, `temp`, `flag`, `DoStuff`. A good name makes a comment unnecessary.
- **A function doing many things:** long, with blank lines between its "phases"; each phase wants to be a function.
- **The same code pasted twice:** the next fix reaches one copy and not the other.
- **Deep nesting:** an `if` in a `for` in an `if` in a `try`. An early `return` often flattens it: the mod's patches
  check their conditions first and `return` straight away when one fails.
- **Magic numbers** (part 5) with no name: `windowid != 2` says nothing, where the mod's `windowid != MedalsWindow`,
  with a one-line comment on the constant, says which screen.
- **Comments that narrate the code** (`// add 1 to i`) instead of saying *why*; old code left commented out.
- **Errors swallowed:** an empty `catch { }`, or catching every exception, so a failure vanishes instead of being
  logged.
- **Checks for things that can't happen**, piled up "just in case", hiding the ones that matter.
- **Mixed styles** in one file, and **clever one-liners** that take a minute to decode.

**Efficiency** at a glance is about *where* code runs more than *how*: a line costs nothing once at start-up and a lot
60 times a second in `Update()`, or once for each of thousands of items. The warning signs: looking something up by
name (reflection, part 5) every frame instead of once, and keeping it in a cache (part 2); new lists or strings every
frame, which the garbage collector (part 3) must clean up, sometimes with a stutter; a loop inside a loop over big
lists. And measure before speeding anything up: most code is not where the time goes.

### What modders look for

- **It touches only what it must:** a postfix that adjusts one result rather than a prefix that replaces a whole
  method (a prefix returning `false` skips the game's method for every mod patching it; in HarmonyX, the Harmony that
  BepInEx ships, the other prefixes still run, where original Harmony would skip those too: HarmonyX's wiki, checked
  2026-09-29).
- **It fails safely when the game changes:** each target is looked up, and when one is missing the feature logs what
  it lost and switches itself off instead of crashing the game (the mod's `[boost] NOT installed ...` lines).
- **It plays well with other mods,** and costs little per frame: nothing heavy in `Update()` or in patches on methods
  the game calls constantly.
- **It logs what it decided,** not only what happened, so a player's log can be read.
- **It never ships the game's code or files,** and says honestly what it changes.

### Judging code written by an AI

AI-written code goes wrong in its own recognisable ways, because a language model writes what *looks* right:

- **Invented names:** a method, parameter or setting that sounds exactly right and doesn't exist, or exists only in
  another version. The most common failure, and the reason both projects' rules say no name, address or API from
  memory: each one traces to a file or a documentation page.
- **Confident explanations of wrong code:** the prose sounds as sure when it is wrong as when it is right.
- **Fixing the symptom:** hiding an error message, a `try`/`catch` around the crash, a special case for the one input
  that failed, instead of finding the cause.
- **Over-defending and over-explaining:** checks and fallbacks for things that can't happen; a comment on every line.
- **Not reading the room:** a new helper written when the project already has one; a style unlike the file around it.
- **Tests that prove nothing:** a test that checks the code does what it does rather than what it should, or one that
  would pass without the fix.

**How to check it** is the same as for any code, only never skipped: does it build; does a test fail without the
change and pass with it; does every name trace to a source; and read the diff, every line, asking why about any line
you can't explain. For a mod, the last check is always the game on screen: "it ran without errors" isn't evidence,
because a wrong hook fails silently.

### One right way?

No. There are many correct ways to write the same thing, and people who know what they are doing disagree: tabs or
spaces, where braces go, one long function or five short ones. What exists instead:

- **Language conventions** most code follows: in C#, `PascalCase` for classes and methods and `camelCase` for local
  variables (Microsoft's naming conventions, which add that "the compiler doesn't enforce them"); in Python, PEP 8
  (`snake_case`, four-space indents).
- **Tools that end the argument:** a **formatter** rewrites code into one standard layout. Go goes furthest: `gofmt`
  lays out all Go code the same way, so no one debates it ("formatting issues are the most contentious but the least
  consequential", *Effective Go*), and MeshGhost's CI fails Go code that isn't in that shape.
- **Project rules:** Archipelago's `style.md` for its worlds; the Bug Fables mod's "comments are lean".

And the one that outranks the rest: **match the code around you.** PEP 8 puts it in order: consistency with the guide
matters, "consistency within a project is more important", and "consistency within one module or function is the
most important". A file in one consistent style, even one you wouldn't have chosen, reads better than a file in two
good ones.
