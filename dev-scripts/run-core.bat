@echo off
REM The dev core launcher for every game: run-core.bat <game> [transport] [instance]; no game prints the usage.
REM Instance 2 is the second client on one machine: bridge 7779 and -name=player2.
REM -interp=0ms -min-send=10ms judge the renderer 1:1: pair with run-relay-loopback.bat (-send-hz=100) and a ghost
REM offset to the side, since zero interp on a ghost sitting on the player hides it.
REM The shipped, trail and online rigs keep their own files because the filename records which rig made a reading.
REM A transport the relay does not serve degrades quietly to tcp: check `using <transport>` in meshghost.log.
REM `if COND set A & set B` runs set B unconditionally, hence the plain goto dispatch below.
setlocal
cd /d "%~dp0"

set "GAME=%~1"
set "TRANSPORT=%~2"
set "INSTANCE=%~3"

if "%GAME%"=="" goto :usage
if /i "%GAME%"=="emerald"       goto :game_ok
if /i "%GAME%"=="crystal"       goto :game_ok
if /i "%GAME%"=="tevi"          goto :game_ok
if /i "%GAME%"=="pseudoregalia" goto :game_ok
echo.
echo   Unknown game "%GAME%".
goto :usage
:game_ok

if "%INSTANCE%"=="" set "INSTANCE=1"
if "%INSTANCE%"=="1" goto :inst1
if "%INSTANCE%"=="2" goto :inst2
echo.
echo   Unknown instance "%INSTANCE%" -- use 1 or 2.
goto :usage
:inst1
set "BRIDGE=127.0.0.1:7778"
set "NAME=player1"
goto :inst_ok
:inst2
set "BRIDGE=127.0.0.1:7779"
set "NAME=player2"
goto :inst_ok
:inst_ok

REM auto passes no -transport flag: it is the client's own default.
set "TFLAG="
set "TSHOWN=auto"
if "%TRANSPORT%"==""        goto :tr_ok
if /i "%TRANSPORT%"=="auto" goto :tr_ok
if /i "%TRANSPORT%"=="tcp"  goto :tr_set
if /i "%TRANSPORT%"=="udp"  goto :tr_set
if /i "%TRANSPORT%"=="quic" goto :tr_set
echo.
echo   Unknown transport "%TRANSPORT%" -- use auto, tcp, udp or quic.
goto :usage
:tr_set
set "TFLAG=-transport=%TRANSPORT%"
set "TSHOWN=%TRANSPORT%"
:tr_ok

echo.
echo   game=%GAME%  bridge=%BRIDGE%  name=%NAME%  transport=%TSHOWN%
echo.
..\meshghost.exe -game=%GAME% %TFLAG% -bridge=%BRIDGE% -name=%NAME% -interp=0ms -min-send=10ms
pause
exit /b 0

:usage
echo.
echo   usage:  run-core.bat ^<game^> [transport] [instance]
echo.
echo     game       emerald ^| crystal ^| tevi ^| pseudoregalia   (required)
echo     transport  auto ^| tcp ^| udp ^| quic                    (default: auto)
echo     instance   1 ^| 2                                       (default: 1)
echo.
echo   examples:
echo     run-core.bat emerald                 one Emerald core, bridge 7778
echo     run-core.bat emerald auto 2          the second client, bridge 7779
echo     run-core.bat pseudoregalia quic      pinned to quic
echo.
exit /b 1
