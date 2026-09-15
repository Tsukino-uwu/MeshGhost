@echo off
REM The dormant plain-udp transport's own tests, run by hand -- the one place they run at all.
REM
REM Since 2026-09-15 (ADR 0065) netx/udpconn compiles only under the meshghost_devudp build tag:
REM no release serves or dials udp, run-gotests.bat never compiles it, and CI only vets it
REM (the "Vet the dev-only udp build" step) so a refactor cannot rot it silently. It is kept as a
REM comparison tool against quic -- the same datagram-shaped path without QUIC's congestion
REM control -- so before a quic comparison, or after touching anything netx/udpconn shares with
REM the other transports, this is the script to run.
REM
REM What it covers, under the tag: netx/udpconn itself, netx's conformance suite with udp in
REM transportsUnderTest, relay's mixed-transport room test in its three-way form, and cmd/. What it
REM does NOT cover: internal/e2e, which builds the release binaries from source and therefore
REM never has udp -- a udp round trip through real binaries would need a tagged build, and nobody
REM ships one. Same output discipline as run-gotests.bat: the whole run lands in a file.
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
