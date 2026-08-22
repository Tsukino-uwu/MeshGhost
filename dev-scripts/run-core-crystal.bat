@echo off
rem Dev-only core for Crystal, mirroring run-core-emerald.bat -- Crystal had no equivalent until
rem 2026-08-22, so its adapter always AUTOSTARTED a core on the shipped defaults (250ms interp).
rem That is the right default for play and the wrong one for this test: with the loopback ghost
rem offset to the side, the point is judging the drawn tier against the player 1:1, and a quarter
rem second of interpolation means what you are watching is the wire, not the renderer. See
rem run-core-emerald-trail.bat for the opposite mode, where a ghost sits ON the player and the
rem delay is the thing being judged.
..\meshghost.exe -game=crystal -bridge=127.0.0.1:7778 -name=player1 -interp=0ms -min-send=10ms
pause
