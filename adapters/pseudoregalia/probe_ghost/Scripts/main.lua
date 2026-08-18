-- MeshGhost Phase 7.5: the real Pseudoregalia adapter. Builds on Phase 7.4's confirmed-working
-- ghost design (spawn the player's own Pawn class, re-possess immediately, and a
-- SetViewTargetWithBlend hook that fights back whenever spawning a ghost makes this game's own
-- camera-rig system re-target away from the real player -- full history in
-- agent_docs/phases/phase7.md and this repo's git history) and wires it to the real bridge
-- protocol instead of a hardcoded local offset: reads real local state every tick (position,
-- orientation, area_id, a velocity-derived anim placeholder per 7.3's decision), connects to the
-- local core over the bridge (non-blocking, retry per frame, per adapters/_template/PROTOCOL.md
-- and agent_docs/contract.md), and renders every remote the core tells us about instead of
-- following the local player directly.
--
-- Deploy: copy this probe_ghost/ folder into
--   <Pseudoregalia install>\pseudoregalia\Binaries\Win64\ue4ss\Mods\MeshGhostGhostProbe\Scripts\main.lua
-- then add "MeshGhostGhostProbe : 1" to that ue4ss\Mods\mods.txt.
--
-- Requires, started BEFORE launching the game (same as Phase 7.2's Stage 3 probe):
--   dev-scripts\run-relay-loopback.bat      (meshghost-relay.exe -loopback)
--   dev-scripts\run-core-pseudoregalia.bat  (meshghost.exe -game=pseudoregalia -bridge=127.0.0.1:7778)
-- In loopback mode the relay echoes this client's own state back as "<name>-ghost" (here,
-- "player1-ghost", per run-core-pseudoregalia.bat's -name=player1) -- so the visible outcome is
-- a ghost trailing the local player over a REAL relay/core/bridge round trip, not a hardcoded
-- local offset like Phase 7.4 used to prove spawn/positioning alone.
--
-- Grounded APIs, same standard as the rest of this phase (bundled RE-UE4SS docs first, `gh api
-- search/code` fallback, per CLAUDE.md) -- everything already confirmed live in Phase 7.4 is
-- reused as-is (SpawnActor, K2_GetActorLocation/Rotation, K2_SetActorLocationAndRotation,
-- GetComponentByClass, SetActorEnableCollision, Possess, the SetViewTargetWithBlend hook,
-- direct UPROPERTY reads/writes). New for 7.5:
--   package.loadlib(vendored lua54.dll / socket-windows-5-4.dll)  -- confirmed live in 7.2 Stage 2/3
--   socket.tcp():settimeout(0)/:connect()/:send()/:receive()      -- confirmed live in 7.2 Stage 3
--     (Stage 3 used a blocking timeout for a one-shot probe; this uses settimeout(0), the
--     non-blocking pattern adapters/pokemon/emerald/probes/phase5_5_sprite.lua already uses for the
--     same per-frame connect-retry shape in the same Lua dialect)
--   K2_DestroyActor()  -- gh api search/code, 710 hits -- not yet confirmed live on this build;
--     tried defensively for despawn_remote, falls back to hiding the actor far away if it fails
--     (this build's UFunction reflection has repeatedly turned out narrower than expected)
--
-- JSON encode/decode is a straight port of this project's own existing minimal JSON
-- implementation (adapters/pokemon/emerald/probes/phase5_5_sprite.lua) -- plain Lua string/table
-- operations, no BizHawk-specific API involved, already proven correct against the real bridge
-- wire format.

local UEHelpers = require("UEHelpers")

local GAME_ID = "pseudoregalia"
local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 7778
-- DIAG (2026-08-12): the vendored LuaSocket build silently corrupts/truncates a large majority
-- (~85-98%) of received render_remote lines under sustained real traffic -- confirmed via a raw
-- receive-side byte count, not just JSON-decode failures. Neither shrinking messages (area_id,
-- ~325 -> ~274 bytes: 98/96/89/86% vs 98/99/88/88% failure at matching tick counts, no real
-- difference) nor slowing the tick rate (100ms -> 250ms: ~84% failure at the same ~30s mark
-- either way) changed the failure rate. Ruled out as adapter-side causes: outgoing sends (100%
-- ok, 0 timeouts across every test), raw line arrival count (matches expected volume), and JSON
-- content/shape (well-formed as far as any read gets before cutting off). This is a genuine
-- binary-compatibility wall in the vendored socket-windows-5-4.dll/lua54.dll pair against UE4SS's
-- own independently-built embedded Lua 5.4 -- see agent_docs/phases/phase7.md's 7.5 entry and
-- agent_docs/risks.md. Reverted to 100ms (the smoother base rate) since slower didn't help.
local FOLLOW_INTERVAL_MS = 100
local MIN_PLAUSIBLE_DISTANCE = 100.0 -- see trySpawnRemoteGhost -- a pawn/remote position this
                                      -- close to the origin means its transform likely isn't
                                      -- placed yet (confirmed live in 7.1/7.4), not a real spot.
-- DIAG (2026-08-12): user reported the ghost "teleporting" instead of smoothly following during
-- plain movement in area 1, in a run that had no MAX_TICK_DELTA-style guard to blame (that guard
-- was only ever reintroduced for the bisect test, which never got a ghost to spawn). 7.4 already
-- hit this exact shape of bug once -- a periodic log that looked reassuring but was only proof of
-- what the script *wrote*, not of what the actor's transform actually became
-- (agent_docs/phases/phase7.md, "the position log was self-fulfilling"). Applying that same fix
-- here: log intended vs. a genuinely separate post-write read, throttled, so the next run can tell
-- "network data itself arrives in jumps" apart from "the write isn't sticking every tick" apart
-- from "it's sticking but something else visually interrupts it."
local REDRAW_LOG_INTERVAL_TICKS = 20 -- ~2s at FOLLOW_INTERVAL_MS=100, matches 7.4's own interval
-- No MAX_TICK_DELTA/REFUSAL_RESYNC_LIMIT here, unlike 7.4's local-follow design: that guard
-- existed to catch a *local* scripting bug (mutating a live UE reference caused runaway drift --
-- see 7.4's drag-bug history). A remote's position comes straight from parsed network JSON each
-- tick, so there's no equivalent drift source to guard against, and real player movement
-- (backflips/dashes, measured up to ~12,000 units in one tick during 7.4 testing) routinely
-- exceeds any threshold that would look like a bug. Confirmed live 2026-08-12: keeping the
-- refusal logic produced exactly the "freeze then teleport" symptom this comment now explains,
-- and it also violated PROTOCOL.md's "redraw every entry unconditionally" rule.

----------------------------------------------------------------------------
-- Vendored LuaSocket -- confirmed live in Phase 7.2 Stage 2/3.
----------------------------------------------------------------------------

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    local path = src:match("^@(.*[/\\])")
    return path or "./"
end

local SCRIPT_DIR = scriptDir()

local function loadSocketCore()
    pcall(function()
        package.loadlib(SCRIPT_DIR .. "lib/x64/lua54.dll", "meshghost_force_preload")
    end)
    local dllPath = SCRIPT_DIR .. "lib/x64/socket-windows-5-4.dll"
    return assert(package.loadlib(dllPath, "luaopen_socket_core"))()
end

local okSocketCore, socketCoreOrErr = pcall(loadSocketCore)
if not okSocketCore then
    print(string.format("[MeshGhostGhostProbe] FATAL: failed to load socket core: %s\n", tostring(socketCoreOrErr)))
    return
end
local socketCore = socketCoreOrErr
print("[MeshGhostGhostProbe] socket core loaded.\n")

----------------------------------------------------------------------------
-- Minimal JSON -- ported from adapters/pokemon/emerald/probes/phase5_5_sprite.lua, already proven
-- against the real bridge wire format.
----------------------------------------------------------------------------

local function jsonString(s)
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    return '"' .. s .. '"'
end

local decodeValue -- forward declaration

local function skipWs(s, i)
    local _, j = s:find("^[ \t\r\n]*", i)
    return j + 1
end

local function decodeString(s, i)
    local j = i + 1
    local out = {}
    while true do
        local c = s:sub(j, j)
        if c == "" then
            error("json: unterminated string")
        elseif c == '"' then
            return table.concat(out), j + 1
        elseif c == "\\" then
            local e = s:sub(j + 1, j + 1)
            if e == "n" then table.insert(out, "\n")
            elseif e == "t" then table.insert(out, "\t")
            elseif e == "r" then table.insert(out, "\r")
            elseif e == "u" then
                local hex = s:sub(j + 2, j + 5)
                table.insert(out, string.char(tonumber(hex, 16) % 256))
                j = j + 4
            else
                table.insert(out, e)
            end
            j = j + 2
        else
            table.insert(out, c)
            j = j + 1
        end
    end
end

local function decodeNumber(s, i)
    local _, j, num = s:find("^(-?%d+%.?%d*[eE]?[%+%-]?%d*)", i)
    if not num then error("json: expected number") end
    return tonumber(num), j + 1
end

local function decodeObject(s, i)
    local obj = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        local key
        key, i = decodeString(s, i)
        i = skipWs(s, i)
        if s:sub(i, i) ~= ":" then error("json: expected ':'") end
        i = skipWs(s, i + 1)
        local val
        val, i = decodeValue(s, i)
        obj[key] = val
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skipWs(s, i + 1)
        elseif c == "}" then
            return obj, i + 1
        else
            error("json: expected ',' or '}'")
        end
    end
end

local function decodeArray(s, i)
    local arr = {}
    i = skipWs(s, i + 1)
    if s:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local val
        val, i = decodeValue(s, i)
        table.insert(arr, val)
        i = skipWs(s, i)
        local c = s:sub(i, i)
        if c == "," then
            i = skipWs(s, i + 1)
        elseif c == "]" then
            return arr, i + 1
        else
            error("json: expected ',' or ']'")
        end
    end
end

decodeValue = function(s, i)
    i = skipWs(s, i)
    local c = s:sub(i, i)
    if c == "{" then return decodeObject(s, i)
    elseif c == "[" then return decodeArray(s, i)
    elseif c == '"' then return decodeString(s, i)
    elseif c == "t" then
        if s:sub(i, i + 3) ~= "true" then error("json: bad literal") end
        return true, i + 4
    elseif c == "f" then
        if s:sub(i, i + 4) ~= "false" then error("json: bad literal") end
        return false, i + 5
    elseif c == "n" then
        if s:sub(i, i + 3) ~= "null" then error("json: bad literal") end
        return nil, i + 4
    else
        return decodeNumber(s, i)
    end
end

local function jsonDecode(line)
    local ok, val = pcall(function() return decodeValue(line, 1) end)
    if not ok then return nil end
    return val
end

----------------------------------------------------------------------------
-- Bridge connection.
----------------------------------------------------------------------------

local sock = nil
local connected = false
local helloSent = false
local remotes = {} -- player_id -> { state = {...}, ghost = AActor|nil, spawning = bool }

local function despawnAllRemotes()
    for playerId, remote in pairs(remotes) do
        if remote.ghost ~= nil and remote.ghost:IsValid() then
            local destroyOk = pcall(function() remote.ghost:K2_DestroyActor() end)
            if not destroyOk then
                -- Fallback: not grounded as working on this build, hide it far away instead of
                -- leaving a stale, un-networked ghost standing around forever.
                pcall(function()
                    local loc = remote.ghost:K2_GetActorLocation()
                    loc.Z = loc.Z - 1000000.0
                    remote.ghost:K2_SetActorLocationAndRotation(loc, remote.ghost:K2_GetActorRotation(), false, {}, false)
                end)
            end
        end
    end
    remotes = {}
end

local function connectBridge()
    if not sock then
        sock = socketCore.tcp()
        sock:settimeout(0)
    end
    local ok, err = sock:connect(BRIDGE_HOST, BRIDGE_PORT)
    if ok == 1 or err == "already connected" then
        connected = true
        helloSent = false
    end
end

local function resetBridge()
    if connected then
        print("[MeshGhostGhostProbe] bridge connection lost, will retry connecting.\n")
    end
    if sock then pcall(function() sock:close() end) end
    sock = nil
    connected = false
    helloSent = false
    despawnAllRemotes()
end

-- DIAG (2026-08-12): the redraw diagnostic showed the ghost's *target* position itself frozen for
-- 6-20+ seconds at a stretch before jumping, with the write always sticking correctly -- ruling
-- out the apply side and pointing upstream, at either our own outgoing sends or what the core
-- actually receives/echoes. sock:send() on a non-blocking (settimeout(0)) socket can return
-- nil, "timeout" for a send that didn't go through at all -- the existing code silently drops
-- that line with no retry and no count, which would produce exactly this "mostly nothing gets
-- through" pattern if it happens often. These counters make that directly checkable via the
-- heartbeat instead of guessed at.
local sendCallCount = 0
local sendOkCount = 0
local sendTimeoutCount = 0
local sendOtherErrorCount = 0

local function sendLine(line)
    sendCallCount = sendCallCount + 1
    local ok, err = sock:send(line .. "\n")
    if ok then
        sendOkCount = sendOkCount + 1
    elseif err == "timeout" then
        sendTimeoutCount = sendTimeoutCount + 1
    else
        sendOtherErrorCount = sendOtherErrorCount + 1
        resetBridge()
    end
end

----------------------------------------------------------------------------
-- Local state reading. Field shapes decided in 7.3 (agent_docs/phases/phase7.md):
--   position: raw UE units (cm), [X, Y, Z]
--   orientation: full [pitch, yaw, roll]
--   area_id: the level name string, world.PersistentLevel:GetFullName() -- confirmed live in 7.1
--   nil-equivalent: no valid PlayerController -- confirmed live in 7.1
--   anim: placeholder movement-state tag inferred from position delta between ticks (a real
--     CharacterMovement/Velocity property was deliberately not assumed -- computing from
--     positions already confirmed readable keeps this grounded without a new, unverified
--     property name). Real animation playback is 7.6's problem.
----------------------------------------------------------------------------

local lastLocalPos = nil -- {x, y, z, t} for anim-speed inference; t is a tick counter, not
                          -- wall-clock time (os.clock() availability not confirmed on this
                          -- build, and FOLLOW_INTERVAL_MS is a known, fixed tick rate anyway)
local localTickCount = 0
local RUNNING_SPEED_THRESHOLD = 5.0 -- cm per FOLLOW_INTERVAL_MS tick; not grounded against any
                                     -- real Pseudoregalia movement constant (7.1 didn't capture
                                     -- speed), a placeholder per 7.3's own "anim is placeholder
                                     -- only" decision.

local function safeGetLevelName()
    local ok, world = pcall(UEHelpers.GetWorld)
    if not ok or world == nil or not world:IsValid() then
        return "<no world>"
    end
    local level = world.PersistentLevel
    if level == nil or not level:IsValid() then
        return "<no persistent level>"
    end
    local ok2, name = pcall(function() return level:GetFullName() end)
    if not ok2 or name == nil then
        return "<level name read failed>"
    end
    -- DIAG (2026-08-12): the full name (e.g. "Level /Game/Maps/ZONE_LowerCastle.
    -- ZONE_LowerCastle:PersistentLevel", ~68 chars) is a major contributor to render_remote
    -- lines the vendored LuaSocket build was failing to read past ~150-190 bytes into. area_id
    -- is opaque and compared by equality only (CLAUDE.md) -- it doesn't need to be the full
    -- path, just stable and unique per level. Testing whether a much shorter id avoids the
    -- read failures; falls back to the full name if this build's naming doesn't match the
    -- expected "X.X:PersistentLevel" shape confirmed live in 7.1.
    local short = name:match("([%w_]+)%.[%w_]+:PersistentLevel")
    return short or name
end

-- getLocalState returns nil (don't send this frame) or a plain Lua table:
--   { area_id, position = {x,y,z}, orientation = {pitch,yaw,roll}, anim }
local function getLocalState(pawn)
    local loc = pawn:K2_GetActorLocation()
    local rot = pawn:K2_GetActorRotation()
    local x, y, z = loc.X, loc.Y, loc.Z

    localTickCount = localTickCount + 1
    local anim = "idle"
    if lastLocalPos ~= nil then
        local dx, dy, dz = x - lastLocalPos.x, y - lastLocalPos.y, z - lastLocalPos.z
        local speed = math.sqrt(dx * dx + dy * dy + dz * dz)
        if speed > RUNNING_SPEED_THRESHOLD then
            anim = "running"
        end
    end
    lastLocalPos = { x = x, y = y, z = z }

    return {
        area_id = safeGetLevelName(),
        position = { x, y, z },
        orientation = { rot.Pitch, rot.Yaw, rot.Roll },
        anim = anim,
    }
end

local function encodeLocalState(state)
    return string.format(
        '{"type":"local_state","payload":{"state":{"area_id":%s,"position":[%s,%s,%s],"orientation":[%s,%s,%s],"anim":%s}}}',
        jsonString(state.area_id),
        tostring(state.position[1]), tostring(state.position[2]), tostring(state.position[3]),
        tostring(state.orientation[1]), tostring(state.orientation[2]), tostring(state.orientation[3]),
        jsonString(state.anim))
end

local ENCODED_NO_SEND = '{"type":"local_state","payload":{"state":null}}'

----------------------------------------------------------------------------
-- Remote handling -- render_remote/despawn_remote, per adapters/_template/PROTOCOL.md.
----------------------------------------------------------------------------

-- DIAG (2026-08-12): send counters came back 100% ok (0 timeouts/errors across 500 sends), yet
-- render_remote arrived at roughly 0.5Hz instead of the ~10Hz local_state sends should produce --
-- fewer than 20 render_remote messages were counted in an entire ~50s run. That rules out the
-- outgoing socket write path; these counters check the raw receive side directly, before any
-- parsing, so "bytes genuinely aren't arriving" can be told apart from "bytes arrive but don't
-- decode/match as expected."
local recvLineCount = 0
local recvDecodeFailCount = 0
local recvUnknownTypeCount = 0
local MAX_LOGGED_DECODE_FAILURES = 5 -- DIAG (2026-08-12): 488/498 raw lines failed to decode in
    -- the last run -- need to see actual failing text, not just the count, to know why.

local function handleBridgeLine(line)
    recvLineCount = recvLineCount + 1
    local env = jsonDecode(line)
    if not env or type(env) ~= "table" then
        recvDecodeFailCount = recvDecodeFailCount + 1
        if recvDecodeFailCount <= MAX_LOGGED_DECODE_FAILURES then
            -- DIAG (2026-08-12): the plain-text version of this log truncated hard right after
            -- "playe" for failure #1 and printed as fully blank for #2-5, all while #line still
            -- correctly reported 322 bytes -- the exact signature of an embedded NUL (or other
            -- unprintable byte) hitting a C-string-based print sink, since Lua strings are
            -- length-prefixed and handle embedded NULs fine but the underlying UE4SS console
            -- likely doesn't. Hex dump instead so the actual bytes are visible regardless.
            -- string.byte(line, idx) with only one index sometimes returned no value at all on
            -- this build (threw "bad argument #2 to 'format' (no value)", which -- before this
            -- pcall wrap was added -- aborted the rest of this tick's message processing
            -- entirely, including the ghost-spawn check, explaining a run where nothing spawned
            -- at all). Explicit (idx, idx) range plus a fallback marker so a real gap is visible
            -- instead of throwing; the whole block is pcall-wrapped so any further logging bug
            -- can never again take real message handling down with it.
            local dumpOk, dumpErr = pcall(function()
                local hexParts = {}
                for idx = 1, #line do
                    local b = string.byte(line, idx, idx)
                    if b then
                        table.insert(hexParts, string.format("%02X", b))
                    else
                        table.insert(hexParts, "??")
                    end
                end
                print(string.format("[MeshGhostGhostProbe] DIAG: decode failure #%d, raw line len=%d, hex: %s\n",
                    recvDecodeFailCount, #line, table.concat(hexParts, " ")))
            end)
            if not dumpOk then
                print(string.format("[MeshGhostGhostProbe] DIAG: decode failure #%d, hex dump itself failed: %s\n",
                    recvDecodeFailCount, tostring(dumpErr)))
            end
        end
        return
    end

    if env.type == "render_remote" then
        local payload = env.payload
        if type(payload) ~= "table" or type(payload.state) ~= "table" or not payload.player_id then
            return
        end
        local st = payload.state
        local pos = st.position
        if type(pos) ~= "table" or not pos[1] or not pos[2] or not pos[3] then
            return
        end
        local remote = remotes[payload.player_id]
        if not remote then
            remote = { ghost = nil, spawning = false, spawnAttemptTick = nil, loggedFirstRender = false, renderCount = 0 }
            remotes[payload.player_id] = remote
        end
        if not remote.loggedFirstRender then
            remote.loggedFirstRender = true
            print(string.format("[MeshGhostGhostProbe] DIAG: first render_remote for %s, position=(%.1f, %.1f, %.1f)\n",
                payload.player_id, pos[1], pos[2], pos[3]))
        end
        -- DIAG (2026-08-12): logged at the same throttle as redrawRemote's target/actual log, so
        -- the two can be lined up to tell "the network data itself arrives in jumps" apart from
        -- "the redraw isn't applying smoothly-arriving data smoothly."
        remote.renderCount = remote.renderCount + 1
        if remote.renderCount % REDRAW_LOG_INTERVAL_TICKS == 0 then
            print(string.format("[MeshGhostGhostProbe] DIAG: remote %s render_remote #%d, position=(%.1f, %.1f, %.1f)\n",
                payload.player_id, remote.renderCount, pos[1], pos[2], pos[3]))
        end
        remote.state = st
    elseif env.type == "despawn_remote" then
        local payload = env.payload
        if type(payload) == "table" and payload.player_id and remotes[payload.player_id] then
            local remote = remotes[payload.player_id]
            if remote.ghost ~= nil and remote.ghost:IsValid() then
                local destroyOk = pcall(function() remote.ghost:K2_DestroyActor() end)
                if not destroyOk then
                    pcall(function()
                        local loc = remote.ghost:K2_GetActorLocation()
                        loc.Z = loc.Z - 1000000.0
                        remote.ghost:K2_SetActorLocationAndRotation(loc, remote.ghost:K2_GetActorRotation(), false, {}, false)
                    end)
                end
            end
            remotes[payload.player_id] = nil
        end
    else
        recvUnknownTypeCount = recvUnknownTypeCount + 1
    end
end

local function drainBridge()
    while true do
        local line, err = sock:receive()
        if line then
            handleBridgeLine(line)
        elseif err == "timeout" then
            return
        else
            resetBridge()
            return
        end
    end
end

----------------------------------------------------------------------------
-- Camera-fight-back hook -- confirmed live and working in Phase 7.4
-- (agent_docs/phases/phase7.md, agent_docs/verified.md). Gated on `anyGhostSpawned` instead of
-- 7.4's single `ghost` variable, since 7.5 can have any number of remote ghosts.
----------------------------------------------------------------------------

local anyGhostSpawned = false
local lastKnownGoodViewTarget = nil

local function tryHookCameraCalls()
    local svtwbOk, svtwbErr = pcall(function()
        RegisterHook("/Script/Engine.PlayerController:SetViewTargetWithBlend",
            function(Context, NewViewTarget)
                local ctx = Context:get()
                local target = NewViewTarget:get()
                print(string.format(
                    "[MeshGhostGhostProbe] HOOK: SetViewTargetWithBlend called on %s -> NewViewTarget=%s\n",
                    (ctx ~= nil and ctx:IsValid()) and ctx:GetFullName() or "nil/invalid",
                    (target ~= nil and target:IsValid()) and target:GetFullName() or "nil/invalid"))
            end,
            function(Context, NewViewTarget)
                local ctxOk, ctx = pcall(function() return Context:get() end)
                local targetOk, target = pcall(function() return NewViewTarget:get() end)
                if not ctxOk or not targetOk or ctx == nil or not ctx:IsValid() or target == nil or not target:IsValid() then
                    return
                end

                if not anyGhostSpawned then
                    lastKnownGoodViewTarget = target
                    return
                end

                if lastKnownGoodViewTarget == nil or not lastKnownGoodViewTarget:IsValid() then
                    -- Confirmed live 2026-08-12: a level transition destroys the previous area's
                    -- camera rig, invalidating lastKnownGoodViewTarget permanently -- this branch
                    -- used to just give up here forever, which is exactly why the camera stayed
                    -- stuck on the ghost after the very next area change (nothing ever fought
                    -- back again for the rest of the session). The first SetViewTargetWithBlend
                    -- call after a transition, before any ghost has re-spawned in the new area,
                    -- is the game's own legitimate choice -- re-baseline on it instead of
                    -- silently disabling the fight-back mechanism.
                    print(string.format(
                        "[MeshGhostGhostProbe] HOOK: lastKnownGoodViewTarget was stale/invalid, re-baselining to %s\n",
                        target:GetFullName()))
                    lastKnownGoodViewTarget = target
                    return
                end

                if target:GetAddress() == lastKnownGoodViewTarget:GetAddress() then
                    return
                end

                print(string.format(
                    "[MeshGhostGhostProbe] HOOK: FIGHTING BACK -- ghost exists and target changed to %s, forcing back to %s\n",
                    target:GetFullName(), lastKnownGoodViewTarget:GetFullName()))
                local restoreTarget = lastKnownGoodViewTarget
                ExecuteInGameThread(function()
                    if not restoreTarget:IsValid() or not ctx:IsValid() then
                        return
                    end
                    local fightOk, fightErr = pcall(function()
                        ctx:SetViewTargetWithBlend(restoreTarget, 0.0, 0, 0.0, false)
                    end)
                    print(string.format("[MeshGhostGhostProbe] HOOK: SetViewTargetWithBlend override: %s\n",
                        fightOk and "ok" or ("FAILED: " .. tostring(fightErr))))
                end)
            end)
    end)
    print(string.format("[MeshGhostGhostProbe] HOOK: registered SetViewTargetWithBlend hook: %s\n",
        svtwbOk and "ok" or ("FAILED: " .. tostring(svtwbErr))))
end

----------------------------------------------------------------------------
-- Remote ghost spawn + per-tick reposition -- same proven mechanism as Phase 7.4, driven by a
-- remote's received position/orientation instead of a local offset.
----------------------------------------------------------------------------

-- remote.spawning guards against a second SpawnActor firing before the first's
-- ExecuteInGameThread callback has run (same race 7.4 found and fixed). DIAG (2026-08-12): 7.4's
-- own history already found an error inside an ExecuteInGameThread callback escapes the caller's
-- pcall -- if that ever happened here before the callback cleared remote.spawning, it would wedge
-- true forever with nothing logged, silently blocking every future spawn attempt for this remote.
-- The whole callback body is now pcall-wrapped so a throw can't skip the clear, and
-- remote.spawnAttemptTick backstops even a callback that never runs at all (see tick()'s timeout
-- check).
local function trySpawnRemoteGhost(playerId, remote, pawn, controller, world, tickNow)
    remote.spawning = true
    remote.spawnAttemptTick = tickNow
    local pos = remote.state.position
    local dist = math.sqrt(pos[1] * pos[1] + pos[2] * pos[2] + pos[3] * pos[3])
    if dist < MIN_PLAUSIBLE_DISTANCE then
        remote.spawning = false
        print(string.format("[MeshGhostGhostProbe] DIAG: remote %s: skipping spawn, distance %.1f < MIN_PLAUSIBLE_DISTANCE %.1f\n",
            playerId, dist, MIN_PLAUSIBLE_DISTANCE))
        return
    end

    ExecuteInGameThread(function()
        local bodyOk, bodyErr = pcall(function()
            local classOk, pawnClass = pcall(function() return pawn:GetClass() end)
            if not classOk or pawnClass == nil or not pawnClass:IsValid() then
                print("[MeshGhostGhostProbe] pawn:GetClass() FAILED.\n")
                return
            end
            local loc = pawn:K2_GetActorLocation() -- spawn location doesn't matter much (repositioned
            local rot = pawn:K2_GetActorRotation() -- immediately below), but must be a real, placed
                                                    -- transform -- reusing the local pawn's, per 7.4.
            local ghost = world:SpawnActor(pawnClass, loc, rot)
            if ghost == nil or not ghost:IsValid() then
                print(string.format("[MeshGhostGhostProbe] remote %s: SpawnActor returned nil/invalid.\n", playerId))
                return
            end
            remote.ghost = ghost
            anyGhostSpawned = true
            print(string.format("[MeshGhostGhostProbe] remote %s: ghost spawned.\n", playerId))

            -- Same auto-possession fix as 7.4 -- BP_PlayerGoatMain_C auto-possesses on spawn.
            local possessOk = pcall(function() controller:Possess(pawn) end)
            print(string.format("[MeshGhostGhostProbe] remote %s: re-possess original pawn: %s\n",
                playerId, possessOk and "ok" or "FAILED"))

            local cameraComponentClass = StaticFindObject("/Script/Engine.CameraComponent")
            pcall(function()
                local ghostCamera = ghost:GetComponentByClass(cameraComponentClass)
                if ghostCamera ~= nil and ghostCamera:IsValid() then
                    ghostCamera.bIsActive = false
                end
            end)

            local collisionOk = pcall(function() ghost:SetActorEnableCollision(false) end)
            print(string.format("[MeshGhostGhostProbe] remote %s: SetActorEnableCollision(false): %s\n",
                playerId, collisionOk and "ok" or "FAILED"))
        end)
        remote.spawning = false
        if not bodyOk then
            print(string.format("[MeshGhostGhostProbe] DIAG: remote %s: spawn callback threw: %s\n",
                playerId, tostring(bodyErr)))
        end
    end)
end

-- redrawRemote applies remote.state's position/orientation to remote.ghost, per
-- PROTOCOL.md's "redraw every entry currently in the remote-ghost map, unconditionally" rule --
-- called every tick regardless of whether a new render_remote arrived this tick.
local function redrawRemote(playerId, remote, tickNow)
    if remote.ghost == nil or not remote.ghost:IsValid() then
        return
    end
    local pos = remote.state.position
    local ori = remote.state.orientation
    local targetX, targetY, targetZ = pos[1], pos[2], pos[3]
    local shouldLog = (tickNow % REDRAW_LOG_INTERVAL_TICKS == 0)

    ExecuteInGameThread(function()
        -- Confirmed live 2026-08-12: by the time this deferred callback runs, a level transition
        -- can already have nil'd remote.ghost out from under us (tick()'s respawn-detection
        -- clears it once invalid). `nil:IsValid()` is a hard Lua error, not "invalid" -- crashed
        -- with "attempt to index a nil value (field 'ghost')" right at a transition, aborting the
        -- callback mid-flight.
        if remote.ghost == nil or not remote.ghost:IsValid() then
            return
        end
        -- Mutate a struct owned by the ghost itself, never one read from elsewhere --
        -- K2_GetActorLocation()/K2_GetActorRotation() appear to return live references into the
        -- actor's own transform, not detached copies (found the hard way in 7.4).
        local ghostLoc = remote.ghost:K2_GetActorLocation()
        ghostLoc.X, ghostLoc.Y, ghostLoc.Z = targetX, targetY, targetZ
        local ghostRot = remote.ghost:K2_GetActorRotation()
        if ori ~= nil and ori[1] ~= nil and ori[2] ~= nil and ori[3] ~= nil then
            ghostRot.Pitch, ghostRot.Yaw, ghostRot.Roll = ori[1], ori[2], ori[3]
        end
        remote.ghost:K2_SetActorLocationAndRotation(ghostLoc, ghostRot, false, {}, false)

        if shouldLog then
            local actual = remote.ghost:K2_GetActorLocation() -- genuinely separate read, not ghostLoc
            print(string.format(
                "[MeshGhostGhostProbe] DIAG: remote %s redraw: target=(%.1f,%.1f,%.1f) actual=(%.1f,%.1f,%.1f)\n",
                playerId, targetX, targetY, targetZ, actual.X, actual.Y, actual.Z))
        end
    end)
end

----------------------------------------------------------------------------
-- Main tick. Adapter always drives (agent_docs/contract.md's tick model): try to connect if
-- needed, send hello once per fresh connection, send local_state every tick (nil included),
-- drain render_remote/despawn_remote, then redraw every known remote unconditionally.
----------------------------------------------------------------------------

local function safeGetPawn()
    local ok, controller = pcall(UEHelpers.GetPlayerController)
    if not ok or controller == nil or not controller:IsValid() then
        return nil, nil, "no valid PlayerController yet"
    end
    local pawn = controller.Pawn
    if pawn == nil or not pawn:IsValid() then
        return nil, controller, "PlayerController has no valid Pawn yet"
    end
    return pawn, controller, nil
end

local lastLoggedState = nil
local tickCounter = 0

-- DIAG (2026-08-12): a run with identical code to a run that spawned a ghost still failed to
-- spawn one, and the log gave no clue why -- no error, no partial progress, nothing between
-- "hello sent" and the run ending. HEARTBEAT_INTERVAL_TICKS makes the tick loop self-report so the
-- next run can't be silent the same way: proves the loop is still alive, and shows exactly which
-- branch (no remotes known yet vs. known-but-not-spawned vs. spawned-but-not-redrawing) it's
-- sitting in. SPAWN_TIMEOUT_TICKS backstops trySpawnRemoteGhost's own pcall in case
-- ExecuteInGameThread's callback is silently dropped by the engine and never runs at all (the one
-- failure mode the callback's own pcall can't catch, since it never executes).
local HEARTBEAT_INTERVAL_TICKS = 50 -- ~5s at FOLLOW_INTERVAL_MS=100
local SPAWN_TIMEOUT_TICKS = 20 -- ~2s at FOLLOW_INTERVAL_MS=100

local function logHeartbeat(pawnErr)
    local remoteCount = 0
    local parts = {}
    for playerId, remote in pairs(remotes) do
        remoteCount = remoteCount + 1
        table.insert(parts, string.format("%s(ghost=%s,spawning=%s)",
            playerId, tostring(remote.ghost ~= nil and remote.ghost:IsValid()), tostring(remote.spawning)))
    end
    print(string.format("[MeshGhostGhostProbe] DIAG: heartbeat tick=%d connected=%s pawn=%s remotes=%d %s sends(calls=%d ok=%d timeout=%d error=%d) recv(lines=%d decodeFail=%d unknownType=%d)\n",
        tickCounter, tostring(connected), pawnErr == nil and "valid" or tostring(pawnErr),
        remoteCount, table.concat(parts, " "),
        sendCallCount, sendOkCount, sendTimeoutCount, sendOtherErrorCount,
        recvLineCount, recvDecodeFailCount, recvUnknownTypeCount))
end

local function tickBody()
    tickCounter = tickCounter + 1

    if not connected then
        connectBridge()
        if connected then
            print("[MeshGhostGhostProbe] connected to bridge.\n")
        end
    end

    local pawn, controller, pawnErr = safeGetPawn()

    if connected then
        -- Safety backstop from 7.4: if controller.Pawn is ever one of our own ghosts (e.g. a
        -- future auto-possess regression), don't send its position as if it were the real
        -- player's local state.
        local pawnIsGhost = false
        if pawn ~= nil then
            for _, remote in pairs(remotes) do
                if remote.ghost ~= nil and remote.ghost:IsValid() and pawn:GetAddress() == remote.ghost:GetAddress() then
                    pawnIsGhost = true
                    break
                end
            end
        end

        if not helloSent then
            sendLine(string.format('{"type":"hello","payload":{"game_id":%s}}', jsonString(GAME_ID)))
            helloSent = true
            print("[MeshGhostGhostProbe] hello sent.\n")
        end

        if pawn ~= nil and not pawnIsGhost then
            local ok, state = pcall(getLocalState, pawn)
            if ok and state ~= nil then
                sendLine(encodeLocalState(state))
            else
                sendLine(ENCODED_NO_SEND)
            end
        else
            sendLine(ENCODED_NO_SEND)
        end

        if connected then
            drainBridge()
        end

        for playerId, remote in pairs(remotes) do
            -- A level transition destroys the spawned actor out from under us (confirmed live
            -- 2026-08-12: the ghost never came back after ZONE_LowerCastle -> ZONE_Dungeon ->
            -- ZONE_LowerCastle). remote.ghost otherwise stays a stale non-nil reference forever,
            -- so the spawn check below never re-fires -- clear it once it's no longer valid.
            if remote.ghost ~= nil and not remote.ghost:IsValid() then
                remote.ghost = nil
            end

            if remote.spawning and remote.spawnAttemptTick ~= nil
                and (tickCounter - remote.spawnAttemptTick) > SPAWN_TIMEOUT_TICKS then
                print(string.format("[MeshGhostGhostProbe] DIAG: remote %s: spawn attempt timed out after %d ticks, clearing.\n",
                    playerId, SPAWN_TIMEOUT_TICKS))
                remote.spawning = false
            end

            if remote.state ~= nil then
                if remote.ghost == nil then
                    if not remote.spawning and pawn ~= nil and not pawnIsGhost then
                        local worldOk, world = pcall(UEHelpers.GetWorld)
                        if worldOk and world ~= nil and world:IsValid() then
                            trySpawnRemoteGhost(playerId, remote, pawn, controller, world, tickCounter)
                        end
                    end
                else
                    redrawRemote(playerId, remote, tickCounter)
                end
            end
        end
    else
        if lastLoggedState ~= "disconnected" then
            print(string.format("[MeshGhostGhostProbe] not connected (pawn: %s)\n", tostring(pawnErr)))
            lastLoggedState = "disconnected"
        end
    end

    if connected and lastLoggedState ~= "connected" then
        lastLoggedState = "connected"
    end

    if tickCounter % HEARTBEAT_INTERVAL_TICKS == 0 then
        logHeartbeat(pawnErr)
    end
end

local lastLoggedTickError = nil

local function tick()
    local ok, err = pcall(tickBody)
    if not ok then
        local errText = tostring(err)
        if errText ~= lastLoggedTickError then
            print(string.format("[MeshGhostGhostProbe] DIAG: tick() threw: %s\n", errText))
            lastLoggedTickError = errText
        end
    end
    return false -- keep looping
end

tryHookCameraCalls()

print("[MeshGhostGhostProbe] Phase 7.5 real adapter running -- connecting to bridge at " .. BRIDGE_HOST .. ":" .. BRIDGE_PORT .. " ...\n")
LoopAsync(FOLLOW_INTERVAL_MS, tick)
