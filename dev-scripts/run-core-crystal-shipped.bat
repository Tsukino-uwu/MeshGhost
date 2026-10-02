@echo off
REM Crystal core at shipped settings: no flags past game and bridge, so interp and min-send are the core's defaults.
REM The complement of `run-core.bat crystal`: it judges what a real player receives, so the shipped delay is the
REM subject. Launched explicitly rather than through autostart, so the rig behind a reading is on record.
REM Pair with run-relay-loopback-shipped.bat.
..\meshghost.exe -game=crystal -bridge=127.0.0.1:7778 -name=player1
pause
