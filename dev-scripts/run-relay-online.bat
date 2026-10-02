@echo off
REM Relay for a real two-machine session with run-core-pseudoregalia-online.bat; not loopback, so no self-ghost.
REM -resume-grace=8 rather than the default 20s, which also leaves a crashed player's ghost frozen for the whole
REM window: 8s still covers a blip (the core retries at 1s, doubling) and clears a crash sooner. A clean close is
REM an immediate leave either way.
REM On quic a killed peer sends no close frame, so a crash shows only at quic's idle timeout, plus the grace.
REM -introspect=30s logs who is SUSPENDED (dropped, held, still in every roster): read it when a ghost freezes.
REM -send-hz=100 keeps the relay's advertised rate from dragging the dev clients' -min-send=10ms back down.
REM Set a room code before handing this address out: without one, the address is the only access control.
..\meshghost-relay.exe -send-hz=100 -resume-grace=8 -introspect=30s
pause
