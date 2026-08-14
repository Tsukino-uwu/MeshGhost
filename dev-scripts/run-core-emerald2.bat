@echo off
rem Second core instance for real two-player Emerald testing (see
rem agent_docs/phases/phase4.md) -- pair with run-core-emerald.bat (instance 1, port 7778) and
rem a second real BizHawk/Emerald instance with MESHGHOST_BRIDGE_PORT=7779 set before launch.
..\meshghost.exe -game=emerald -bridge=127.0.0.1:7779 -name=player2 -interp=200ms
pause
