@echo off
REM Fault-injecting proxy between a client and a relay, so a session can be
REM run over a network worth being afraid of instead of a perfect loopback.
REM
REM Mirrors the relay's PORT NUMBERS on 127.0.0.2, which is load-bearing:
REM transport discovery sends the port but deliberately not the host, so a
REM client upgrading to udp/quic reuses whatever host it first connected to.
REM Same numbers on a second loopback address keeps the whole
REM handshake-then-upgrade path inside the proxy. A different port number
REM would route the upgrade around it and the session would look fine while
REM testing nothing.
REM
REM THE NO-ARG PROFILE IS THE WORST CASE A SHIPPED DEFAULT MUST SURVIVE, and it is
REM the ONLY profile a rate/interp verdict is made on (user's rule, 2026-09-02):
REM NA<->EU ping plus bad wifi. 100ms one-way per pass (the proxy is crossed twice
REM per peer path, so ~200 ping peer to peer), +/-50ms jitter, 5% loss, 3% reorder,
REM and a one-second blackout every 45s for the wifi dropout. A milder profile answers
REM a question nobody asked: on 2026-09-02 two games' interp ladders were judged on
REM 60/25/2/2 and had to be redone. Pass explicit flags ONLY to compare against this.
REM
REM Usage:
REM   run-netsim.bat                 (the worst-case profile above)
REM   run-netsim.bat -loss 0.1 -latency 80ms -jitter 40ms
REM   run-netsim.bat -partition-every 20s -partition-for 3s
REM
REM Then start a relay as usual (run-relay.bat / run-relay-loopback.bat) and
REM point a client at 127.0.0.2 instead of 127.0.0.1:
REM   ..\meshghost.exe -relay 127.0.0.2:7777 -game pseudoregalia
REM
REM The seed is printed at startup -- pass it back with -seed to replay the
REM same fault sequence when something breaks.
REM
REM NOTE -loss/-duplicate/-reorder are udp-only -- dropping bytes out of a
REM proxied tcp stream corrupts it rather than simulating loss, so they are
REM applied to the udp/quic flows and skipped on tcp. Combining them with a
REM mirrored tcp port is fine and is the normal case: the handshake is ALWAYS
REM tcp, so every real session needs tcp mirrored. The tool only refuses the
REM combination that does nothing at all -- those flags with NO udp ports.
setlocal
if "%~1"=="" (
  "%~dp0..\meshghost-netsim.exe" -tcp=7777 -udp=7777,7780 -latency 100ms -jitter 50ms -loss 0.05 -reorder 0.03 -partition-every 45s -partition-for 1s
) else (
  "%~dp0..\meshghost-netsim.exe" %*
)
endlocal
