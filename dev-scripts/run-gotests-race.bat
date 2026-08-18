@echo off
REM Runs the race detector locally -- the exact command CI's "Build, vet, test (race)" job runs,
REM which run-gotests.bat CANNOT run and therefore cannot vouch for. CI caught a real relay race
REM on 2026-08-16 that 300 local runs of the same test never reproduced, so "run-gotests.bat is
REM green" has never meant "CI will be green".
REM
REM The race detector needs cgo, and cgo needs a C compiler Go can actually use. On this project's
REM dev machine the gcc on PATH is devkitPro's MSYS2 copy, which fails with "stddef.h: No such
REM file or directory" -- the same wrong-install-on-PATH trap CLAUDE.md warns about.
REM
REM MSYS2's own GCC 15 was ALSO recorded as failing, and that was wrong -- it works, and this
REM script's own probe is what made it look otherwise. Setting CC is not enough: the compiler
REM needs the rest of its toolchain (as, ld, its headers) resolvable, so its bin directory has
REM to go on PATH ahead of the devkitPro copy. The probe below set CC only, so every candidate
REM failed the same way and the conclusion drawn was "no compiler works" rather than "the probe
REM is missing a step" -- two failures with an identical symptom, which CLAUDE.md says to treat
REM as a signal rather than bad luck. Fixed and verified working 2026-08-18; see
REM agent_docs/testing.md's Race detector section.
setlocal
cd /d "%~dp0\.."

set "RACE_CC="
for %%C in (gcc.exe) do if not "%%~$PATH:C"=="" call :try "%%~$PATH:C"
call :try "C:\msys64\ucrt64\bin\gcc.exe"
call :try "C:\msys64\mingw64\bin\gcc.exe"
call :try "C:\mingw64\bin\gcc.exe"
call :try "C:\TDM-GCC-64\bin\gcc.exe"

if not defined RACE_CC (
    echo.
    echo NO WORKING C COMPILER FOUND -- the race detector cannot run on this machine.
    echo.
    echo This is a real gap, not a passing result: CI still runs -race on every push and
    echo has caught bugs no local run reproduced. Treat a green run-gotests.bat as
    echo "probably fine", never as "CI will pass".
    echo.
    echo To close it, install an MSYS2 mingw64 GCC ^(the mingw64 bin directory^), or any
    echo mingw-w64 GCC, or install a WSL distro with go and gcc.
    echo.
    exit /b 1
)

echo Using CC=%RACE_CC%
set "CC=%RACE_CC%"
set "CGO_ENABLED=1"
echo === go test -race -count=3 (same as CI) ===
go test -race -count=3 ./...
if errorlevel 1 (
    echo.
    echo RACE/TEST FAILURE -- this is what CI would have reported.
    exit /b 1
)
echo.
echo Race detector clean.
exit /b 0

:try
if defined RACE_CC exit /b 0
if not exist "%~1" exit /b 0
REM Probe by actually building something that needs cgo. A compiler that exists is not the
REM same as a compiler Go can use, which is the entire lesson of the two failures above.
REM
REM PATH first, then CC: cgo shells out to the compiler, which shells out to its own as/ld and
REM reads its own headers. Without its bin directory ahead of devkitPro's on PATH, a perfectly
REM good compiler fails exactly like a broken one.
set "PATH=%~dp1;%PATH%"
set "CC=%~1"
set "CGO_ENABLED=1"
go build -race -o "%TEMP%\meshghost-race-probe.exe" ./cmd/meshghost >nul 2>&1
if not errorlevel 1 set "RACE_CC=%~1"
del "%TEMP%\meshghost-race-probe.exe" >nul 2>&1
exit /b 0
