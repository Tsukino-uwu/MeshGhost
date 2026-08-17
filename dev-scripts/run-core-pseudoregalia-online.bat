@echo off
REM Pseudoregalia client with the two capabilities that help a REAL two-machine
REM session, for testing with the Linux tester. Pair with run-relay-online.bat.
REM
REM   clock.v1  -- ROOM-SCOPED, so BOTH players must run this script (or pass the
REM                same -features). It puts everyone's state timestamps in the
REM                relay's clock domain instead of each machine's own.
REM
REM                Why it matters here and not in loopback: agent_docs/testing.md
REM                records that interpolation degrades SILENTLY under clock skew.
REM                internal/core/interp.go compares a LOCAL wall-clock render time
REM                against a REMOTE's wall-clock timestamps, so if the two machines'
REM                clocks differ by more than -interp, interpolation stops entirely
REM                and every ghost falls back to an edge snapshot each tick. No
REM                error, no log line -- the ghost just looks subtly wrong. One
REM                machine is loopback, so this CANNOT be tested here; two machines
REM                is the only place it means anything.
REM
REM   resume.v1 -- CLIENT-SCOPED, so it works even if the other player does not
REM                pass it. On an unexpected drop the relay holds this player's
REM                identity for the grace window instead of announcing a leave:
REM                same player_id on reconnect, and nobody else sees the ghost
REM                despawn and respawn at all.
REM
REM                This is the case found live 2026-08-14 -- a relay restart left
REM                two cores idle forever, and before the heartbeat existed an idle
REM                timeout handed out a fresh player_id every minute, which every
REM                peer saw as a despawn/respawn. Over the internet under Proton,
REM                blips are the normal case, not the exception.
REM
REM WHAT resume.v1 DOES AND DOES NOT COVER -- measured 2026-08-17, not assumed:
REM   Covers: the relay CONNECTION dropping while this core process keeps running.
REM           A network blip, a route change, the proxy/router hiccuping. The core
REM           redials with its token and the room is never told anything happened.
REM           Confirmed end to end: "core: resumed the previous session as p1 --
REM           the room was never told we left".
REM   Does NOT cover: closing or crashing the GAME (or this core process). The
REM           token lives in this process's memory, so a new process starts with
REM           none and gets a fresh player_id. That is correct, not a bug -- a
REM           closed game should be a real leave.
REM   Does NOT cover: restarting the RELAY. Its sessions are in memory too.
REM   Barely matters on tcp for SHORT blips: a tcp session survived a 25s total
REM           link partition here without disconnecting at all, because the read
REM           deadline is 60s. Resumption earns its keep on quic (the default) and
REM           for outages long enough to actually break the connection.
REM
REM WHAT TO WATCH FOR, since neither is visible on its own:
REM   1. meshghost.log must show, once, at connect:
REM          core: room "default" negotiated capabilities [clock.v1 resume.v1]
REM      If that line is missing, NOTHING here is on and the run tests nothing.
REM      If it names fewer capabilities than you passed, the other player's
REM      room-scoped set won and yours was refused -- check for a reject.
REM   2. Pull the network cable / drop wifi mid-session, for LONGER than a couple
REM      of seconds (see above -- a short cut may not break the connection at
REM      all). The OTHER player's screen should show your ghost keep still and
REM      then carry on -- NOT despawn and respawn. Your own log should say
REM      "resumed the previous session as pN". Do not test this by closing the
REM      game: that is a real leave by design.
REM   3. Deliberately set the two machines' clocks apart by ~1s and play. With
REM      clock.v1 the ghosts should stay smooth; without it they visibly stop
REM      interpolating. This is the only way to actually test clock sync.
REM
REM -interp=0ms and -min-send=10ms, matching every other dev script. **Dev scripts
REM are always 1:1** -- they exist so the ghost can be compared directly against the
REM player, and any interpolation renders the ghost deliberately in the PAST (100ms
REM is ~6 frames at 60fps, a plainly visible lag). Whatever else a run is testing,
REM it must not silently cost the rig the one thing it is for.
REM
REM **Consequence to know before testing clock.v1 specifically:** at interp=0 the
REM newest sample is always used, so clock skew between two machines has nothing to
REM change and this script cannot demonstrate clock sync working or failing. That
REM measurement needs interp raised ABOVE the skew being tested -- which is a
REM deliberate, temporary, say-so-out-loud change for that one run, then put back.
REM The resumption half below is unaffected and testable as-is.
..\meshghost.exe -game=pseudoregalia -bridge=127.0.0.1:7778 -name=player1 ^
  -features=clock.v1,resume.v1 -interp=0ms -min-send=10ms
pause
