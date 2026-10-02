@echo off
REM Fault-injecting proxy between clients and a relay, so a session runs over a bad network instead of a loopback.
REM It mirrors the relay's port numbers on 127.0.0.2: transport discovery sends the port but not the host, so the
REM udp/quic upgrade stays inside the proxy, where a different port would route around it and test nothing.
REM
REM The no-arg profile is the worst case a shipped default must survive, NA<->EU ping plus bad wifi, and the only
REM one a rate or interp verdict is made on. The proxy is crossed twice per peer path, so 100ms a pass is ~200 ping.
REM Pass flags only to compare against it, and say which profile a result came from:
REM   run-netsim.bat -loss 0.1 -latency 80ms -jitter 40ms
REM   run-netsim.bat -tcp=7777 -udp=7777,7780 -latency 100ms -jitter 50ms -loss 0.05 -loss-burst 250ms
REM -loss alone drops datagrams independently and rarely loses the consecutive samples that empty an interp buffer;
REM -loss-burst keeps that share but loses it in runs of about that length: a different network, not a harder one.
REM
REM Then start a relay and point a client at 127.0.0.2:  ..\meshghost.exe -relay 127.0.0.2:7777 -game pseudoregalia
REM The seed is printed at startup; -seed replays the same fault model, not a bit-identical run.
REM -loss, -duplicate and -reorder apply to udp flows only; the handshake is always tcp, so tcp stays mirrored too.
setlocal
if "%~1"=="" (
  "%~dp0..\meshghost-netsim.exe" -tcp=7777 -udp=7777,7780 -latency 100ms -jitter 50ms -loss 0.05 -reorder 0.03 -partition-every 45s -partition-for 1s
) else (
  "%~dp0..\meshghost-netsim.exe" %*
)
endlocal
