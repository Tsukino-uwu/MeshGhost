-- MeshGhost INPUT GATE (2026-09-09): READ-ONLY, on the PLAYER's own pawn, hot-loaded over the
-- scratch slot. The driven ghost feeds the recorded stick through the engine's `AddMovementInput`
-- every frame (its Blueprint's Move handler reads the BOUND stick, zero on a clone). During a wall
-- cling that input is not gated by anything: the wall blocks it, and the pawn slides along and UP
-- the wall at run speed (`snap_watch.lua`, 12:15: vel (0,984,89), +80 units/s of height, a 150-unit
-- correction every 0.4 s) while the recording slides down. The player's Blueprint decides per
-- state whether the stick reaches the movement component at all. This measures that decision:
-- every 50 ms, the player's `moveState`, `actionState`, `hasMovementInput?`, `moveInputAmount`, the
-- length of the engine's `GetLastMovementInputVector` (what actually reached the movement
-- component last frame) and the speed -- logged on every change of the (moveState, actionState,
-- stick held, input passed) tuple. The set of states where "stick held, nothing passed" is the
-- gate the ghost has to copy. Named reads and native getters only; nothing written, nothing called
-- that changes state.

local TAG = "[MeshGhostInputGate]"

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end
local function log(line) print(TAG .. " " .. line .. "\n") end

local function player_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn = prop(pc, field)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end
local function vlen(v)
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if type(x) ~= "number" then return nil end
    return math.sqrt(x * x + y * y + (z or 0) * (z or 0))
end

local last_key = nil
local t_start = os.clock()
-- Per (moveState) tallies: ticks with the stick held, and of those, ticks where input passed.
local tally = {}
local ticks = 0
log("loaded -- watching the PLAYER: which move states let the stick through to the movement component. Do the route: cling, wall run, jump, slide, attack.")

LoopAsync(50, function()
    ticks = ticks + 1
    local me = player_pawn()
    if not me then return false end
    local ms = tostring(prop(me, "moveState"))
    local as = tostring(prop(me, "actionState"))
    local held = prop(me, "hasMovementInput?") == true
    local amount = tonumber(prop(me, "moveInputAmount")) or 0
    local passed_len = nil
    pcall(function() passed_len = vlen(me:GetLastMovementInputVector()) end)
    local passed = (passed_len or 0) > 0.01
    local speed = nil
    pcall(function() speed = vlen(me:GetVelocity()) end)
    if held then
        tally[ms] = tally[ms] or { held = 0, passed = 0 }
        tally[ms].held = tally[ms].held + 1
        if passed then tally[ms].passed = tally[ms].passed + 1 end
    end
    local key = ms .. "/" .. as .. "/" .. tostring(held) .. "/" .. tostring(passed)
    if key ~= last_key then
        log(string.format("t=%6.2f moveState=%s actionState=%s stick_held=%s amount=%.2f passed=%s (|last input|=%.2f) speed=%.0f",
            os.clock() - t_start, ms, as, tostring(held), amount, tostring(passed), passed_len or -1, speed or -1))
        last_key = key
    end
    if ticks % 200 == 0 then
        local parts = {}
        for k, v in pairs(tally) do parts[#parts + 1] = string.format("moveState %s: stick held %d ticks, passed %d", k, v.held, v.passed) end
        table.sort(parts)
        log("TALLY -- " .. table.concat(parts, "; "))
    end
    return false
end)
