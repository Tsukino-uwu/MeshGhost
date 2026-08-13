@echo off
rem MeshGhost -- stages a UE4SS runtime bundle under
rem packaging\release\games\pseudoregalia\ue4ss-runtime\, so the Pseudoregalia release is a
rem single drag-and-drop copy into the user's Binaries\Win64\ folder -- no separate UE4SS
rem download/install step, matching the AP randomizer's own onboarding.
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
set DEST=%ROOT%\packaging\release\games\pseudoregalia\ue4ss-runtime

if not exist "%BUILDBIN%\UE4SS.dll" (
  echo stage-ue4ss-runtime: %BUILDBIN%\UE4SS.dll not found -- build MeshGhostPseudo first.
  exit /b 1
)

echo Staging UE4SS runtime to %DEST% ...
if exist "%DEST%" rmdir /s /q "%DEST%"
mkdir "%DEST%\ue4ss"

copy /y "%BUILDBIN%\dwmapi.dll" "%DEST%\dwmapi.dll" >nul
copy /y "%BUILDBIN%\UE4SS.dll" "%DEST%\ue4ss\UE4SS.dll" >nul
copy /y "%SUB%\assets\UE4SS-settings.ini" "%DEST%\ue4ss\UE4SS-settings.ini" >nul
copy /y "%SUB%\LICENSE" "%DEST%\ue4ss\LICENSE" >nul
xcopy /y /e /i "%SUB%\assets\Mods" "%DEST%\ue4ss\Mods" >nul

echo Recording provenance to built-from.txt...
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%DEST%\ue4ss\UE4SS.dll" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined UE4SS_HASH set UE4SS_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%DEST%\dwmapi.dll" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined DWMAPI_HASH set DWMAPI_HASH=%%h
for /f %%c in ('git -C "%SUB%" rev-parse HEAD') do set SUBCOMMIT=%%c

(
  echo # Written by dev-scripts\stage-ue4ss-runtime.bat -- read by .github\workflows\release.yml's
  echo # staleness gate. Do not hand-edit.
  echo # UE4SS.dll and dwmapi.dll are built from the RE-UE4SS submodule pinned below, via
  echo # MeshGhostPseudo's own CMake build tree -- not a separately downloaded release.
  echo re-ue4ss-submodule-commit: %SUBCOMMIT%
  echo UE4SS.dll: %UE4SS_HASH%
  echo dwmapi.dll: %DWMAPI_HASH%
) > "%DEST%\built-from.txt"

echo Done. Commit packaging\release\games\pseudoregalia\ue4ss-runtime\ (including built-from.txt).
