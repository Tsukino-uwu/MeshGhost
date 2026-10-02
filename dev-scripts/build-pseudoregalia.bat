@echo off
rem Builds main.dll and the UE4SS runtime, and stages main.dll in the game install's own folder layout, so the
rem "pseudoregalia" folder under packaging\release\games\pseudoregalia\ is one drag-and-drop.
rem CI cannot build it (the UEPseudo dependency is access-gated), so the output is committed, and the CMake
rem tree under adapters\pseudoregalia\MeshGhostPseudo\build\ must already be configured once.
rem Re-run and commit whenever a source hashed below changes: release.yml refuses sources that no longer match.

setlocal enabledelayedexpansion

set ROOT=%~dp0..
set SRC=%ROOT%\adapters\pseudoregalia\MeshGhostPseudo
set GAMEDIR=%ROOT%\packaging\release\games\pseudoregalia
set DEST=%GAMEDIR%\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo

rem A bare cmake can resolve to another install on PATH than the one the build tree was configured with.
set CMAKE_EXE=cmake
if exist "C:\Program Files\CMake\bin\cmake.exe" set CMAKE_EXE=C:\Program Files\CMake\bin\cmake.exe

rem The Rust part of UE4SS.dll keeps source paths in its panic messages: map the clone and the cargo
rem home to fixed names. RUSTFLAGS splits on spaces, so a path holding one cannot be mapped this way.
for %%I in ("%ROOT%") do set ROOT_ABS=%%~fI
set CARGO_DIR=%CARGO_HOME%
if not defined CARGO_DIR set CARGO_DIR=%USERPROFILE%\.cargo
if not "%ROOT_ABS: =%"=="%ROOT_ABS%" (
  echo build-pseudoregalia: the clone path holds a space, which RUSTFLAGS cannot carry; nothing built.
  exit /b 1
)
if not "%CARGO_DIR: =%"=="%CARGO_DIR%" (
  echo build-pseudoregalia: the cargo home path holds a space, which RUSTFLAGS cannot carry; nothing built.
  exit /b 1
)
set RUSTFLAGS=--remap-path-prefix=%ROOT_ABS%=/_ --remap-path-prefix=%CARGO_DIR%=/cargo

echo Building MeshGhostPseudo main.dll and the UE4SS runtime (Game__Shipping__Win64)...
"%CMAKE_EXE%" --build "%SRC%\build" --config Game__Shipping__Win64 --target MeshGhostPseudo proxy
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
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\PeerJson.hpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined PEERJSON_HPP_HASH set PEERJSON_HPP_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\BridgeClient.cpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined BRIDGE_CPP_HASH set BRIDGE_CPP_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\BridgeClient.hpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined BRIDGE_HPP_HASH set BRIDGE_HPP_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\dllmain.cpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined DLLMAIN_HASH set DLLMAIN_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\CoreLauncher.cpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined LAUNCHER_CPP_HASH set LAUNCHER_CPP_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\src\CoreLauncher.hpp" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined LAUNCHER_HPP_HASH set LAUNCHER_HPP_HASH=%%h
for /f "usebackq tokens=1" %%h in (`certutil -hashfile "%SRC%\Mod\CMakeLists.txt" SHA256 ^| findstr /v "hash CertUtil"`) do if not defined CMAKELISTS_HASH set CMAKELISTS_HASH=%%h
for /f %%c in ('git -C "%ROOT%" rev-parse HEAD') do set COMMIT=%%c

(
  echo # Written by dev-scripts\build-pseudoregalia.bat -- read by .github\workflows\release.yml's
  echo # staleness gate. Do not hand-edit. Kept outside the pseudoregalia\ drag-and-drop tree
  echo # on purpose so it never lands in a user's game folder.
  echo commit: %COMMIT%
  echo Plugin.cpp: %PLUGIN_CPP_HASH%
  echo Plugin.hpp: %PLUGIN_HPP_HASH%
  echo PeerJson.hpp: %PEERJSON_HPP_HASH%
  echo BridgeClient.cpp: %BRIDGE_CPP_HASH%
  echo BridgeClient.hpp: %BRIDGE_HPP_HASH%
  echo dllmain.cpp: %DLLMAIN_HASH%
  echo CoreLauncher.cpp: %LAUNCHER_CPP_HASH%
  echo CoreLauncher.hpp: %LAUNCHER_HPP_HASH%
  echo CMakeLists.txt: %CMAKELISTS_HASH%
) > "%GAMEDIR%\MeshGhostPseudo-built-from.txt"

echo Done. Commit packaging\release\games\pseudoregalia\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostPseudo\dlls\main.dll
echo and MeshGhostPseudo-built-from.txt.
