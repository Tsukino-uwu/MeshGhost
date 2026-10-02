@echo off
REM Tier 1-2 load test: N synthetic peers against run-loadtest-relay.bat, no game, measuring the relay's fan-out,
REM which grows with the square of room size. With one area, client0_remotes should read one less than the client
REM count; lower means states are being dropped.
REM The second argument spreads the peers over N areas, the only room shape the relay's cross-area filter can save
REM anything on; run the relay with -introspect to read the filtered share.
REM Usage: run-loadtest-peers.bat [count] [areas]   (defaults 16, 1)
set MG_CLIENTS=%1
if "%MG_CLIENTS%"=="" set MG_CLIENTS=16
set MG_AREAS=%2
if "%MG_AREAS%"=="" set MG_AREAS=1
"%~dp0..\meshghost-fakeadapter.exe" -relay 127.0.0.1:7799 -room loadtest -clients %MG_CLIENTS% ^
  -areas %MG_AREAS% -stats-every 5s -log-every 60s
pause
