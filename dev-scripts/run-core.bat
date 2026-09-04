@echo off
REM One dev core launcher for every game, replacing nine near-identical scripts.
REM
REM   run-core.bat <game> [transport] [instance]
REM
REM     game       emerald | crystal | tevi | pseudoregalia        (required)
REM     transport  auto | tcp | udp | quic                         (default: auto)
REM     instance   1 | 2                                           (default: 1)
REM
REM Instance 2 is the second client on one machine: bridge port 7779 and -name=player2,
REM which is the only difference the old run-core-emerald2.bat / run-core-tevi2.bat had.
REM
REM These are DEV settings on purpose: -interp=0ms -min-send=10ms. Pair them with
REM run-relay-loopback.bat (-send-hz=100), and read "Interp is PAIRED with the loopback
REM offset" in README.md before judging anything -- zero interpolation is right when the
REM ghost is offset to the side and you are judging the renderer against the player 1:1,
REM and wrong when the ghost sits on the player and the delay is the subject.
REM
REM For the opposite rig -- shipped 250ms interpolation, shipped send rate, judging what a
REM real player actually receives -- use run-core-crystal-shipped.bat with
REM run-relay-loopback-shipped.bat. Those are NOT collapsed into this script deliberately:
REM the filename is what records which rig produced a reading, and phase9.md has two
REM sessions made ambiguous by that not being written down. Same for
REM run-core-emerald-trail.bat (a real -interp=200ms, ghost on the player) and
REM run-core-pseudoregalia-online.bat (the two-machine procedure, with its own 77 lines).
REM
REM CONFIRM WHICH TRANSPORT WAS ACTUALLY USED when you pass one. Every connection
REM handshakes over tcp and only then upgrades, and a preference the relay does not serve
REM degrades quietly to a working tcp session -- so a run that "works" proves nothing on
REM its own. meshghost.log carries `core: relay offers ... -- using <transport> at ...`;
REM if that names something else, the run did not test what you meant.
REM
REM TWO BATCH TRAPS THIS FILE WAS WRITTEN INTO AND OUT OF, 2026-08-25, both silent:
REM   * This file MUST keep CRLF line endings. cmd.exe mis-parses labels and `goto` in an
REM     LF-only .bat, and the first draft ran straight past its own argument validation and
REM     launched a core with an empty -game. The short 3-line scripts this replaces were
REM     LF too and never showed it, because they had no labels to mis-parse.
REM   * `if COND set A & set B` does NOT put `set B` inside the condition -- cmd parses it
REM     as `(if COND set A) & set B`, so the tail runs unconditionally. Hence the plain
REM     goto dispatch below rather than anything more compact.
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

REM auto is the client's own default, so it is expressed by passing no flag at all rather
REM than by -transport=auto -- keeping the command line identical to the old per-game
REM scripts, which passed none.
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
