-- MeshGhost HITABLE RESTORE (2026-09-09): a WRITING probe, dev-only. The player's health object is
-- the pawn's OWN component `BP_HpHitable` (class `BP_HpHitable_C`, outer the pawn; `CurrentHp`,
-- `maxHP` -- the 2026-09-06 player dump, `documentation.md`). The spawn decouple nulls a ghost's
-- REFERENCE to it, and the driven ghost's chair sit stayed the hurt variant with health 80 on its
-- private game instance and the save's upgrades copied -- so the sit most likely reads the null
-- ref. Every second, on every DRIVEN pawn (AIController + a private game-instance ref + not being
-- destroyed), this finds the pawn's own `BP_HpHitable_C` object (outer == the pawn), logs its
-- CurrentHp/maxHP and the player's, copies CurrentHp/maxHP from the player's onto the ghost's OWN
-- object if they differ, then writes the pawn's `BP_HpHitable` ref to it and reads it back. The
-- player's object is only read. Once per pawn. Hot-loaded over the scratch slot; RESTORE THE STUB
-- before judging anything else.

local TAG = "[MeshGhostHitable]"
local HITABLE_CLASS = "BP_HpHitable_C"

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

local function own_hitable(pawn)
    local pawn_addr = addr_of(pawn)
    local found, count = nil, 0
    for _, h in pairs(FindAllOf(HITABLE_CLASS) or {}) do
        if valid(h) then
            count = count + 1
            local outer
            pcall(function() outer = h:GetOuter() end)
            if outer ~= nil and addr_of(outer) == pawn_addr then found = h end
        end
    end
    return found, count
end

local done = {}
log("loaded -- restoring each driven pawn's own " .. HITABLE_CLASS .. " reference, once per pawn, read back")

LoopAsync(1000, function()
    local me = player_pawn()
    if not me then return false end
    local my_class = "?"
    pcall(function() my_class = me:GetClass():GetFName():ToString() end)
    local my_addr = addr_of(me)
    local my_gi = prop(me, "As MV Game Instance Ref")
    local my_gi_addr = my_gi and addr_of(my_gi) or nil
    local my_hit = prop(me, "BP_HpHitable")
    local my_hp = my_hit and prop(my_hit, "CurrentHp") or nil
    local my_max = my_hit and prop(my_hit, "maxHP") or nil
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
                local ref_before = prop(p, "BP_HpHitable")
                local ref_before_s = (ref_before ~= nil and valid(ref_before)) and fname_str(ref_before) or "null"
                local own, count = own_hitable(p)
                if not own then
                    log(string.format("driven pawn %s: NO own %s among %d live (ref was %s) -- nothing written",
                        fname_str(p), HITABLE_CLASS, count, ref_before_s))
                else
                    local hp0, max0 = prop(own, "CurrentHp"), prop(own, "maxHP")
                    local copied = ""
                    if my_hp ~= nil and hp0 ~= my_hp then
                        pcall(function() own.CurrentHp = my_hp end)
                        copied = copied .. string.format(" CurrentHp %s->%s", tostring(hp0), tostring(prop(own, "CurrentHp")))
                    end
                    if my_max ~= nil and max0 ~= my_max then
                        pcall(function() own.maxHP = my_max end)
                        copied = copied .. string.format(" maxHP %s->%s", tostring(max0), tostring(prop(own, "maxHP")))
                    end
                    local ok, err = pcall(function() p.BP_HpHitable = own end)
                    local ref_after = prop(p, "BP_HpHitable")
                    local ref_after_s = (ref_after ~= nil and valid(ref_after)) and (fname_str(ref_after) .. "@" .. tostring(addr_of(ref_after))) or "null"
                    log(string.format("driven pawn %s ctl=%s: own hitable %s@%s (CurrentHp=%s maxHP=%s; player %s/%s)%s; ref %s -> %s%s",
                        fname_str(p), cn, fname_str(own), tostring(addr_of(own)), tostring(hp0), tostring(max0), tostring(my_hp), tostring(my_max),
                        copied ~= "" and (" copied:" .. copied) or "", ref_before_s, ref_after_s,
                        (ok and addr_of(ref_after) == addr_of(own)) and "" or (" MISMATCH" .. (ok and "" or (" err " .. tostring(err))))))
                end
            end
        end
    end
    return false
end)
