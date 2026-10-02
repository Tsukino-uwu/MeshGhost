@echo off
REM Loopback echo at shipped settings: -loopback is the only departure from a released relay.
REM Not run-relay-loopback.bat, whose -send-hz=100 is the exact knob that would invalidate this test: it judges the
REM drawn tier at the default rate a real player receives. Pair with run-core-crystal-shipped.bat, never with
REM `run-core.bat crystal`.
..\meshghost-relay.exe -loopback
pause
