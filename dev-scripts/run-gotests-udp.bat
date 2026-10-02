@echo off
REM The dev-only plain-udp transport's tests: netx/udpconn compiles only under the meshghost_devudp tag, CI only vets
REM it, and run-gotests.bat never builds it. Run it after touching what udpconn shares with the other transports.
REM internal/e2e is not covered: it builds release binaries, which have no udp.
cd /d "%~dp0.."

echo === go vet (tagged) ===
go vet -tags meshghost_devudp ./... || goto :failed

set "TESTLOG=%~dp0..\gotests-udp-last.log"
echo === go test -tags meshghost_devudp ===  [full output also written to gotests-udp-last.log]
powershell -NoProfile -ExecutionPolicy Bypass -Command "& go test -tags meshghost_devudp -count=1 ./netx/... ./relay/ ./cmd/... 2>&1 | Tee-Object -FilePath '%TESTLOG%'; exit $LASTEXITCODE" || goto :failed

echo.
echo Optional: a short fuzz run against the udp listener (Ctrl+C ends it early).
echo   go test -tags meshghost_devudp -run='^$' -fuzz='^FuzzListenerSurvivesArbitraryDatagrams$' -fuzztime=60s ./netx/udpconn
echo.
echo All udp checks passed.
goto :end

:failed
echo.
echo FAILED -- see the output above; the complete run is in gotests-udp-last.log.
exit /b 1

:end
