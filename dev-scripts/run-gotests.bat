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
REM
REM **THE WHOLE OUTPUT GOES TO A FILE, not just the console (2026-09-11, review O3).** A core test
REM failed once on 2026-09-08 and was never identified, because the only thing captured was the
REM TAIL -- which held teardown log noise from two cores and a relay shutting down, and not the
REM test NAME. Without the name there is nothing to bisect, and the run could not be re-captured
REM because the output was gone. That is a bad way to lose a flake: this repo's own history says
REM the one seen once and waved through is the one CI finds later on a slower machine.
REM
REM This is insurance for EVERY future flake rather than for that one: whatever fails, and however
REM the script was invoked, the complete output is on disk afterwards. Tee-Object rather than a
REM plain redirect so the console still streams live -- a run takes minutes and watching it is
REM half the point. $LASTEXITCODE after the pipeline is `go`'s own, because Tee-Object is a cmdlet
REM and does not touch it.
set "TESTLOG=%~dp0..\gotests-last.log"
echo === go test (x2) ===  [full output also written to gotests-last.log]
powershell -NoProfile -ExecutionPolicy Bypass -Command "& go test -count=2 ./... 2>&1 | Tee-Object -FilePath '%TESTLOG%'; exit $LASTEXITCODE" || goto :failed

echo.
echo All Go checks passed.
goto :end

:failed
echo.
echo FAILED -- see the output above.
echo The COMPLETE run is in gotests-last.log (the console may have scrolled, and a
echo tail is what lost the 2026-09-08 flake). Search it for "--- FAIL" to get the
echo test NAME, which is the one thing a bisect needs.
exit /b 1

:end
pause
