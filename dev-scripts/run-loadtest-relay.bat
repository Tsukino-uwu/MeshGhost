@echo off
REM Dev-only relay for the synthetic-peer load test, on its own port so it cannot collide with a session on 7777.
REM -max-clients is raised: the shipped default is 8 across all rooms, and a fakeadapter "server full" is that cap.
REM -config nul ignores the repo's config.json, so this stays a self-contained dev relay.
set MG_MAX_CLIENTS=%1
if "%MG_MAX_CLIENTS%"=="" set MG_MAX_CLIENTS=40
"%~dp0..\meshghost-relay.exe" -addr 127.0.0.1:7799 -max-clients %MG_MAX_CLIENTS% -config nul
pause
