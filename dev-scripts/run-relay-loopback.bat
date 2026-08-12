@echo off
REM Dev-only Phase 3/6.5-style loopback: echoes each client's own state back to itself as
REM "<id>-ghost". Lets a single real client see itself as a remote ghost with no second
REM instance -- see agent_docs/phases/phase3.md and agent_docs/phases/phase6.md.
..\meshghost-relay.exe -loopback
pause
