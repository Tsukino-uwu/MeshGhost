@echo off
REM Pseudoregalia client pinned to the tcp transport, for live-testing the
REM 2026-08-16 selectable-transport work against a real game.
REM
REM tcp: the default and the mandatory handshake leg. This is the path that already had field time, so run it first as a regression check that nothing broke.
REM
REM Pair this with run-relay-loopback.bat, which serves all three so you can
REM switch protocols by running a different one of these without restarting
REM the relay.
REM
REM IMPORTANT -- confirm which transport was ACTUALLY used. The connection
REM always handshakes over tcp and only then upgrades, and a preference the
REM relay does not serve degrades quietly to a working tcp session. So a run
REM that "works" proves nothing about tcp on its own. Check meshghost.log for:
REM     core: relay offers ... -- using tcp at 127.0.0.1:...
REM If that line names a different transport, this run did not test tcp.
..\meshghost.exe -game=pseudoregalia -transport=tcp -bridge=127.0.0.1:7778 -name=player1 -interp=0ms -min-send=10ms
pause
