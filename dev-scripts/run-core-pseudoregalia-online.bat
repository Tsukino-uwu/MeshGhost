@echo off
REM Pseudoregalia client with clock.v1 and resume.v1 for a real two-machine session; pair with run-relay-online.bat.
REM clock.v1 is room-scoped, so both players must pass it: it puts state timestamps in the relay's clock domain,
REM since interpolation compares a local render time against a remote's timestamps and fails silently under skew.
REM resume.v1 is client-scoped: on a dropped connection the relay holds this player's identity for the grace
REM window, so peers see no despawn. Closing the game or restarting the relay still ends the session.
REM
REM What to watch for:
REM   1. meshghost.log shows once, at connect: core: room "default" negotiated capabilities [clock.v1 resume.v1]
REM      Missing means nothing here is on; fewer than passed means the other player's room-scoped set won.
REM   2. Drop the network long enough to break the connection, not a short blip: the other player should see the
REM      ghost hold still and carry on, never despawn, and this log say "resumed the previous session as pN".
REM   3. Set the two clocks about 1s apart: with clock.v1 the ghosts stay smooth. At -interp=0ms the newest sample
REM      is always used and skew changes nothing, so raise -interp above the skew for that run, then put it back.
REM -interp=0ms -min-send=10ms like every dev launcher, so the ghost can be judged 1:1 against the player.
..\meshghost.exe -game=pseudoregalia -bridge=127.0.0.1:7778 -name=player1 ^
  -features=clock.v1,resume.v1 -interp=0ms -min-send=10ms
pause
