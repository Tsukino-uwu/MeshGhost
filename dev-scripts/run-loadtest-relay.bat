@echo off
REM Dev-only relay for the synthetic-peer load test (see dev-scripts/README.md).
REM Raised -max-clients because the shipped default is 8 TOTAL across all rooms, so a
REM load test of any interesting size is refused before it starts -- the fakeadapter
REM reports "client N of M: ... server full" when that happens, which is this, not a bug.
REM Runs on its own port so it can't collide with a real session on the default 7777.
REM -config nul: ignore the repo's config.json so this stays a self-contained dev relay.
set MG_MAX_CLIENTS=%1
if "%MG_MAX_CLIENTS%"=="" set MG_MAX_CLIENTS=40
"%~dp0..\meshghost-relay.exe" -addr 127.0.0.1:7799 -max-clients %MG_MAX_CLIENTS% -config nul
pause
