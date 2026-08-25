@echo off
REM Loopback echo at SHIPPED settings -- the ONLY departure from a released relay is -loopback,
REM which echoes a client's own state back to it as "<id>-ghost" so one machine can see a ghost.
REM
REM Deliberately NOT run-relay-loopback.bat, whose -send-hz=100 is the exact knob that would
REM invalidate this test: the open question is how the drawn tier looks at the rate a real player
REM would actually receive, so the receive rate has to be the shipped 20Hz default. Pair it with
REM run-core-crystal-shipped.bat, never with `run-core.bat crystal` -- see that file's header.
..\meshghost-relay.exe -loopback
pause
