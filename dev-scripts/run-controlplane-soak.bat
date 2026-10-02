@echo off
REM Soaks the planes past cosmetic (events, leases, escrow, world custody): its own relay plus 6 synthetic peers for
REM 60s, each checking the invariants in cmd/meshghost-fakeadapter/controlplane.go and world.go. Exits non-zero on a
REM violation; a pass with 0 claims denied, 0 exchanges committed or 0 worlds adopted exercised nothing.
REM It complements relay's ordering tests rather than replacing them: a ticker-driven rig contends far less.
REM The relay closes a client sending past max(120, send_hz*6) messages a second, which reads as a disconnect: the
REM authority peer's 5 entities at 12Hz are 60 writes a second on top of its state and events, so check the sum
REM before raising a rate.
start "soak relay" ..\meshghost-relay.exe -addr=127.0.0.1:7911 -transport=tcp -introspect=10s
timeout /t 2 /nobreak >nul
..\meshghost-fakeadapter.exe -relay=127.0.0.1:7911 -room=soak -game-id=faketest -clients=6 ^
  -features=event.v1,lease.v1,escrow.v1,world.v1 ^
  -event-every=300ms -lease-every=700ms -trade-every=1s ^
  -host-entities=5 -entity-hz=12 -migrate-every=3s ^
  -log-every=60s -duration=60s
set SOAK_RC=%ERRORLEVEL%
echo.
echo Soak finished with exit code %SOAK_RC% (0 = no invariant violations).
echo.
echo Read the "soak relay" window BEFORE it closes below -- its -introspect lines show what
echo the relay thought was true every 10s, which is the other half of a failed run.
pause
REM A soak relay left running holds 127.0.0.1:7911, and the next run's relay then fails to bind, like a relay bug.
taskkill /FI "WINDOWTITLE eq soak relay" /T /F >nul 2>&1
tasklist /FI "WINDOWTITLE eq soak relay" 2>nul | find /I "meshghost-relay.exe" >nul
if not errorlevel 1 (
  echo WARNING: a "soak relay" process is STILL running -- close it by hand before the next run,
  echo or it will hold 127.0.0.1:7911.
)
exit /b %SOAK_RC%
