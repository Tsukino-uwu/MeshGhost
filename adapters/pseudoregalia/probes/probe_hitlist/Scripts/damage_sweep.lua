-- Damage sweep, and it calls a function on the player meant to hurt: BPI_PerformDamageResponse on the player's own pawn
-- for each type in TYPES, logging both health locations (the game instance's and the pawn's own BP_HpHitable) at
-- +0/100/500/1000/2500 ms. Stops below HP_FLOOR, touches only the local player, writes nothing; unload it afterwards.
-- Types 2 and 3 crashed the game inside the call (an access violation no pcall catches) and TYPES still starts at 3:
-- never run it as written. Types 0 and 1 are a reaction only and move no HP.

local TAG = "[MeshGhostDamageSweep]"
local START_DELAY_S = 10        -- time to get somewhere safe before the first call
local GAP_S = 8                 -- between phases; long enough for i-frames to lapse
-- 0 and 1 are done and 2 is left out; 3, the first here, crashed the game too.
local TYPES = { 3, 4, 5, 6, 7 }
local HP_FLOOR = 25.0           -- stop rather than risk a death mid-sweep
local READ_OFFSETS_MS = { 0, 100, 500, 1000, 2500 }

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../damagesweep-" .. os.date("%H%M%S") .. ".log"
local out = io.open(OUT_PATH, "a")
local function log(line) print(TAG .. " " .. line .. "\n") end
local function fout(line) if out then out:write(line, "\n"); out:flush() end end
local function say(line) log(line); fout(line) end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function num(obj, name)
    local v
    local ok = pcall(function() v = obj[name] end)
    if not ok or v == nil then return nil end
    if type(v) == "userdata" then
        local got
        if pcall(function() got = v:get() end) and type(got) == "number" then return got end
        return nil
    end
    if type(v) == "number" then return v end
    return nil
end

local function player_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn
                pcall(function() pawn = pc[field] end)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end

-- Read through the game's own refs each time, never cached: a transition makes a new pawn.
local function read_hp(pawn)
    local gi_hp, own_hp, max_hp
    local gi
    pcall(function() gi = pawn["As MV Game Instance Ref"] end)
    if gi ~= nil and valid(gi) then gi_hp = num(gi, "CurrentHp") end
    local ref
    pcall(function() ref = pawn.BP_HpHitable end)
    if ref ~= nil and valid(ref) then
        own_hp = num(ref, "CurrentHp")
        max_hp = num(ref, "maxHP")
    end
    return gi_hp, own_hp, max_hp
end

local function hp_str(gi_hp, own_hp, max_hp)
    return string.format("gi=%s own=%s/%s",
        tostring(gi_hp), tostring(own_hp), tostring(max_hp))
end

-- UE4SS Lua demands the exact arity, so attackDirection is passed in each plausible form and the accepted one
-- reported. Accepted is not proof of the real layout: a guessed struct is an access violation no pcall catches.
local ARG_FORMS = {
    { name = "number 0 (byte/enum/float)", make = function() return 0 end },
    { name = "FVector table", make = function() return { X = 0.0, Y = 0.0, Z = 0.0 } end },
    { name = "FRotator table", make = function() return { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } end },
}
local arg_form = nil    -- latched to whichever form first works, so the sweep stays one variable

local function call_damage_response(pawn, damage_type)
    if arg_form ~= nil then
        local ok, err = pcall(function() pawn:BPI_PerformDamageResponse(damage_type, arg_form.make()) end)
        if ok then return true, nil end
        return false, tostring(err)
    end
    local errors = {}
    for _, form in ipairs(ARG_FORMS) do
        local ok, err = pcall(function() pawn:BPI_PerformDamageResponse(damage_type, form.make()) end)
        if ok then
            arg_form = form
            say("ARG FORM accepted: attackDirection as " .. form.name)
            return true, nil
        end
        errors[#errors + 1] = form.name .. " -> " .. tostring(err)
    end
    return false, table.concat(errors, " | ")
end

local phase = 0                 -- 0 = countdown, then one per entry in TYPES
local t_phase = os.clock()
local pending = nil             -- an in-flight call's readback schedule
local resolved_once = false
local stopped = false

say("loaded " .. os.date("%H:%M:%S") .. " -- CALLS BPI_PerformDamageResponse ON THE PLAYER.")
say("first call in " .. START_DELAY_S .. "s; " .. #TYPES .. " types, " .. GAP_S .. "s apart; stops below "
    .. HP_FLOOR .. " HP. Full log: " .. OUT_PATH)

LoopAsync(100, function()
    if stopped then return true end
    local me = player_pawn()
    if me == nil then return false end

    -- Once, whether the function resolves at all, so "nothing happened" is never a missing name.
    if not resolved_once then
        resolved_once = true
        local fn
        pcall(function() fn = me:GetFunctionByNameInChain("BPI_PerformDamageResponse") end)
        if fn == nil then
            pcall(function() fn = me.BPI_PerformDamageResponse end)
        end
        say("COVERAGE: BPI_PerformDamageResponse on the player resolves = " .. tostring(fn ~= nil)
            .. "; pawn class " .. tostring(select(2, pcall(function() return me:GetClass():GetFName():ToString() end))))
        local gi_hp, own_hp, max_hp = read_hp(me)
        say("COVERAGE: baseline HP " .. hp_str(gi_hp, own_hp, max_hp))
    end

    if pending ~= nil then
        local elapsed_ms = (os.clock() - pending.t0) * 1000
        while pending.next <= #READ_OFFSETS_MS and elapsed_ms >= READ_OFFSETS_MS[pending.next] do
            local gi_hp, own_hp, max_hp = read_hp(me)
            say(string.format("  type=%d +%dms %s (delta gi=%s own=%s)",
                pending.damage_type, READ_OFFSETS_MS[pending.next], hp_str(gi_hp, own_hp, max_hp),
                (gi_hp and pending.gi0) and string.format("%.1f", gi_hp - pending.gi0) or "?",
                (own_hp and pending.own0) and string.format("%.1f", own_hp - pending.own0) or "?"))
            pending.next = pending.next + 1
        end
        if pending.next > #READ_OFFSETS_MS then
            pending = nil
            t_phase = os.clock()
        end
        return false
    end

    local waited = os.clock() - t_phase
    if phase == 0 then
        if waited >= START_DELAY_S then
            phase = 1
            t_phase = os.clock()
        elseif math.floor(waited) ~= math.floor(waited - 0.1) then
            log(string.format("starting in %ds...", math.max(0, math.ceil(START_DELAY_S - waited))))
        end
        return false
    end

    if phase > #TYPES then
        say("done -- every type tried. UNLOAD THIS PROBE (restore probe_scratch's stub).")
        if out then out:close(); out = nil end
        stopped = true
        return true
    end

    if waited < GAP_S then return false end

    local damage_type = TYPES[phase]
    local gi0, own0, max0 = read_hp(me)
    local floor_value = gi0 or own0
    if floor_value ~= nil and floor_value <= HP_FLOOR then
        say(string.format("STOPPING at type=%d: HP %s is at or below the %.1f floor -- heal or reload, then reload this probe.",
            damage_type, tostring(floor_value), HP_FLOOR))
        if out then out:close(); out = nil end
        stopped = true
        return true
    end

    say(string.format("CALL type=%d before %s", damage_type, hp_str(gi0, own0, max0)))
    local ok, err = call_damage_response(me, damage_type)
    if not ok then
        say(string.format("  type=%d CALL FAILED: %s -- the Lua call path is the problem, not the game",
            damage_type, tostring(err)))
        phase = phase + 1
        t_phase = os.clock()
        return false
    end
    pending = { damage_type = damage_type, t0 = os.clock(), next = 1, gi0 = gi0, own0 = own0 }
    phase = phase + 1
    return false
end)
