@echo off
REM -send-hz=100: a relay's advertised rate is prescriptive and the slower of it and a core's own -min-send wins,
REM so the relay's default would drag the dev core launchers' -min-send=10ms back down.
..\meshghost-relay.exe -send-hz=100
pause
