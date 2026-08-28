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
REM Second argument spreads the peers over N areas, which is the only room SHAPE where the
REM relay's cross-area filter (ADR 0041) can save anything -- a single-area room is its worst
REM case by construction. Default 1 = every peer in one area, exactly the old behaviour, so a
REM number recorded before -areas existed is still comparable. Run the relay with -introspect
REM to read the filtered share. Measured 2026-08-28: 16 peers over 8 areas suppresses 93% of
REM offered state bytes; the same 16 over 1 area suppresses 0%.
REM
REM Usage: run-loadtest-peers.bat [count] [areas]   (defaults 16, 1)
set MG_CLIENTS=%1
if "%MG_CLIENTS%"=="" set MG_CLIENTS=16
set MG_AREAS=%2
if "%MG_AREAS%"=="" set MG_AREAS=1
"%~dp0..\meshghost-fakeadapter.exe" -relay 127.0.0.1:7799 -room loadtest -clients %MG_CLIENTS% ^
  -areas %MG_AREAS% -stats-every 5s -log-every 60s
pause
