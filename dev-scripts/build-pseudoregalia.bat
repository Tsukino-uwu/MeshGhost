@echo off
rem MeshGhost -- builds the Pseudoregalia UE4SS C++ mod (main.dll) and stages it under
rem packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo\,
rem mirroring the real Steam install's own folder layout (see stage-ue4ss-runtime.bat's
rem comment) so the whole "pseudoregalia" folder is one drag-and-drop, ready to be zipped by
rem .github\workflows\release.yml.
rem
rem CI cannot do this build itself: it needs a locally configured CMake build tree against
rem RE-UE4SS (git submodule, pinned to this machine's installed UE4SS SHA) plus the private
rem UEPseudo dependency, which isn't publicly cloneable (see agent_docs/phases/phase7.md's
rem 7.2 entry). Our own output (main.dll) is fine to distribute -- it just has to be built
rem locally and committed. Requires: the build tree already configured once under
rem adapters\pseudoregalia\MeshGhostPseudo\build\ (CMake 4.x, VS 2022 Build Tools, C++
rem workload -- see phase7.md for the one-time setup).
rem
rem Run this whenever Plugin.cpp/hpp, BridgeClient.cpp/hpp, dllmain.cpp, or CMakeLists.txt
rem change, then commit the result -- release.yml refuses to cut a release if the committed
rem DLL is older than those sources (staleness gate, compares against built-from.txt below).

setlocal enabledelayedexpansion

set ROOT=%~dp0..
set SRC=%ROOT%\adapters\pseudoregalia\MeshGhostPseudo
set GAMEDIR=%ROOT%\packaging\release\games\pseudoregalia
set DEST=%GAMEDIR%\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo

rem CLAUDE.md: "A build tool on PATH may silently resolve to the wrong install." Confirmed
rem live 2026-08-15: a bare `cmake` on this project's dev machine resolves first to msys2's
rem older bundled copy (C:\devkitPro\msys2\usr\bin\cmake.exe, 4.0.2), not the real install
rem the build tree was actually configured with (C:\Program Files\CMake\bin\cmake.exe,
rem 4.4.2) -- silently using the wrong one can produce a build that looks successful but
rem doesn't match the configured tree. Prefer the real install explicitly if it's present;
rem fall back to whatever's on PATH otherwise (e.g. a machine where CMake was installed
rem somewhere else).
set CMAKE_EXE=cmake
if exist "C:\Program Files\CMake\bin\cmake.exe" set CMAKE_EXE=C:\Program Files\CMake\bin\cmake.exe

echo Building MeshGhostPseudo main.dll (Game__Shipping__Win64)...
"%CMAKE_EXE%" --build "%SRC%\build" --config Game__Shipping__Win64 --target MeshGhostPseudo
if errorlevel 1 (
  echo build-pseudoregalia: cmake build failed, nothing staged.
  exit /b 1
)

if not exist "%DEST%\dlls" mkdir "%DEST%\dlls"
copy /y "%SRC%\build\Mod\Game__Shipping__Win64\main.dll" "%DEST%\dlls\main.dll" >nul
if not exist "%DEST%\enabled.txt" type nul > "%DEST%\enabled.txt"

echo Recording source hashes to built-from.txt...
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\Plugin.cpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined PLUGIN_CPP_HASH set PLUGIN_CPP_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\Plugin.hpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined PLUGIN_HPP_HASH set PLUGIN_HPP_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\BridgeClient.cpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined BRIDGE_CPP_HASH set BRIDGE_CPP_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\BridgeClient.hpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined BRIDGE_HPP_HASH set BRIDGE_HPP_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\dllmain.cpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined DLLMAIN_HASH set DLLMAIN_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\CMakeLists.txt" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined CMAKELISTS_HASH set CMAKELISTS_HASH=%%h
for /f %%c in ('git -C "%ROOT%" rev-parse HEAD') do set COMMIT=%%c

(
  echo # Written by dev-scripts\build-pseudoregalia.bat -- read by .github\workflows\release.yml's
  echo # staleness gate. Do not hand-edit. Kept outside the pseudoregalia\ drag-and-drop tree
  echo # on purpose so it never lands in a user's game folder.
  echo commit: %COMMIT%
  echo Plugin.cpp: %PLUGIN_CPP_HASH%
  echo Plugin.hpp: %PLUGIN_HPP_HASH%
  echo BridgeClient.cpp: %BRIDGE_CPP_HASH%
  echo BridgeClient.hpp: %BRIDGE_HPP_HASH%
  echo dllmain.cpp: %DLLMAIN_HASH%
  echo CMakeLists.txt: %CMAKELISTS_HASH%
) > "%GAMEDIR%\MeshGhostPseudo-built-from.txt"

echo Done. Commit packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo\dlls\main.dll
echo and MeshGhostPseudo-built-from.txt.
