@echo off
rem Stages the RE-UE4SS runtime under packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64\ in the
rem game install's own layout, so the "pseudoregalia" folder drags straight into the install root.
rem RE-UE4SS is MIT-licensed and ships here with its LICENSE, an exception to players installing the modding tool.
rem Everything traces to the pinned RE-UE4SS submodule: the DLLs through the CMake build tree, the settings and
rem LICENSE from the submodule itself. Needs the build tree built once; re-run whenever the submodule pin changes.

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

rem No delete-and-recreate: ue4ss\Mods also holds MeshGhostPseudo from build-pseudoregalia.bat, and copy overwrites
rem in place, so the two scripts run in either order.
rem ue4ss\THIRD-PARTY-NOTICES.txt is hand-maintained (notices for what RE-UE4SS statically links into UE4SS.dll)
rem and survives only because nothing here deletes the folder; update it when the pin changes the dependency set.
copy /y "%BUILDBIN%\dwmapi.dll" "%DEST%\dwmapi.dll" >nul
copy /y "%BUILDBIN%\UE4SS.dll" "%DEST%\ue4ss\UE4SS.dll" >nul
copy /y "%SUB%\assets\UE4SS-settings.ini" "%DEST%\ue4ss\UE4SS-settings.ini" >nul
copy /y "%SUB%\LICENSE" "%DEST%\ue4ss\LICENSE" >nul
rem RE-UE4SS's stock Lua mods (a cheat manager, a console, keybind hooks, an actor dumper and more) are not staged:
rem MeshGhostPseudo is a C++ mod loaded from its own folder and needs none of them.
if not exist "%DEST%\ue4ss\Mods" mkdir "%DEST%\ue4ss\Mods"

rem The stock settings enable UE4SS's debug console and overlay; the shipped copy turns them off.
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
