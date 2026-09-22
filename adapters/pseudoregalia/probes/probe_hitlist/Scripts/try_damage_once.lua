-- MeshGhost TRY DAMAGE ONCE (written 2026-09-23): CALLS the game's own damage event ONCE on the
-- player. Part B of agent_docs/chaser-planning.md. NOT read-only: it costs the player one hit.
--
-- WHY. `hitbox_capture.lua` (2026-09-23) read back what two real enemies passed: after a hit the
-- player's `BP_HpHitable` holds `Attacker` (the enemy), `incomingHitboxInfo` (`ST_HitboxData`,
-- Damage 5.0, DamageType 5), `Forward Vector` (the attacker's facing) and `Query Location`, and
-- `intangible?` turns true -- the same four inputs `BPI_TryDamage(Attacker, HitboxInfo,
-- ForwardVector, QueryLocation)` takes (entry 603, the class's own bytecode). The four earlier bare
-- calls each left those at null/default. This calls `BPI_TryDamage` with the values the game itself
-- stored on the last real hit, so the only thing not copied from the game is the moment.
--
-- WHAT IT DOES: waits for ONE real hit (an HP drop), then fires once QUIET_S pass with no further
-- drop -- so a respawn or a stale reference cannot be what it calls with (the first run, 2026-09-23,
-- was REFUSED after the player died and respawned: a new pawn, a new component, Attacker null).
-- Refuses unless `intangible?` is false and `Attacker` is still a valid object; reads CurrentHp, calls once, and
-- reads CurrentHp and `intangible?` back through the component at +0/+100/+500/+1500 ms. Nothing
-- else is written. The call is logged with every argument so a negative says what was passed.
--
-- HOW TO RUN: load it through the scratch slot, take ONE ordinary enemy touch, walk away from every
-- enemy and stand still. It fires QUIET_S after the last hit. Restore the stub after.

local TAG = "[MeshGhostTryDamage]"
local QUIET_S = 5
local READ_BACK_MS = { 0, 100, 500, 1500 }

local function log(line) print(TAG .. " " .. line .. "\n") end
local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
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
local function vec_text(v)
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    return string.format("{X=%s Y=%s Z=%s}", tostring(x), tostring(y), tostring(z))
end
local function state(hitable)
    local hp, intang
    pcall(function() hp = hitable.CurrentHp end)
    pcall(function() intang = hitable["intangible?"] end)
    return hp, intang
end

log("loaded " .. os.date("%H:%M:%S") .. " -- WAITING for one real enemy hit; then walk away and stand still -- it calls BPI_TryDamage ONCE " .. QUIET_S .. "s after the last hit.")

local last_hp, last_drop = nil, nil
local fired_at = nil
local next_read = 1
local hitable_ref = nil
local done = false

LoopAsync(50, function()
    local ok, res = pcall(function()
        if done then return true end
        if fired_at == nil then
            local me = player_pawn()
            if me == nil then return false end
            local hitable
            pcall(function() hitable = me.BP_HpHitable end)
            if hitable == nil or not valid(hitable) then return false end
            local hp, intang = state(hitable)
            if last_hp ~= nil and hp ~= nil and hp < last_hp then
                last_drop = os.clock()
                log(string.format("real hit seen: CurrentHp %s -> %s; firing %ds after the last one.", tostring(last_hp), tostring(hp), QUIET_S))
            end
            if hp ~= nil then last_hp = hp end
            if last_drop == nil or os.clock() - last_drop < QUIET_S then return false end
            if intang ~= false then log("REFUSED: intangible? = " .. tostring(intang) .. " (i-frames or unreadable)."); done = true; return true end
            local attacker
            pcall(function() attacker = hitable.Attacker end)
            if attacker == nil or not valid(attacker) then log("REFUSED: stored Attacker is not a valid object -- take one real enemy hit first."); done = true; return true end
            local info
            pcall(function() info = hitable.incomingHitboxInfo end)
            local fwd, qloc
            pcall(function() fwd = hitable["Forward Vector"] end)
            pcall(function() qloc = me:K2_GetActorLocation() end)
            local an = "?"
            pcall(function() an = attacker:GetFullName() end)
            log("BEFORE: CurrentHp=" .. tostring(hp) .. " intangible?=" .. tostring(intang))
            log("CALL: BPI_TryDamage(Attacker=" .. an .. ", HitboxInfo=<the stored incomingHitboxInfo>, ForwardVector="
                .. vec_text(fwd) .. ", QueryLocation=" .. vec_text(qloc) .. " [player's own location])")
            local fwd_t = { X = fwd.X, Y = fwd.Y, Z = fwd.Z }
            local q_t = { X = qloc.X, Y = qloc.Y, Z = qloc.Z }
            local cok, cerr = pcall(function() hitable:BPI_TryDamage(attacker, info, fwd_t, q_t) end)
            log("CALL returned: ok=" .. tostring(cok) .. (cok and "" or (" err=" .. tostring(cerr))))
            fired_at = os.clock()
            hitable_ref = hitable
            return false
        end
        local due = READ_BACK_MS[next_read]
        if due == nil then
            log("done. Restore probe_scratch's stub.")
            done = true
            return true
        end
        if (os.clock() - fired_at) * 1000 >= due then
            local hp, intang = state(hitable_ref)
            log(string.format("AFTER +%dms: CurrentHp=%s intangible?=%s", due, tostring(hp), tostring(intang)))
            next_read = next_read + 1
        end
        return false
    end)
    if not ok then log("LOOP ERROR: " .. tostring(res)); return true end
    return res
end)
