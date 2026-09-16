# Dependencies — what to install on a fresh machine

**The situation this file is for**: a fresh Windows 11 install, VS Code with the Claude extension,
and a clone of this repo. Nothing else. This is what to install so the clone can be worked on, in
tiers by what each install unlocks, so you stop at the tier you need.

**What this file is not.** It is not an inventory of every program the project touches, and it
never carries a version number or an install path: those are dated, machine-confirmed facts and
they live in [environment.md](environment.md), which also holds the traps each tool has sprung.
Read that file after this one. Written 2026-09-16; every claim below names the repo file that
needs the tool, so a tool that stops being called can be removed from here.

## Tier 1 — the Go side: client, relay, tests, preflight, commits

Enough to build `meshghost.exe` and `meshghost-relay.exe`, run every test that needs no game, run
the gates, and commit.

- **Git for Windows.** Everything: the clone, the hooks, and `dev-scripts/preflight.ps1`, whose
  gates run as `git ls-files` and `git grep`. Two commands after cloning, both required:
  `git config core.hooksPath .githooks` (preflight FAILS without it, and the hook is what keeps
  a machine-specific path out of history) and `git submodule update --init` (the RE-UE4SS
  submodule under `adapters/pseudoregalia/MeshGhostPseudo/`, which even a Go-only session needs
  present for preflight's file listing to be complete).
- **Go.** The version `go.mod`'s `go` directive names, or newer; CI pins the same floor. Unlocks
  `dev-scripts/run-gotests.bat`, the root binaries (`go build -o meshghost.exe ./cmd/meshghost`
  and the three beside it; `dev-scripts/README.md` lists them), and everything in
  `docs/reviewing.md`. `gofmt` and `go vet` come with it.
- **Windows PowerShell 5.1.** Already on Windows 11. Every `.ps1` in `dev-scripts/` targets this
  edition, not PowerShell 7, and every `.bat` is launched through `$env:ComSpec`
  ([../CLAUDE.md](../CLAUDE.md), the PATH rule).
- **GitHub CLI (`gh`)**, then `gh auth login`. Reading what CI did after a `.go` commit is a
  standing rule (`gh run list -L 5`), and `dev-scripts/release.ps1` drives a release through it.

## Tier 2 — the race detector and the Lua gates

One install, two things unlocked. Skip it and `run-gotests.bat` still runs; the race detector and
preflight's Lua parse check do not.

- **MSYS2**, then from its own shell: `pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-lua`.
  - gcc gives Go the cgo it needs for `dev-scripts/run-gotests-race.bat`, which probes for a
    usable compiler at the mingw64 bin folder among others and says what to install if none
    passes.
  - `luac.exe` is what preflight's Lua sections call, by absolute path into the mingw64 bin
    folder, to prove every tracked `.lua` parses (`.github/workflows/lua.yml` does the same on
    Linux).
  - **Do not put MSYS2 on `PATH`.** Every script that needs it reaches in by absolute path, on
    purpose: a shadowed `gcc`, `cmake` or `cmd` on `PATH` has cost this repo live sessions three
    times, and preflight fails a dev-script that calls any of those by bare name
    ([environment.md](environment.md) Host; `pitfalls/INDEX.md`).

## Tier 3 — per game, only when working on that adapter

Each game is independent. Install only the row you are about to work on.

### Pokémon Emerald and Pokémon Crystal (BizHawk, Lua)

- **BizHawk**, the version recorded in [environment.md](environment.md)'s BizHawk section, plus a
  ROM you own for each game. The adapters are Lua scripts BizHawk runs; no compiler, no build
  step. BizHawk embeds Lua 5.4, which is why Tier 2's `luac` is pinned to 5.4 too.
- Nothing else. The dev launchers that start BizHawk with a ROM are `.local.bat` files, untracked
  because they carry this machine's paths; `dev-scripts/README.md` says how to make yours.

### TEVI (Unity, C#, BepInEx)

- **.NET SDK**, the major version `.github/workflows/tevi.yml` pins with `setup-dotnet`. It
  builds the plugin (`dev-scripts/build-tevi.bat`, a `netstandard2.0` class library) and runs the
  test harness under `adapters/tevi/MeshGhostTevi.Tests/`. The `.csproj` restores its own NuGet
  packages (`BepInEx.Core`, `UnityEngine.Modules`); nothing to install for those.
- **The game**, on Steam, with **BepInEx 5.4.x, 64-bit, Mono** unzipped into its folder: the same
  steps a player follows in `docs/getting-started.md`.
- **Two DLLs copied out of your own install**: `Assembly-CSharp.dll` and `Newtonsoft.Json.dll`
  from the game's `TEVI_Data\Managed\` into `adapters/tevi/MeshGhostTevi/lib/`. The `.csproj`
  references them by that path; they are gitignored and never committed, which is why CI cannot
  build this adapter and the built DLL is committed under `packaging/release/games/tevi/` with a
  `built-from.txt` staleness record instead (`build-tevi.bat`'s header).
- Optional, for hot reload and inspection: ScriptEngine (from BepInEx.Debug), UnityExplorer,
  dnSpyEx and `ilspycmd` (`dotnet tool install -g ilspycmd`). Which asset of each matches this
  game's build, and why, is in [environment.md](environment.md)'s Unity/TEVI section;
  `dev-scripts/tevi-hotreload.ps1` assumes ScriptEngine is present.

### Pseudoregalia (Unreal Engine 5, C++, UE4SS)

- **CMake**, installed with `winget install Kitware.CMake` so it lands where
  `dev-scripts/build-pseudoregalia.bat` looks first (`C:\Program Files\CMake\bin\`); the
  `CMakeLists.txt` under `adapters/pseudoregalia/MeshGhostPseudo/` states the minimum version.
- **Visual Studio 2022 Build Tools with the C++ workload** (the `VC.Tools.x86.x64` component).
  CMake generates a VS solution and the build config is `Game__Shipping__Win64`.
- **The game**, on Steam. The UE4SS runtime the mod loads under ships in this repo's release
  folder, staged by `dev-scripts/stage-ue4ss-runtime.bat` from the submodule; a player's install
  steps are in `docs/getting-started.md`.
- **The RE-UE4SS submodule's private dependency.** The submodule itself is public, but its
  `UE4SS` CMake target hard-depends on `deps/first/Unreal`, a repository you can clone only after
  linking your GitHub account to an Epic Games account and accepting the EpicGames organisation
  invite. Then `git submodule update --init deps/first/Unreal` inside the submodule. This is the
  other reason CI cannot build this adapter and its `main.dll` is committed with a `built-from.txt`
  ([environment.md](environment.md) Host; `phases/phase7.md` for the one-time configure).
- Configure the build tree once under `adapters/pseudoregalia/MeshGhostPseudo/build/`;
  `build-pseudoregalia.bat` only ever runs `cmake --build` against it. `.vscode/settings.json`
  points the CMake extension at that source folder if you use it.

## Tier 4 — optional, dev-scripts only

- **Python 3.** Three analysis scripts in `dev-scripts/` (`lua-forward-refs.py`,
  `read-minidump.py`, `replay-cadence.py`); no CI step and no build calls Python. Invoke it as
  `python`, the only name on `PATH` here.
- **SteamCMD.** Pulls the standalone TEVI depot for the two-instance rig
  ([environment.md](environment.md) Unity/TEVI, `dev-scripts/README.md`'s runbook).
- Nothing personal goes here: a screen recorder, an editor, or a utility only you use is not a
  dependency. A program belongs on this list only if a tracked script, workflow or build file
  calls it.

## After installing

- **Environment variables preflight reads**, so its deployed-copy checks run instead of warning:
  `MESHGHOST_TEVI_DLL`, `MESHGHOST_TEVI_DLL_ALT`, `MESHGHOST_PSEUDO_DLL` and
  `MESHGHOST_PSEUDO_SCRATCH`, each the full path of the file in your game install. They are
  variables rather than literals because install paths are machine-specific and this repo is
  public (`preflight.ps1`'s header).
- **First checks**, in order: `dev-scripts/preflight.ps1` (read-only; it names anything missing
  above), then `dev-scripts/run-gotests.bat` with any VPN off ([environment.md](environment.md)
  Onboarding: a connected VPN fails every loopback UDP test with an address error that looks
  like a code bug), then `run-gotests-race.bat` if Tier 2 is in.
- Every dev log goes to `dev-logs/`, which is tracked as an empty folder on purpose
  ([environment.md](environment.md) Workspace conventions).

## Deliberately not listed

Go module dependencies (`go.mod`, fetched by `go build`), NuGet packages (restored by
`dotnet build`), the actions and runner tools CI uses (`.github/workflows/`, the runner's, not this
machine's), and SignPath (`docs/code-signing.md`, an external service with no local install).
