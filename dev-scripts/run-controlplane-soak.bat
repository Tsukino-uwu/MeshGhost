@echo off
REM Soak the planes past cosmetic -- events, leases, escrow, world custody -- with 6 synthetic peers
REM contending against each other for 60 seconds, while every peer continuously checks the
REM invariants those planes exist to provide. Starts its own relay, so this is the whole
REM rig in one double-click: nothing else needs to be running.
REM
REM WHAT IT CHECKS (cmd/meshghost-fakeadapter/controlplane.go):
REM   1. Ordering    -- every control message a peer receives has a strictly larger sequencer
REM                     stamp than the last. Seeing 3 after 5 means the relay's stamp order
REM                     and its delivery order have come apart.
REM   2. Exclusivity -- a key is granted to a second holder only after the first released it.
REM                     Every peer goes for the SAME key on purpose; contention is what makes
REM                     this check mean anything, and a run showing 0 denials tested nothing.
REM   3. Termination -- every exchange reaches committed or aborted, and an abort never
REM                     delivers a deposit. A trade that just stops is the hostage case.
REM   4-8. Custody   -- (cmd/meshghost-fakeadapter/world.go) the world never goes backwards,
REM                     a stale host's write is never accepted, nothing is lost across a
REM                     handover, a dropped entity is never resurrected, and the adoption
REM                     snapshot follows the grant with nothing in between. -migrate-every
REM                     forces a real handover into contention every 3s; a run reporting
REM                     0 worlds adopted tested custody without testing migration.
REM
REM Exits non-zero if any invariant failed, so this can go in a script or a soak job. The
REM summary line at the end is worth reading even on a pass: a run with 0 claims denied or
REM 0 exchanges committed is a green result that exercised nothing.
REM
REM HONEST LIMIT, measured 2026-08-17 rather than assumed: this did NOT catch a deliberately
REM broken relay (the per-room send lock removed) in 51,000 events, while
REM relay/online_test.go's total-order test caught the same defect on its first run.
REM A ticker-driven rig produces far less contention per second than a tight burst of
REM goroutines. **This complements the unit tests; it does not replace them.** Its real value
REM is duration and the transports/faults a unit test cannot reach -- point it at
REM run-netsim.bat's proxy address to soak under loss and jitter.
REM
REM -event-every 300ms with 6 peers is ~120 relay messages/sec of control traffic on top of
REM the 20Hz state plane. Do not lower it much: the relay's per-client flood cap is
REM max(120, send_hz*6) messages/sec and it CLOSES a connection that exceeds it, which reads
REM as a mysterious disconnect rather than as "you asked for too much." The world plane spends
REM the same budget: -host-entities 5 at -entity-hz 12 is 60 writes/sec from whichever peer
REM holds the authority, on top of that peer's 20Hz state and its events. Raise either number
REM and check the arithmetic against 120 before assuming a disconnect is a bug.
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
REM Then close it here rather than asking the reader to. A soak relay left running holds
REM 127.0.0.1:7911, and a later run silently binding a different port -- or this one failing to
REM bind and looking like a relay bug -- is exactly the trap CLAUDE.md records: close every
REM process you started, and verify it is gone.
taskkill /FI "WINDOWTITLE eq soak relay" /T /F >nul 2>&1
tasklist /FI "WINDOWTITLE eq soak relay" 2>nul | find /I "meshghost-relay.exe" >nul
if not errorlevel 1 (
  echo WARNING: a "soak relay" process is STILL running -- close it by hand before the next run,
  echo or it will hold 127.0.0.1:7911.
)
exit /b %SOAK_RC%
