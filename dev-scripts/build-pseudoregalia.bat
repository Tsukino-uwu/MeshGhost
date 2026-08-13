@echo off
rem MeshGhost -- builds the Pseudoregalia UE4SS C++ mod (main.dll) and stages it under
rem packaging\release\games\pseudoregalia\MeshGhostPseudo\dlls\, ready to be zipped by
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
set DEST=%ROOT%\packaging\release\games\pseudoregalia\MeshGhostPseudo

echo Building MeshGhostPseudo main.dll (Game__Shipping__Win64)...
cmake --build "%SRC%\build" --config Game__Shipping__Win64 --target MeshGhostPseudo
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
  echo # staleness gate. Do not hand-edit.
  echo commit: %COMMIT%
  echo Plugin.cpp: %PLUGIN_CPP_HASH%
  echo Plugin.hpp: %PLUGIN_HPP_HASH%
  echo BridgeClient.cpp: %BRIDGE_CPP_HASH%
  echo BridgeClient.hpp: %BRIDGE_HPP_HASH%
  echo dllmain.cpp: %DLLMAIN_HASH%
  echo CMakeLists.txt: %CMAKELISTS_HASH%
) > "%DEST%\built-from.txt"

echo Done. Commit packaging\release\games\pseudoregalia\MeshGhostPseudo\dlls\main.dll and built-from.txt.
