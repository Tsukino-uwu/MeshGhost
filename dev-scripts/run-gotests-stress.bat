@echo off
REM Local concurrency stress, for machines that can't run the race detector (see
REM run-gotests-race.bat for why this project's dev machine can't).
REM
REM This is NOT a substitute for -race and must not be reported as one. It changes three things
REM the normal suite holds fixed, each of which has a real chance of shaking out a timing bug:
REM   -count=10   repeats, because a race that needs an unlucky interleaving needs attempts.
REM               CLAUDE.md already records -count=10 catching what -count=2 missed.
REM   -shuffle=on randomises test order, catching tests that only pass after some other test
REM               happened to leave the world in a particular state.
REM   -cpu=1,4    runs everything at two different GOMAXPROCS values. Single-P scheduling and
REM               parallel scheduling produce genuinely different interleavings, and a bug that
REM               only appears under one of them is invisible if you only test the machine's
REM               default.
REM
REM Scoped to the packages where the concurrency actually lives -- relay rooms, transport read
REM loops, core's tick/relay goroutines, and the two net transports. internal/e2e is deliberately
REM EXCLUDED: it launches the real binaries per test, so multiplying it by counts and cpu values
REM blew straight past go test's own 10-minute binary timeout and reported a "failure" that was
REM only this script asking for something absurd (found immediately, first run). e2e is covered
REM by run-gotests.bat and by CI.
REM
REM Takes a few minutes; that is the point.
setlocal
cd /d "%~dp0\.."

echo === go test -count=10 -shuffle=on -cpu=1,4 (concurrency packages) ===
go test -count=10 -shuffle=on -cpu=1,4 ./internal/relay/... ./internal/core/... ./internal/transport/... ./internal/netx/...
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
