-- MeshGhost STAND-UP EDGE (2026-09-09): a CALLING probe, dev-only, hot-loaded beside the hitable
-- restore. The driven ghost enters the seated state (moveState 8, MovementMode 5) at the clip's
-- sit and never leaves it (the DRIVE TRACE: seated until the loop seam). `sit_watch.lua` measured
-- a real stand-up as the RISING EDGE of `hasMovementInput?` while seated, and the table glitch as
-- the same sit with the input already held (no edge). The rig writes `hasMovementInput?` from the
-- stick, so this probe watches that field on the driven pawn at 50 ms and, on its false->true
-- edge while moveState == 8, calls the pawn's own `EndInteract` (no-arg, zero-filled params),
-- then logs moveState/MovementMode 100 ms and 500 ms later. Edge-triggered ONLY -- a level trigger
-- was the version that broke the glitch. Restore the stub before judging anything else.

local TAG = "[MeshGhostStandUp]"

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

local driven, driven_addr = nil, nil
local last_input = nil
local ticks = 0
local pending = {}   -- { at_tick, pawn, label }
log("loaded -- EndInteract on the rising edge of hasMovementInput? while seated, driven pawn only")

LoopAsync(50, function()
    ticks = ticks + 1
    -- Re-find the driven pawn every second (a loop seam replaces it): the player's class, an
    -- AIController, not being destroyed.
    if ticks % 20 == 1 or not (driven and valid(driven)) then
        local me = player_pawn()
        if me then
            local my_class = "?"
            pcall(function() my_class = me:GetClass():GetFName():ToString() end)
            local my_addr = addr_of(me)
            local found = nil
            for _, p in pairs(FindAllOf(my_class) or {}) do
                if valid(p) and addr_of(p) ~= my_addr and prop(p, "bActorIsBeingDestroyed") ~= true then
                    local ctl = prop(p, "Controller")
                    local cn = "<none>"
                    if ctl ~= nil and valid(ctl) then pcall(function() cn = ctl:GetClass():GetFName():ToString() end) end
                    if cn:find("AIController") then found = p end
                end
            end
            if found and addr_of(found) ~= driven_addr then
                driven, driven_addr, last_input = found, addr_of(found), nil
                log("watching driven pawn " .. fname_str(found))
            elseif not found then
                driven, driven_addr = nil, nil
            end
        end
    end
    -- Deferred read-backs.
    local keep = {}
    for _, d in ipairs(pending) do
        if ticks >= d.at_tick then
            if valid(d.pawn) then
                log(string.format("%s: moveState=%s MovementMode=%s hasMovementInput?=%s", d.label,
                    tostring(prop(d.pawn, "moveState")), tostring(prop(d.pawn, "MovementMode")), tostring(prop(d.pawn, "hasMovementInput?"))))
            end
        else
            keep[#keep + 1] = d
        end
    end
    pending = keep
    if not (driven and valid(driven)) then return false end
    local input = prop(driven, "hasMovementInput?")
    local ms = prop(driven, "moveState")
    if last_input == false and input == true and ms == 8 then
        local mm = prop(driven, "MovementMode")
        local ok, err = pcall(function() driven:EndInteract() end)
        log(string.format("rising edge while seated (moveState=8 MovementMode=%s) -> EndInteract %s", tostring(mm), ok and "called" or ("FAILED " .. tostring(err))))
        pending[#pending + 1] = { at_tick = ticks + 2, pawn = driven, label = "  +100ms" }
        pending[#pending + 1] = { at_tick = ticks + 10, pawn = driven, label = "  +500ms" }
    end
    last_input = input
    return false
end)
