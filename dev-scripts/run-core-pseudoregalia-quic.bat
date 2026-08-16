@echo off
REM Pseudoregalia client pinned to the quic transport, for live-testing the
REM 2026-08-16 selectable-transport work against a real game.
REM
REM quic: encrypted (its handshake is TLS 1.3) and spoofing-resistant, with the same loss behaviour as udp. Listens on its OWN port (see -listen-quic on the relay) because it runs over udp and cannot share one.
REM
REM Pair this with run-relay-loopback.bat, which serves all three so you can
REM switch protocols by running a different one of these without restarting
REM the relay.
REM
REM IMPORTANT -- confirm which transport was ACTUALLY used. The connection
REM always handshakes over tcp and only then upgrades, and a preference the
REM relay does not serve degrades quietly to a working tcp session. So a run
REM that "works" proves nothing about quic on its own. Check meshghost.log for:
REM     core: relay offers ... -- using quic at 127.0.0.1:...
REM If that line names a different transport, this run did not test quic.
..\meshghost.exe -game=pseudoregalia -transport=quic -bridge=127.0.0.1:7778 -name=player1 -interp=0ms -min-send=10ms
pause
