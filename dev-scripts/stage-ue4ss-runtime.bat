@echo off
rem MeshGhost -- stages a UE4SS runtime bundle under
rem packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64\, mirroring the real
rem Steam install's own folder layout (pseudoregalia\Binaries\Win64\...) so the whole
rem "pseudoregalia" folder can be dragged straight into the user's Steam install root and
rem merged/overwritten by Windows Explorer -- no manual reaching into subfolders, matching
rem the AP randomizer's own drag-and-drop onboarding exactly (same folder name, same layout).
rem
rem Deliberate exception to the project's normal "never redistribute the modding tool, user
rem installs it themselves" posture (see agent_docs/licensing.md's RE-UE4SS entry) -- RE-UE4SS
rem is MIT-licensed, and this ships its own LICENSE alongside the binaries per MIT's terms.
rem
rem Source of the binaries: MeshGhostPseudo's own CMake build tree (Game__Shipping__Win64),
rem which links against and copies out the exact RE-UE4SS submodule commit this repo pins
rem (adapters\pseudoregalia\MeshGhostPseudo\RE-UE4SS). Source of the stock Mods/settings/
rem LICENSE: that same submodule's assets\ folder -- so everything staged here traces to one
rem single pinned commit, not a separately-downloaded release.
rem
rem Requires: the build tree already configured and built once (see
rem dev-scripts\build-pseudoregalia.bat / agent_docs\phases\phase7.md for the one-time setup).
rem Re-run this whenever the RE-UE4SS submodule pin changes.

setlocal enabledelayedexpansion

set ROOT=%~dp0..
set SUB=%ROOT%\adapters\pseudoregalia\MeshGhostPseudo\RE-UE4SS
set BUILDBIN=%ROOT%\adapters\pseudoregalia\MeshGhostPseudo\build\Game__Shipping__Win64\bin
set GAMEDIR=%ROOT%\packaging\release\games\pseudoregalia
set DEST=%GAMEDIR%\pseudoregalia\Binaries\Win64

if not exist "%BUILDBIN%\UE4SS.dll" (
  echo stage-ue4ss-runtime: %BUILDBIN%\UE4SS.dll not found -- build MeshGhostPseudo first.
  exit /b 1
)

echo Staging UE4SS runtime to %DEST% ...
if not exist "%DEST%\ue4ss" mkdir "%DEST%\ue4ss"

rem No blanket delete-and-recreate here: %DEST%\ue4ss\Mods also holds
rem MeshGhostPseudo, staged separately by build-pseudoregalia.bat. copy/xcopy
rem below overwrite matching files in place and leave anything else (i.e.
rem MeshGhostPseudo, if already staged) untouched -- order-independent
rem between this script and build-pseudoregalia.bat.
rem
rem %DEST%\ue4ss\THIRD-PARTY-NOTICES.txt is HAND-MAINTAINED and deliberately not staged by
rem this script -- it carries the licence notices of the libraries RE-UE4SS statically links
rem into UE4SS.dll (MIT/BSD/zlib all require the notice travel with the binary). It survives
rem because nothing here deletes the folder; if you ever add a delete-and-recreate, preserve
rem it. Update it when the RE-UE4SS pin moves and its dependency set changes.
rem See agent_docs/licensing.md's UE4SS dependency-chain entry.
copy /y "%BUILDBIN%\dwmapi.dll" "%DEST%\dwmapi.dll" >nul
copy /y "%BUILDBIN%\UE4SS.dll" "%DEST%\ue4ss\UE4SS.dll" >nul
copy /y "%SUB%\assets\UE4SS-settings.ini" "%DEST%\ue4ss\UE4SS-settings.ini" >nul
copy /y "%SUB%\LICENSE" "%DEST%\ue4ss\LICENSE" >nul
rem The stock Mods folder is deliberately NOT staged. RE-UE4SS ships a set of Lua mods
rem alongside its runtime -- a cheat manager, a console, console commands, keybind hooks, an
rem actor dumper, a line-trace tool, a profiler, a splitscreen mod -- and MeshGhost needs
rem exactly none of them: MeshGhostPseudo is a C++ mod loaded from its own folder, listed in
rem neither mods.txt nor mods.json.
rem
rem This used to be `xcopy /y /e /i "%SUB%\assets\Mods"`, which shipped all of them ENABLED.
rem A user installing a visual-only ghost overlay was silently also installing a cheat manager
rem and a console into their game -- and, for the Linux tester, into a speedrunners game.
rem Two of those hook keyboard input and one enumerates actors, which made them live suspects
rem when a hard crash was investigated 2026-08-17 (verified.md) and cost real time to rule out.
rem
rem **Ship only what the adapter requires.** Not specific to this game -- see
rem adapters/_template/README.md, which states it for every future adapter.
if not exist "%DEST%\ue4ss\Mods" mkdir "%DEST%\ue4ss\Mods"

rem RE-UE4SS's own stock UE4SS-settings.ini ships with its debug console/overlay enabled by
rem default (ConsoleEnabled/GuiConsoleEnabled/GuiConsoleVisible all = 1) -- fine for a UE4SS
rem developer, bad default UX for a MeshGhost player who just wants the game to launch
rem normally. Force these off in the shipped copy; a user who wants to debug can flip them
rem back on themselves in the ini.
echo Disabling UE4SS debug console/overlay defaults for the shipped copy...
powershell -NoProfile -Command "(Get-Content '%DEST%\ue4ss\UE4SS-settings.ini') -replace '^(ConsoleEnabled\s*=\s*)1', '${1}0' -replace '^(GuiConsoleEnabled\s*=\s*)1', '${1}0' -replace '^(GuiConsoleVisible\s*=\s*)1', '${1}0' | Set-Content '%DEST%\ue4ss\UE4SS-settings.ini'"

echo Recording provenance to ue4ss-runtime-built-from.txt...
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%DEST%\ue4ss\UE4SS.dll" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined UE4SS_HASH set UE4SS_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%DEST%\dwmapi.dll" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined DWMAPI_HASH set DWMAPI_HASH=%%h
for /f %%c in ('git -C "%SUB%" rev-parse HEAD') do set SUBCOMMIT=%%c

(
  echo # Written by dev-scripts\stage-ue4ss-runtime.bat -- read by .github\workflows\release.yml's
  echo # staleness gate. Do not hand-edit. Kept outside the pseudoregalia\ drag-and-drop tree
  echo # on purpose so it never lands in a user's game folder.
  echo # UE4SS.dll and dwmapi.dll are built from the RE-UE4SS submodule pinned below, via
  echo # MeshGhostPseudo's own CMake build tree -- not a separately downloaded release.
  echo re-ue4ss-submodule-commit: %SUBCOMMIT%
  echo UE4SS.dll: %UE4SS_HASH%
  echo dwmapi.dll: %DWMAPI_HASH%
) > "%GAMEDIR%\ue4ss-runtime-built-from.txt"

echo Done. Commit packaging\release\games\pseudoregalia\pseudoregalia\ (the drag-and-drop
echo tree) and ue4ss-runtime-built-from.txt.
