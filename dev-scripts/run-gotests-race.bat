@echo off
REM Runs the race detector locally -- the exact command CI's "Build, vet, test (race)" job runs,
REM which run-gotests.bat CANNOT run and therefore cannot vouch for. CI caught a real relay race
REM on 2026-08-16 that 300 local runs of the same test never reproduced, so "run-gotests.bat is
REM green" has never meant "CI will be green".
REM
REM The race detector needs cgo, and cgo needs a C compiler Go can actually use. On this project's
REM dev machine the gcc on PATH is devkitPro's MSYS2 copy, which fails with "stddef.h: No such
REM file or directory" -- the same wrong-install-on-PATH trap CLAUDE.md warns about. MSYS2's own
REM GCC 15 fails too (Go's runtime/cgo doesn't build with it; see dev-scripts/README.md).
REM
REM So this script PROBES for a compiler that works instead of assuming one, and if none does it
REM says so plainly rather than looking like a test failure. Known-good options, either of which
REM makes this script start working with no edit:
REM   - a mingw-w64 GCC in the 12-14 range on PATH (Go's runtime/cgo builds with those)
REM   - a WSL distro with go+gcc, then run the same command inside it
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
    echo To close it, install a mingw-w64 GCC in the 12-14 range and put it on PATH ahead
    echo of any devkitPro copy, or install a WSL distro with go and gcc.
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
set "CC=%~1"
set "CGO_ENABLED=1"
go build -race -o "%TEMP%\meshghost-race-probe.exe" ./cmd/meshghost >nul 2>&1
if not errorlevel 1 set "RACE_CC=%~1"
del "%TEMP%\meshghost-race-probe.exe" >nul 2>&1
exit /b 0
