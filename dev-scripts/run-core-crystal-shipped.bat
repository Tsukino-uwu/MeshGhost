@echo off
REM Crystal core at SHIPPED settings: no flags past the ones that pick the game and the bridge, so
REM interpolation is core.DefaultInterpolationDelay (250ms) and min-send is the default.
REM
REM The COMPLEMENT of run-core-crystal.bat, which forces -interp=0ms to judge the renderer against
REM the player 1:1. This one judges the opposite thing -- what a real player receives -- and the
REM 250ms is the subject of the test rather than a nuisance in it. Relying on the adapter's
REM AUTOSTART to get here is what made two sessions' worth of stutter work ambiguous (`phase9.md`):
REM the settings were right by accident and unlogged, so nothing recorded which rig had produced
REM which reading. Launch it explicitly instead. Pair with run-relay-loopback-shipped.bat.
..\meshghost.exe -game=crystal -bridge=127.0.0.1:7778 -name=player1
pause
