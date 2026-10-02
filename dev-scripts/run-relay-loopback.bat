@echo off
REM Dev loopback relay: echoes each client's own state back as "<id>-ghost", so one client sees itself as a ghost.
REM -send-hz=100 keeps the relay's advertised rate from dragging the dev core launchers' -min-send=10ms back down.
REM Serving tcp, udp and quic lets run-core.bat's transport argument change without a relay restart; udp needs a
REM relay built with -tags meshghost_devudp, and a release build refuses the name.
..\meshghost-relay.exe -loopback -send-hz=100 -transport=tcp,udp,quic
pause
