@echo off
REM The Go client/server gate in one command: build, vet, then the whole suite twice. Needs no game and no watcher.
REM Not run here: -race (run-gotests-race.bat) and fuzzing (CI); the fuzz seed corpora run as ordinary tests.
cd /d "%~dp0.."

echo === go build ===
go build ./... || goto :failed

echo === go vet ===
go vet ./... || goto :failed

REM -count=2: parts of this suite have failed intermittently, so one green run is not enough.
REM The whole output goes to gotests-last.log so a flake's test name survives a scrolled console; Tee-Object keeps
REM the console live, and $LASTEXITCODE after the pipeline is still go's.
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
