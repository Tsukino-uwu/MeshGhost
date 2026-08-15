@echo off
REM Tier 2 load test: N synthetic peers that a REAL running Pseudoregalia client will render
REM as N ghosts. This is the one that measures the ceiling that actually binds -- the
REM adapter's per-ghost render cost -- without needing N copies of the game.
REM
REM YOU MUST SET TWO THINGS FIRST, from a live session, or nothing will appear on screen:
REM
REM   MG_AREA  -- the area_id the real client is currently in. internal/core filters remote
REM               states by area_id EQUALITY, so a wrong value renders nothing and looks
REM               exactly like a broken rig. Read it from the mod's own log line in
REM               UE4SS.log (Pseudoregalia's area_id is the level's full name).
REM   MG_CENTER -- "x,y,z" world coordinates to orbit, near where the player is standing.
REM               Also from the mod's log (its local position trace).
REM
REM Then: start the relay (run-loadtest-relay.bat), start the real game with its normal
REM launcher but pointed at 127.0.0.1:7799 and room "loadtest", and run this.
REM
REM Ramp the count (1, 2, 4, 8, 16) and read a real frame-time number off the game each time
REM -- UE's "stat unit" console overlay. "No errors in the log" is not a measurement.
REM Add -churn-every 6s to also exercise ghost spawn/despawn (a full pawn-clone construction
REM each time), which may well cost more than steady-state rendering.

if "%MG_AREA%"=="" (
  echo ERROR: set MG_AREA to the real client's current area_id first. See the comments in this file.
  pause
  exit /b 1
)
if "%MG_CENTER%"=="" (
  echo ERROR: set MG_CENTER to "x,y,z" near the player first. See the comments in this file.
  pause
  exit /b 1
)

set MG_CLIENTS=%1
if "%MG_CLIENTS%"=="" set MG_CLIENTS=4

"%~dp0..\meshghost-fakeadapter.exe" -relay 127.0.0.1:7799 -room loadtest ^
  -game-id pseudoregalia -clients %MG_CLIENTS% ^
  -area-id "%MG_AREA%" -center "%MG_CENTER%" -dims 3 ^
  -radius 250 -period 8 -anim idle -yaw-follows-path ^
  -extras "@%~dp0loadtest-extras-pseudoregalia.json" ^
  -stats-every 5s -log-every 60s
pause
