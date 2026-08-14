@echo off
rem Second core instance for real two-TEVI testing (see agent_docs/phases/phase6.md's 6.6
rem entry) -- pair with run-core-tevi.bat (instance 1, port 7778) and a standalone TEVI build
rem (e.g. C:\dev\tevi-14778703, see agent_docs/environment.md) running alongside your normal
rem Steam TEVI copy. That standalone install's own BepInEx/config/dev.meshghost.tevi.cfg needs
rem its BridgePort set to 7779 to match this core -- the Steam copy stays on the default 7778.
..\meshghost.exe -game=tevi -bridge=127.0.0.1:7779 -name=player2 -interp=0ms -min-send=10ms
pause
