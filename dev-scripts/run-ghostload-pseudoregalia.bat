@echo off
REM Tier 3 load test: N synthetic peers that one running Pseudoregalia client renders as N ghosts, pricing the
REM adapter's per-ghost render cost without N copies of the game.
REM
REM Set two things from a live session first, or nothing appears:
REM   MG_AREA    the real client's current area_id, from the mod's log in UE4SS.log. core matches area_id by
REM              equality, so a wrong value renders nothing and looks like a broken rig.
REM   MG_CENTER  "x,y,z" to orbit, near the player, from the mod's local position trace.
REM Then start run-loadtest-relay.bat, point the real game at 127.0.0.1:7799 room "loadtest", and run this.
REM Ramp the count (1, 2, 4, 8, 16) and read UE's "stat unit" frame time each step; -churn-every adds spawn cost.

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
