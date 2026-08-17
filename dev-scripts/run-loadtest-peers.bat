@echo off
REM Ceilings 1-2 load test: N synthetic peers against run-loadtest-relay.bat, no game involved.
REM (Ceilings numbered as in dev-scripts/README.md: 1 relay fan-out, 2 per-client receive,
REM 3 adapter render cost.)
REM Measures the RELAY's own fan-out cost, which grows with the square of room size
REM (relay/limits.go's DefaultMaxClients). Watch the relay process's CPU and the
REM stats line here; the "client0_remotes" number is the rig's self-check and should read
REM one less than the client count -- anything lower means states are being dropped rather
REM than the test being genuinely light.
REM
REM Usage: run-loadtest-peers.bat [count]   (default 16)
set MG_CLIENTS=%1
if "%MG_CLIENTS%"=="" set MG_CLIENTS=16
"%~dp0..\meshghost-fakeadapter.exe" -relay 127.0.0.1:7799 -room loadtest -clients %MG_CLIENTS% ^
  -stats-every 5s -log-every 60s
pause
