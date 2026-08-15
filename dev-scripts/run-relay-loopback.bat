@echo off
REM Dev-only Phase 3/6.5-style loopback: echoes each client's own state back to itself as
REM "<id>-ghost". Lets a single real client see itself as a remote ghost with no second
REM instance -- see agent_docs/phases/phase3.md and agent_docs/phases/phase6.md.
REM -send-hz=100: see run-relay.bat's own comment -- keeps this relay from silently overriding
REM the dev-only run-core-*.bat scripts' own fast -min-send back down to the 20Hz default.
..\meshghost-relay.exe -loopback -send-hz=100
pause
