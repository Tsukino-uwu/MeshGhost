@echo off
REM Dev-only Phase 3/6.5-style loopback: echoes each client's own state back to itself as
REM "<id>-ghost". Lets a single real client see itself as a remote ghost with no second
REM instance -- see agent_docs/phases/phase3.md and agent_docs/phases/phase6.md.
REM -send-hz=100: see run-relay.bat's own comment -- keeps this relay from silently overriding
REM the dev-only run-core-*.bat scripts' own fast -min-send back down to the 20Hz default.
REM -transport=tcp,udp,quic: serves all three at once so the per-protocol
REM run-core-*-tcp/udp/quic.bat scripts each work without restarting this
REM relay. Harmless when unused -- a client picks exactly one, and clients on
REM different transports share a room normally.
REM -listen-quic is passed EXPLICITLY here and must be: quic normally shares
REM -addr's port (one port number for a host to forward), but the plain udp
REM transport takes that udp port itself, so serving udp and quic together
REM needs quic told where to go. Without this the relay refuses to start and
REM says so. This is the uncommon case -- a default relay serves tcp+quic on
REM one port. See the transport ADR in agent_docs/architecture.md.
..\meshghost-relay.exe -loopback -send-hz=100 -transport=tcp,udp,quic -listen-quic=127.0.0.1:7780
pause
