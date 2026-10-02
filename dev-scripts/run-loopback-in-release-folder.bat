@echo off
REM Loopback for a downloaded release: copy this file next to meshghost.exe and meshghost-server.exe and run it
REM instead of meshghost-server.exe; the server echoes your state back as "<id>-ghost", so you see yourself.
REM No -send-hz=100 here: that only keeps a dev relay out of the dev core launchers' way, and a release should run
REM at its own config.json's send_hz.
REM cd /d first: the relay reads config.json from the working directory, which differs by how the script started.
cd /d "%~dp0"

REM %~dp0 is spelled out because cmd skips the current directory when NoDefaultCurrentDirectoryInExePath is set.
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
