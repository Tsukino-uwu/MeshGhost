@echo off
REM The race detector, the exact command CI's race job runs, which run-gotests.bat does not.
REM cgo needs a C compiler Go can use, and the gcc first on PATH may be devkitPro's MSYS2 copy, whose headers fail.
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
REM Probe with a real cgo build: a compiler that exists is not one Go can use.
REM PATH before CC: the compiler runs its own as/ld and reads its own headers, so its bin directory must come first.
set "PATH=%~dp1;%PATH%"
set "CC=%~1"
set "CGO_ENABLED=1"
go build -race -o "%TEMP%\meshghost-race-probe.exe" ./cmd/meshghost >nul 2>&1
if not errorlevel 1 set "RACE_CC=%~1"
del "%TEMP%\meshghost-race-probe.exe" >nul 2>&1
exit /b 0
