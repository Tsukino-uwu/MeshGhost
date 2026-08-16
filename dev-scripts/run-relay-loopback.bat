@echo off
REM Dev-only Phase 3/6.5-style loopback: echoes each client's own state back to itself as
REM "<id>-ghost". Lets a single real client see itself as a remote ghost with no second
REM instance -- see agent_docs/phases/phase3.md and agent_docs/phases/phase6.md.
REM -send-hz=100: see run-relay.bat's own comment -- keeps this relay from silently overriding
REM the dev-only run-core-*.bat scripts' own fast -min-send back down to the 20Hz default.
REM -transport=tcp,udp,quic: serves all three at once so the per-protocol
REM run-core-*-tcp/udp/quic.bat scripts each work without restarting this
REM relay. Harmless when unused -- a client picks exactly one, and clients on
REM different transports share a room normally. quic gets its own port
REM (-listen-quic, default 127.0.0.1:7780) because it runs over udp and
REM cannot share one with the plain udp transport. See the transport ADR in
REM agent_docs/architecture.md.
..\meshghost-relay.exe -loopback -send-hz=100 -transport=tcp,udp,quic
pause
