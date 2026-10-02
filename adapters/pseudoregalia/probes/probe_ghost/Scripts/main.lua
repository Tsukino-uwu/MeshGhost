-- The complete Lua adapter the C++ mod superseded: local state over the bridge with the vendored LuaSocket, each
-- remote a clone of the player's pawn. Its SetViewTargetWithBlend hook blocks every later camera change: never copy it.
-- The vendored LuaSocket corrupts most received lines under sustained traffic, so a ghost here cannot follow smoothly.
-- Deploy as ue4ss\Mods\MeshGhostGhostProbe\Scripts\main.lua, add "MeshGhostGhostProbe : 1" to mods.txt, and start
-- dev-scripts\run-relay-loopback.bat and run-core.bat pseudoregalia first: the loopback relay echoes this client back.

local UEHelpers = require("UEHelpers")

local GAME_ID = "pseudoregalia"
local BRIDGE_HOST = "127.0.0.1"
local BRIDGE_PORT = 7778
local FOLLOW_INTERVAL_MS = 100
local MIN_PLAUSIBLE_DISTANCE = 100.0 -- nearer the origin than this, a transform is not placed yet
-- The redraw logs the target beside a separate post-write read: a log of what was written proves nothing.
local REDRAW_LOG_INTERVAL_TICKS = 20 -- ~2s at FOLLOW_INTERVAL_MS=100
-- No per-tick distance guard: a remote position comes straight off the wire, and real moves jump far in one tick.

-- Vendored LuaSocket.

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

-- Minimal JSON.

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

-- Bridge connection.

local sock = nil
local connected = false
local helloSent = false
local remotes = {} -- player_id -> { state = {...}, ghost = AActor|nil, spawning = bool }

local function despawnAllRemotes()
    for playerId, remote in pairs(remotes) do
        if remote.ghost ~= nil and remote.ghost:IsValid() then
            local destroyOk = pcall(function() remote.ghost:K2_DestroyActor() end)
            if not destroyOk then
                -- Hidden far away if the destroy throws; on this build it has been seen to no-op silently instead.
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

-- A non-blocking send can return nil, "timeout" for a line that never went, so the heartbeat counts each outcome.
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

-- Local state: position in cm, full [pitch, yaw, roll], the level name as area_id, and an anim placeholder from the
-- position delta; no valid controller sends null.

local lastLocalPos = nil -- {x, y, z} of the previous tick, for the anim-speed inference
local localTickCount = 0
local RUNNING_SPEED_THRESHOLD = 5.0 -- cm per tick: a placeholder, not a measured movement constant

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
    -- area_id only has to be stable per level, so the short map name, or the full name if the shape differs.
    local short = name:match("([%w_]+)%.[%w_]+:PersistentLevel")
    return short or name
end

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

-- Remote handling: render_remote and despawn_remote. Lines are counted before any parsing, so lines that never arrive
-- and lines that arrive and do not decode can be told apart.
local recvLineCount = 0
local recvDecodeFailCount = 0
local recvUnknownTypeCount = 0
local MAX_LOGGED_DECODE_FAILURES = 5

local function handleBridgeLine(line)
    recvLineCount = recvLineCount + 1
    local env = jsonDecode(line)
    if not env or type(env) ~= "table" then
        recvDecodeFailCount = recvDecodeFailCount + 1
        if recvDecodeFailCount <= MAX_LOGGED_DECODE_FAILURES then
            -- Hex, because the UE4SS console truncates at an unprintable byte. string.byte with one index sometimes
            -- returned nothing here, hence the explicit range, the "??" marker and the pcall.
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
        -- Same throttle as the redraw's target/actual log, so the two line up.
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

-- Camera fight-back hook, armed once any ghost has spawned.

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
                    -- A transition destroys the old rig; the game's first choice after it is legitimate: re-baseline.
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

-- Remote ghost spawn and per-tick reposition.

-- remote.spawning stops a second SpawnActor before the first callback runs. An error in an ExecuteInGameThread callback
-- escapes the caller's pcall, so the body has its own; spawnAttemptTick covers a callback that never runs.
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
            local loc = pawn:K2_GetActorLocation() -- any placed transform will do: repositioned next tick
            local rot = pawn:K2_GetActorRotation()
            local ghost = world:SpawnActor(pawnClass, loc, rot)
            if ghost == nil or not ghost:IsValid() then
                print(string.format("[MeshGhostGhostProbe] remote %s: SpawnActor returned nil/invalid.\n", playerId))
                return
            end
            remote.ghost = ghost
            anyGhostSpawned = true
            print(string.format("[MeshGhostGhostProbe] remote %s: ghost spawned.\n", playerId))

            -- BP_PlayerGoatMain_C auto-possesses on spawn.
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

-- Called every tick for every remote, whether or not a render_remote arrived.
local function redrawRemote(playerId, remote, tickNow)
    if remote.ghost == nil or not remote.ghost:IsValid() then
        return
    end
    local pos = remote.state.position
    local ori = remote.state.orientation
    local targetX, targetY, targetZ = pos[1], pos[2], pos[3]
    local shouldLog = (tickNow % REDRAW_LOG_INTERVAL_TICKS == 0)

    ExecuteInGameThread(function()
        -- A transition can nil remote.ghost before this deferred callback runs, and nil:IsValid() raises.
        if remote.ghost == nil or not remote.ghost:IsValid() then
            return
        end
        -- Mutate only the ghost's own struct: K2_GetActorLocation/Rotation appear to return live references.
        local ghostLoc = remote.ghost:K2_GetActorLocation()
        ghostLoc.X, ghostLoc.Y, ghostLoc.Z = targetX, targetY, targetZ
        local ghostRot = remote.ghost:K2_GetActorRotation()
        if ori ~= nil and ori[1] ~= nil and ori[2] ~= nil and ori[3] ~= nil then
            ghostRot.Pitch, ghostRot.Yaw, ghostRot.Roll = ori[1], ori[2], ori[3]
        end
        remote.ghost:K2_SetActorLocationAndRotation(ghostLoc, ghostRot, false, {}, false)

        if shouldLog then
            local actual = remote.ghost:K2_GetActorLocation() -- a separate read, not ghostLoc
            print(string.format(
                "[MeshGhostGhostProbe] DIAG: remote %s redraw: target=(%.1f,%.1f,%.1f) actual=(%.1f,%.1f,%.1f)\n",
                playerId, targetX, targetY, targetZ, actual.X, actual.Y, actual.Z))
        end
    end)
end

-- Main tick: connect if needed, hello once per connection, local_state every tick (null included), drain, redraw.

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

-- The heartbeat shows the loop is alive and which branch each remote sits in; SPAWN_TIMEOUT_TICKS clears a spawn
-- whose callback never ran.
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
        -- If controller.Pawn is ever one of our ghosts, its position is not the player's.
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
            -- A transition destroys the ghost; clearing the stale reference lets the spawn below re-fire.
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
