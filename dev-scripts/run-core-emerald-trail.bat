@echo off
rem Pairs specifically with run-bizhawk-emerald-loopback-trail.local.bat (MESHGHOST_LOOPBACK_TRAIL=1,
rem zero render offset) -- that mode needs a real interpolation delay or the ghost sits exactly on
rem top of you with no visible trail at all, defeating the point. 200ms is the same value Phase 3
rem confirmed live (agent_docs/phases/phase3.md / status.md: "a ghost trails the player ~200ms
rem behind"), not an arbitrary pick. `run-core.bat emerald` itself defaults to instant
rem (-interp=0ms -min-send=10ms) for animation-diffing with the offset (non-trail) loopback mode --
rem use this launcher instead whenever you specifically want the trailing-behind effect.
..\meshghost.exe -game=emerald -bridge=127.0.0.1:7778 -name=player1 -interp=200ms
pause
