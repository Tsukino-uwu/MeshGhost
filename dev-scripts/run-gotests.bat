@echo off
REM The whole Go client/server gate in one command -- the checks CLAUDE.md requires before a
REM change to the Go client/server is called done. Run this instead of remembering four commands.
REM
REM Nothing here needs a game, an emulator, or a human watching: internal/e2e builds and
REM launches the real meshghost-server.exe and meshghost.exe and drives a real adapter over the
REM bridge, which is what run-relay-loopback.bat + run-core-*.bat used to check by hand.
REM
REM NOT run here: the race detector. On Windows -race needs a working cgo C toolchain, and a
REM machine can easily have a `gcc` on PATH that is the wrong install (found live 2026-08-16:
REM this box's resolved to a devkitPro MSYS2 copy whose headers -race can't use). CI runs
REM -race -count=3 on Linux on every push instead -- see .github/workflows/ci.yml. Fuzzing is
REM likewise CI's job on a per-push basis; the seed corpora still run below as ordinary tests.
cd /d "%~dp0.."

echo === go build ===
go build ./... || goto :failed

echo === go vet ===
go vet ./... || goto :failed

REM -count=2 because parts of this suite have failed intermittently rather than reliably --
REM a single green run has been misleading here before (see CLAUDE.md).
echo === go test (x2) ===
go test -count=2 ./... || goto :failed

echo.
echo All Go checks passed.
goto :end

:failed
echo.
echo FAILED -- see the output above.
exit /b 1

:end
pause
