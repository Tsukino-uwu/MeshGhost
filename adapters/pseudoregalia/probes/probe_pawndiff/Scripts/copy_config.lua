-- MeshGhost COPY CONFIG (2026-09-09): a WRITING probe, dev-only. Every second, on every DRIVEN
-- ghost pawn (a pawn of the player's class steered by an AIController and holding a PRIVATE
-- game-instance ref -- the rig's own signature), the save-derived config fields the pawn diff
-- found different (`pawndiff-002922.log`: healUpgrades, damageUpgrades, powerBuildUpgrades,
-- powerMeterUpgrades, bonusAirKicks, healAmountPerDing, canMoveHeal?, canDoAirRecovery?) are
-- written from the PLAYER's pawn. The question: does the chair sit stop being the hurt variant
-- once the ghost carries the player's upgrades. Each write is read back through the property
-- itself and logged once per pawn; a mismatch is logged as such. Damage numbers are NOT copied
-- (the adapter zeroes them on purpose). Hot-loaded over the scratch slot; RESTORE THE STUB and
-- unload before judging anything else -- a writing probe is a suspect in every later report.

local TAG = "[MeshGhostCopyConfig]"
local FIELDS = { "healUpgrades", "damageUpgrades", "powerBuildUpgrades", "powerMeterUpgrades",
                 "bonusAirKicks", "healAmountPerDing", "canMoveHeal?", "canDoAirRecovery?" }

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function fname_str(x)
    local s
    pcall(function() s = x:GetFName():ToString() end)
    return s or "?"
end
local function addr_of(x)
    local a
    pcall(function() a = x:GetAddress() end)
    return a
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

local done = {}   -- pawn address -> true once written and read back
log("loaded -- copying " .. #FIELDS .. " field(s) from the player onto every driven ghost pawn, once per pawn, read back after each write")

LoopAsync(1000, function()
    local me = player_pawn()
    if not me then return false end
    local my_class = "?"
    pcall(function() my_class = me:GetClass():GetFName():ToString() end)
    local my_addr = addr_of(me)
    local my_gi = prop(me, "As MV Game Instance Ref")
    local my_gi_addr = my_gi and addr_of(my_gi) or nil
    for _, p in pairs(FindAllOf(my_class) or {}) do
        local a = addr_of(p)
        if valid(p) and a ~= my_addr and not done[a] then
            local ctl = prop(p, "Controller")
            local cn = "<none>"
            if ctl ~= nil and valid(ctl) then pcall(function() cn = ctl:GetClass():GetFName():ToString() end) end
            local gi = prop(p, "As MV Game Instance Ref")
            local private_gi = gi ~= nil and valid(gi) and addr_of(gi) ~= my_gi_addr
            local being_destroyed = prop(p, "bActorIsBeingDestroyed") == true
            if cn:find("AIController") and private_gi and not being_destroyed then
                done[a] = true
                local parts = {}
                for _, f in ipairs(FIELDS) do
                    local want = prop(me, f)
                    local before = prop(p, f)
                    local ok, err = pcall(function() p[f] = want end)
                    local after = prop(p, f)
                    parts[#parts + 1] = string.format("%s %s->%s%s", f, tostring(before), tostring(after),
                        (ok and after == want) and "" or (" MISMATCH(want " .. tostring(want) .. (ok and "" or (", err " .. tostring(err))) .. ")"))
                end
                log("driven pawn " .. fname_str(p) .. " ctl=" .. cn .. ": " .. table.concat(parts, "; "))
            end
        end
    end
    return false
end)
