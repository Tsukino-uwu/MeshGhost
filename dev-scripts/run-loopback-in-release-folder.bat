@echo off
REM Loopback for a downloaded RELEASE folder. Copy this one file into the unzipped release
REM (next to meshghost.exe / meshghost-server.exe / config.json) and run it INSTEAD of
REM meshghost-server.exe -- it echoes your own state back to you as a "<id>-ghost", so you can
REM see a ghost of yourself with no second player and no second PC. Nothing else in the release
REM folder needs changing, and nothing loopback-related is shipped in the release itself.
REM
REM Same idea as run-relay-loopback.bat next to this file, with two deliberate differences:
REM   - the release renames the relay to meshghost-server.exe, and it sits in the SAME folder
REM     as this script rather than one level up at the repo root
REM   - no -send-hz=100 override. That exists only to stop a dev relay silently overriding the
REM     run-core-*.bat scripts' own fast -min-send (see run-relay.bat's comment); a release
REM     folder has neither, so whatever send_hz is in its own config.json should apply, exactly
REM     as it would in a normal session.
REM
REM cd /d first so config.json and meshghost-server.log resolve to THIS folder however the
REM script was started -- double-click, dragged onto a cmd window, or Run as administrator all
REM start with different working directories, and the relay reads config.json from the working
REM directory, not from its own location.
cd /d "%~dp0"

REM Both the check and the launch below spell out %~dp0 (this script's own folder) rather than
REM relying on the working directory cd /d just set: cmd normally searches the current directory
REM for a command, but that lookup is disabled wherever NoDefaultCurrentDirectoryInExePath is
REM set, and a bare "meshghost-server.exe" then fails with "not recognized as an internal or
REM external command" even though it is sitting right there. Found live while testing this
REM script from a stand-in release folder.
if not exist "%~dp0meshghost-server.exe" (
  echo.
  echo   meshghost-server.exe is not in this folder.
  echo.
  echo   Copy this .bat into your unzipped release folder -- the one holding
  echo   meshghost.exe, meshghost-server.exe and config.json -- and run it there.
  echo.
  pause
  exit /b 1
)

echo Starting the server in LOOPBACK mode -- you will see a ghost of yourself.
echo Leave this window open, then start meshghost.exe and load your game's mod as usual.
echo.
"%~dp0meshghost-server.exe" -loopback
pause
