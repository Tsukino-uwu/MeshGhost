@echo off
REM Relay for a real two-machine session with run-core-pseudoregalia-online.bat.
REM NOT loopback: this is for two actual players, so there is no self-ghost.
REM
REM -resume-grace=8: how long a dropped player's identity is held before the room
REM is told it left. The built-in default is 20s, which is tuned for "a blip must
REM not cost a despawn" and pays for it at the other end -- a crash or alt-F4 also
REM leaves a frozen ghost standing there for the whole window, because the relay
REM cannot tell a crash from a bad connection. 8s keeps a real network blip
REM invisible (internal/core.reconnectWithBackoff retries at 1s, 2s, 4s, so it
REM gets three attempts inside that) while making a genuine crash clear up in a
REM couple of seconds rather than twenty. A clean game-close is unaffected either
REM way -- the core deliberately discards its resume token when the adapter goes,
REM so quitting normally is always an immediate, honest leave.
REM
REM The grace is only HALF the delay a peer actually sees, and the other half is
REM the transport's. Measured 2026-08-17: after a client was hard-killed, tcp
REM reported the drop in the same second (the OS sends an RST) while quic -- the
REM default transport -- took about 17 seconds, because a killed peer sends no
REM close frame and the connection sits there until quic's own idle timeout. So a
REM crash on quic freezes that ghost for roughly 17s + the grace, not the grace
REM alone. Tightening quic's idle timeout is a real follow-up (quicConfig in
REM internal/netx/quicconn sets no MaxIdleTimeout at all today); until then, do
REM not read this number as the whole story.
REM
REM -introspect=30s: logs what the relay currently believes -- who is in the room,
REM on which transport, and above all whether anyone is SUSPENDED (dropped but
REM being held). That last one is the state hardest to diagnose from the outside,
REM because a suspended player still appears in every roster and receives nothing.
REM If a ghost freezes and nobody can explain it, this is the line to read.
REM
REM -send-hz left at its 20Hz default ON PURPOSE, unlike the loopback dev scripts
REM which force 100. This is a real network with real bandwidth, and the client
REM script's -min-send=20ms already matches; 100Hz here would quadruple everyone's
REM traffic to prove nothing about the two capabilities being tested.
REM
REM Room code: set one before handing this address to anyone outside your own
REM machine. quic (the default transport) encrypts the session against a passive
REM observer but does NOT authenticate the relay, so the address alone is the
REM whole of the access control until a code is set.
..\meshghost-relay.exe -resume-grace=8 -introspect=30s
pause
