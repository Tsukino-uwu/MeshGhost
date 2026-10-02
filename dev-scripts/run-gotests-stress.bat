@echo off
REM Concurrency stress, not a substitute for -race: repeats, shuffled order and two GOMAXPROCS values each change
REM which interleavings run. internal/e2e is left out: it launches real binaries per test, and at these counts it
REM passes go test's 10-minute timeout.
setlocal
cd /d "%~dp0\.."

echo === go test -count=10 -shuffle=on -cpu=1,4 (concurrency packages) ===
go test -count=10 -shuffle=on -cpu=1,4 ./relay/... ./core/... ./transport/... ./netx/...
if errorlevel 1 (
    echo.
    echo STRESS FAILURE -- a real one. Do not re-run hoping it passes; a test that fails
    echo intermittently under stress fails intermittently for users too.
    echo Note the seed printed above so the order can be reproduced with -shuffle=SEED.
    exit /b 1
)

echo.
echo Stress clean. This does NOT mean the race detector would be clean -- CI still runs it.
exit /b 0
