@echo off
rem MeshGhost -- builds the TEVI BepInEx plugin (MeshGhostTevi.dll) and stages it under
rem packaging\release\games\tevi\MeshGhost\, ready to be zipped by .github\workflows\release.yml.
rem Staged under a MeshGhost\ subfolder (not flat in games\tevi\) so the whole MeshGhost\
rem folder is a single drag-and-drop into the user's BepInEx\plugins\ -- same shape as
rem Pseudoregalia's drag-and-drop tree (build-pseudoregalia.bat), just one file.
rem
rem CI cannot do this build itself: MeshGhostTevi.csproj compiles against
rem adapters\tevi\MeshGhostTevi\lib\*.dll, copies out of the developer's own TEVI install --
rem proprietary, gitignored, never committed (agent_docs/licensing.md). Our own output
rem (MeshGhostTevi.dll) is fine to distribute -- it just has to be built locally and
rem committed. Requires: .NET SDK, and lib\Assembly-CSharp.dll / lib\Newtonsoft.Json.dll
rem already copied in from your TEVI install (see adapters\tevi\README.md).
rem
rem Run this whenever Plugin.cs, BridgeClient.cs, or the .csproj change, then commit the
rem result -- release.yml refuses to cut a release if the committed DLL is older than those
rem sources (staleness gate, compares against built-from.txt below).

setlocal enabledelayedexpansion

set ROOT=%~dp0..
set SRC=%ROOT%\adapters\tevi\MeshGhostTevi
set GAMEDIR=%ROOT%\packaging\release\games\tevi
set DEST=%GAMEDIR%\MeshGhost

echo Building MeshGhostTevi.dll (Release)...
dotnet build "%SRC%" -c Release
if errorlevel 1 (
  echo build-tevi: dotnet build failed, nothing staged.
  exit /b 1
)

if not exist "%DEST%" mkdir "%DEST%"
copy /y "%SRC%\bin\Release\MeshGhostTevi.dll" "%DEST%\MeshGhostTevi.dll" >nul

echo Recording source hashes to built-from.txt...
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Plugin.cs" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined PLUGIN_HASH set PLUGIN_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\BridgeClient.cs" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined BRIDGE_HASH set BRIDGE_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\MeshGhostTevi.csproj" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined CSPROJ_HASH set CSPROJ_HASH=%%h
for /f %%c in ('git -C "%ROOT%" rev-parse HEAD') do set COMMIT=%%c

(
  echo # Written by dev-scripts\build-tevi.bat -- read by .github\workflows\release.yml's
  echo # staleness gate. Do not hand-edit. Kept outside the MeshGhost\ drag-and-drop tree on
  echo # purpose so it never lands in a user's BepInEx\plugins\ folder.
  echo commit: %COMMIT%
  echo Plugin.cs: %PLUGIN_HASH%
  echo BridgeClient.cs: %BRIDGE_HASH%
  echo MeshGhostTevi.csproj: %CSPROJ_HASH%
) > "%GAMEDIR%\built-from.txt"

echo Done. Commit packaging\release\games\tevi\MeshGhost\MeshGhostTevi.dll and built-from.txt.
