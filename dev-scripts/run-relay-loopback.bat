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
REM -listen-quic is NO LONGER passed here, and that is the point of the 2026-08-27
REM change: quic keeps -addr's port and the plain udp transport is the one that
REM moves aside (to -listen-udp's default, 127.0.0.1:7780). quic is a DEFAULT
REM transport and udp is opt-in, so making the default one surrender the shared
REM number had it backwards. This script serves all three, so udp relocates
REM automatically and the relay prints where each landed.
..\meshghost-relay.exe -loopback -send-hz=100 -transport=tcp,udp,quic
pause
