@echo off
REM -send-hz=100: local dev/loopback testing has no real bandwidth constraint, and the
REM dev-only run-core-*.bat scripts pass their own fast -min-send (e.g. 10ms) specifically to
REM stop network buffering from hiding real timing bugs (see agent_docs/phases/phase8.md). Since
REM the send/receive rate-control feature, a relay's advertised send_hz is prescriptive and
REM effectiveSendInterval takes the SLOWER of the relay's rate and a Core's own explicit
REM MinSendInterval -- left at this relay's own 20Hz default, that would silently override every
REM one of those fast local overrides back down to 50ms. See the ADR in agent_docs/architecture.md.
..\meshghost-relay.exe -send-hz=100
pause
