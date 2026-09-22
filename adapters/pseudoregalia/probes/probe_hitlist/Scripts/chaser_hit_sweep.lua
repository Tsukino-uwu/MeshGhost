-- MeshGhost CHASER HIT SWEEP (written 2026-09-23): CALLS the game's own damage event on the player
-- THREE times, a chaser as the attacker. Part B/E of agent_docs/chaser-planning.md. NOT read-only:
-- each step costs the player one hit.
--
-- WHY. `try_damage_once.lua` proved `BPI_TryDamage` deals damage (2026-09-23: 75 -> 70,
-- `intangible?` on, the user saw a normal hurt) -- but with a REAL enemy as Attacker and the struct
-- that enemy's hit left behind. The shipped chaser has neither, so this builds both the way the
-- adapter would: Attacker = a chaser's pawn, `ST_HitboxData` from a table. Every field value comes
-- from `hitbox_capture.lua`'s 14 real hits the same day: a body touch from three enemy kinds carried
-- Damage 5, HitStopDuration 0.2, HitType false, the `Cue_contact` sound, `handSlot_RSocket`,
-- lengthRadiusHalfHeight 120/80/80, DamageType 5; the Maid's heavier hit DamageType 2 (and Damage
-- 10); a hazard and a projectile DamageType 0. Only those three DamageTypes are used -- a value the
-- game never produced is untested, and `BPI_PerformDamageResponse` crashed on 2 and 3 (2026-09-18),
-- which these real hits now show is a problem of that call, not of the values.
--
-- THE STEPS, STEP_GAP_S apart after a START_S countdown (well past the ~1.56 s i-frames):
--   1. Damage 20, DamageType 5  -- a contact touch at a custom amount: does the amount follow?
--   2. Damage 5,  DamageType 2  -- the Maid's kind: a different reaction (knockback, sword drop)?
--   3. Damage 5,  DamageType 0  -- the hazard/projectile kind.
-- Each logs its arguments, then CurrentHp and `intangible?` read back at +0/+500 ms. A step is
-- SKIPPED (and says so) while `intangible?` is true, never retried.
--
-- The struct's field names are the reflected ones (`Damage_15_<guid>` and so on), written below and
-- checked against the live struct before the first call.
--
-- HOW TO RUN: chasers running (relay up), stand still away from enemies. Restore the stub after.

local TAG = "[MeshGhostChaserHit]"
local START_S = 15
local STEP_GAP_S = 6
local STEPS = {
    { damage = 20.0, damage_type = 5, label = "contact kind, Damage 20" },
    { damage = 5.0, damage_type = 2, label = "Maid's kind (DamageType 2)" },
    { damage = 5.0, damage_type = 0, label = "hazard/projectile kind (DamageType 0)" },
}
local CONTACT_CUE = "/Game/Audio/Sounds/Actions/Cue_contact.Cue_contact"

local function log(line) print(TAG .. " " .. line .. "\n") end
local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function addr(obj)
    local a
    pcall(function() a = obj:GetAddress() end)
    return a
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
local function loc(actor)
    local v
    pcall(function() v = actor:K2_GetActorLocation() end)
    if v == nil then return nil end
    return { X = v.X, Y = v.Y, Z = v.Z }
end

-- The nearest pawn of the player's own class that is NOT the player: with no peer in the room and
-- no replay playing, that is a chaser. Identity by address (two wrappers are never ==).
local function nearest_chaser(me)
    local my_addr = addr(me)
    local my_loc = loc(me)
    local cls_name = "?"
    pcall(function() cls_name = me:GetClass():GetFName():ToString() end)
    local all = FindAllOf(cls_name)
    local best, best_d, count = nil, nil, 0
    if all then
        for _, p in pairs(all) do
            if valid(p) and addr(p) ~= my_addr then
                local l = loc(p)
                if l and my_loc then
                    count = count + 1
                    local d = math.sqrt((l.X - my_loc.X) ^ 2 + (l.Y - my_loc.Y) ^ 2 + (l.Z - my_loc.Z) ^ 2)
                    if best_d == nil or d < best_d then best, best_d = p, d end
                end
            end
        end
    end
    return best, best_d, count, cls_name
end

-- ST_HitboxData's reflected field names as this build spells them, WRITTEN rather than walked
-- (preflight's "blind reflection walks" gate): read off `hitbox_capture.lua`'s first run, 2026-09-23.
local HITBOX_FIELD = {
    Damage = "Damage_15_2068E77745C092F1FC7634A91107BEAB",
    HitStopDuration = "HitStopDuration_16_E15EA3AC41362D7EA0AEB3A8064CF3A7",
    HitType = "HitType_7_A22DD9384A13F44AE32A35B8483C5ED3",
    HitSound = "HitSound_14_FB67671344A1F2B807571DAC05C7BC60",
    hitboxSocketName = "hitboxSocketName_13_3851CA34448DCDDECDDC9DAEE4FD19DE",
    lengthRadiusHalfHeight = "lengthRadiusHalfHeight_12_596D9D47496CF530718FD78AB8AAE1CE",
    DamageType = "DamageType_19_CC06EAD1426104EDCDC6BB915B624248",
}

log("loaded " .. os.date("%H:%M:%S") .. " -- first hit in " .. START_S .. "s, then every " .. STEP_GAP_S .. "s. Stand still, away from enemies.")

local t0 = os.clock()
local step = 0
local next_at = t0 + START_S
local reads = {}
local names, cue
local done = false

local function fire(me, hitable, s)
    local hp, intang
    pcall(function() hp = hitable.CurrentHp end)
    pcall(function() intang = hitable["intangible?"] end)
    if intang ~= false then
        log(string.format("STEP %d (%s) SKIPPED: intangible? = %s", step, s.label, tostring(intang)))
        return
    end
    local chaser, dist, count, cls_name = nearest_chaser(me)
    if chaser == nil then
        log(string.format("STEP %d SKIPPED: no other %s pawn found (chasers running?)", step, cls_name))
        return
    end
    local my_loc, c_loc = loc(me), loc(chaser)
    local dx, dy = my_loc.X - c_loc.X, my_loc.Y - c_loc.Y
    local len = math.sqrt(dx * dx + dy * dy)
    local fwd = len > 0.001 and { X = dx / len, Y = dy / len, Z = 0.0 } or { X = 1.0, Y = 0.0, Z = 0.0 }
    local info = {}
    info[names.Damage] = s.damage
    info[names.HitStopDuration] = 0.2
    info[names.HitType] = false
    if cue ~= nil then info[names.HitSound] = cue end
    info[names.hitboxSocketName] = FName("handSlot_RSocket")
    info[names.lengthRadiusHalfHeight] = { X = 120.0, Y = 80.0, Z = 80.0 }
    info[names.DamageType] = s.damage_type
    local cname = "?"
    pcall(function() cname = chaser:GetFullName() end)
    log(string.format("STEP %d (%s): BEFORE CurrentHp=%s; Attacker=%s (%d candidate(s), %.0f away); ForwardVector={%.3f %.3f 0}; HitSound=%s",
        step, s.label, tostring(hp), cname, count, dist, fwd.X, fwd.Y, cue and "Cue_contact" or "<not found, left null>"))
    local ok, err = pcall(function() hitable:BPI_TryDamage(chaser, info, fwd, my_loc) end)
    log(string.format("STEP %d CALL returned: ok=%s%s", step, tostring(ok), ok and "" or (" err=" .. tostring(err))))
    for _, ms in ipairs({ 0, 500 }) do reads[#reads + 1] = { due = os.clock() + ms / 1000, ms = ms, step = step, hitable = hitable } end
end

LoopAsync(50, function()
    local ok, res = pcall(function()
        if done then return true end
        local keep = {}
        for _, r in ipairs(reads) do
            if os.clock() >= r.due then
                local hp, intang
                pcall(function() hp = r.hitable.CurrentHp end)
                pcall(function() intang = r.hitable["intangible?"] end)
                log(string.format("STEP %d AFTER +%dms: CurrentHp=%s intangible?=%s", r.step, r.ms, tostring(hp), tostring(intang)))
            else
                keep[#keep + 1] = r
            end
        end
        reads = keep
        if os.clock() < next_at then return false end
        if step >= #STEPS then
            if #reads == 0 then log("done. Restore probe_scratch's stub."); done = true; return true end
            return false
        end
        local me = player_pawn()
        if me == nil then return false end
        local hitable
        pcall(function() hitable = me.BP_HpHitable end)
        if hitable == nil or not valid(hitable) then return false end
        if names == nil then
            -- Coverage: every written name must resolve on the live struct, or the call would
            -- silently build a struct with that field left at zero.
            local info
            pcall(function() info = hitable.incomingHitboxInfo end)
            local missing = {}
            for short, full in pairs(HITBOX_FIELD) do
                -- A name that does not resolve may read nil rather than raise, so the value is checked
                -- too -- except HitSound, which is null at rest (the 2026-09-23 baseline).
                local ok, v = pcall(function() return info[full] end)
                if not ok or (v == nil and short ~= "HitSound") then missing[#missing + 1] = short end
            end
            if #missing > 0 then log("REFUSED: ST_HitboxData field(s) do not resolve: " .. table.concat(missing, ", ")); done = true; return true end
            names = HITBOX_FIELD
            local c
            pcall(function() c = StaticFindObject(CONTACT_CUE) end)
            if c ~= nil and valid(c) then cue = c end
            log("COVERAGE: all 7 ST_HitboxData fields resolve; contact cue " .. (cue and "found" or "NOT loaded -- hits will be silent"))
        end
        step = step + 1
        fire(me, hitable, STEPS[step])
        next_at = os.clock() + STEP_GAP_S
        return false
    end)
    if not ok then log("LOOP ERROR: " .. tostring(res)); return true end
    return res
end)
