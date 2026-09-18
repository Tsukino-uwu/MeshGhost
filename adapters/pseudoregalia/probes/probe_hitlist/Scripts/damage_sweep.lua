-- MeshGhost DAMAGE SWEEP (written 2026-09-18): **THIS ONE CALLS A FUNCTION ON THE PLAYER, AND IT
-- IS MEANT TO HURT YOU.** Part B of agent_docs/chaser-planning.md: find what an enemy actually does
-- to lower the player's HP, so chaser contact "hurt"/"kill" can trigger the game's own path instead
-- of inventing one.
--
-- ============================================================================================
-- **IT CRASHED A LIVE GAME ON ITS FIRST RUN (2026-09-18) AND MUST NOT BE RE-RUN AS WRITTEN.**
--
-- `CALL type=2` at 02:26:48.1256 and the crash dump at 02:26:48.1264 -- the same millisecond.
-- `EXCEPTION_ACCESS_VIOLATION` (0xC0000005) inside **VCRUNTIME140.dll**, i.e. a bad buffer
-- operation, not a fault in the game's own code or in the adapter's `main.dll`.
--
-- **THEN TYPE 3 CRASHED IDENTICALLY** (call 02:30:49.9374, dump 02:30:49.9384), which settles which
-- of the two candidates it was. The candidates were:
--   1. DamageType 2 is genuinely unhandled on this build; or
--   2. the `attackDirection` argument form below is WRONG and the parameter buffer was corrupt
--      from the first call -- types 0 and 1 survived by luck and 2 branched into code that used it.
--
-- **Candidate 1, widened: the valid range is TINY -- 0 and 1 -- and anything above it crashes.**
-- Two values apart, two instant access violations, while 0 and 1 behaved coherently and type 1
-- visibly USED the direction argument (knockback). A corrupt parameter buffer does not produce a
-- clean, distinct, repeatable reaction for the low values and instant death for the high ones; an
-- enum value indexing past the end of a switch or table does exactly that. So the argument form is
-- probably sound and the VALUE was the fault.
--
-- **Do not confirm that by trying 4.** Two guesses failing the same way is this repo's signal to
-- isolate by subtraction rather than guess again (`CLAUDE.md`). The subtraction here is to read the
-- ENUM -- name the DamageType property's declared enum and list its values, which is a metadata
-- read (naming a property's class and stopping, the allowed shape) and costs no live session.
--
-- **The method mistake worth keeping, because it is the transferable part.** The probe latched onto
-- "FVector table" purely because the UE4SS Lua wrapper accepted it without raising -- and
-- "the wrapper accepted it" is NOT evidence of the real parameter layout. That is the same shape as
-- `pseudoregalia/CLAUDE.md`'s standing warning that a vendored SDK's idea of a struct is a claim to
-- verify rather than a fact. A guessed struct passed across that boundary is an access violation no
-- `pcall` catches.
--
-- **If this question is picked up again, do it from C++ instead**, where `call_perform_damage_response`
-- already builds a correctly SIZED, fully ZEROED parameter buffer and writes only the DamageType
-- byte at its own reflected offset (`Plugin.cpp`) -- which is exactly why the shipped hurt mirror has
-- called this function for a year without crashing anything. Reading the real signature from C++ is
-- the prerequisite; `attackDirection`'s type is UNESTABLISHED as of this file's date.
--
-- WHAT THE RUN DID ESTABLISH before it died, the user watching the screen: the damage type SELECTS
-- THE REACTION -- type 0 blink only, type 1 knockback plus blink, type 2 knockback plus blink then
-- the crash -- and **no type moved either health value**, at +0/100/500/1000/2500 ms. So this
-- interface is the reaction and never the deduction, on the PLAYER as well as on a ghost. The
-- read-only follow-up is `enemy_hit_watch.lua` beside this file.
-- ============================================================================================
--
-- WHAT IS ALREADY ESTABLISHED (Plugin.cpp, 2026-08-27 -- this probe does NOT re-derive it):
--   * An attacker records victims in its OWN `hitActorsArray` and calls the Blueprint interface
--     `BPI_PerformDamageResponse(DamageType, attackDirection)` on each one.
--   * That interface carries a damage TYPE (a byte), never an amount -- the VICTIM decides what a
--     type costs. Zeroing an attacker's damage numbers achieves nothing; they are never read.
--   * This game does not use the engine's damage path at all (`ApplyDamage` armed 3/3, never fired;
--     the player's `LastHitBy` stays null through being hurt).
--   * Called on a GHOST with type 0 it paints the hurt reaction and moves no HP -- but a ghost has
--     no `BP_HpHitable` and no game-instance ref at all, so that is not evidence about the PLAYER.
--
-- THE ONE QUESTION: called on the PLAYER's own pawn, does it deduct HP -- and which byte is an
-- enemy's ordinary contact hit? If a type costs HP and looks on screen exactly like being touched
-- by an enemy, chaser "hurt" is that call and nothing else.
--
-- HOW IT READS HP -- two independent locations, every sample, because which one is authoritative is
-- exactly what is in doubt (the docs disagree; both read 80.0 at rest, measured 2026-09-18):
--   * the GameInstance's `CurrentHp` through `As MV Game Instance Ref` (what the shipped adapter
--     already uses to detect a hurt, a heal and a death);
--   * the pawn's OWN `BP_HpHitable` component's `CurrentHp`/`maxHP`.
-- If one moves a tick before the other, that names the authority and the mirror. Both are read
-- through the game's own refs -- never a value this script wrote (CLAUDE.md).
--
-- SHAPE: endurance, not timing. A countdown, then one call per phase with a long gap, so nothing
-- has to be caught at a particular moment. Per call it logs HP at +0ms/+100ms/+500ms/+1s/+2.5s, so
-- a deduction that lands a tick late is still attributed, and an i-frame window is readable as "the
-- second call at +Xs did nothing".
--
-- SAFETY, stated because this deliberately damages the player:
--   * It STOPS the sweep below HP_FLOOR so a sweep cannot accidentally kill you. The kill path is a
--     separate question and gets its own deliberate run, not an accident in this one.
--   * It writes NO save, NO memory and NO game state -- it calls one of the game's own functions and
--     reads two of the game's own fields. The game does whatever it normally does with that call.
--   * It touches ONLY the local player's pawn. Ghosts are never called here (the shipped mirror
--     already does that, and having two callers would make every reading ambiguous).
--   * UNLOAD IT AFTERWARDS. A calling probe left in the scratch slot is a suspect in every later
--     report, and this one's calls look exactly like a damage bug.
--
-- WHAT IT CANNOT SEE: why a type costs what it costs (the victim's own Blueprint decides, and that
-- is not readable here), and any damage path an enemy uses that is NOT this interface. If every
-- type reads 0 cost, that is the finding -- and the next instrument is a watch of both HP locations
-- across a REAL enemy contact hit, which names the amount without guessing the type.

local TAG = "[MeshGhostDamageSweep]"
local START_DELAY_S = 10        -- time to get somewhere safe before the first call
local GAP_S = 8                 -- between phases; long enough for i-frames to lapse
-- 0 and 1 are DONE (2026-09-18: blink only; knockback plus blink -- neither moved HP).
-- **2 IS THE KNOWN CRASHER and is deliberately absent** -- see the crash block at the top.
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

-- The two health locations, read through the game's own refs each time (never cached: a transition
-- makes an entirely new pawn, and a stale ref is how a reading survives the thing it measured).
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

-- Call the game's own interface on the PLAYER.
--
-- **UE4SS Lua demands the EXACT arity** -- measured 2026-09-18, first run: passing DamageType alone
-- fails with "UFunction expected 2 parameters, received 1". The shipped C++ helper gets away with
-- setting only DamageType because it hands ProcessEvent a fully ZEROED parameter buffer; Lua has no
-- equivalent, so `attackDirection` has to be passed explicitly. Its type is not established
-- anywhere in this repo, so rather than guess once and read a failure as "the game did nothing",
-- this tries each plausible form and REPORTS which one the build accepted -- the accepted form is
-- itself a finding, and it is what the C++ would need if this ever moves into the adapter.
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

    -- Report once whether the function is even there, so "nothing happened" can never be confused
    -- with "the name does not resolve on this build" (an instrument reports its own coverage).
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

    -- Service an in-flight call's readback window before starting anything new.
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
