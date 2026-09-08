-- MeshGhost DRIVE RIG helper (2026-09-08): a driven ghost is a fresh clone with the pawn's
-- CLASS DEFAULTS, and `obtainedAttack?` is false on it (the drive log, 23:06) -- the attack the
-- player unlocked on their save is not a thing the clone has, so its attack event nodes refuse.
-- This writes the flag true on the first AI-steered ghost, re-checked every 2 s (a loop seam
-- respawns the pawn). Ghost-only, by the same identity guard as the census; never the player.
-- Hot-loaded over the scratch slot; restore the stub afterwards. Dev-only; never ships.

local TAG = "[MeshGhostGrantAttack]"
local PAWN_CLASS = "BP_PlayerGoatMain_C"
local FLAGS = { "obtainedAttack?" }

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function fname_str(x)
    local s
    pcall(function() s = x:GetFName():ToString() end)
    return s or "?"
end
local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end
local function same_object(a, b)
    if a == nil or b == nil then return false end
    local aa, ab
    pcall(function() aa = a:GetAddress() end)
    pcall(function() ab = b:GetAddress() end)
    if aa ~= nil and ab ~= nil then return aa == ab end
    return fname_str(a) == fname_str(b)
end
local function player_controller_and_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn = prop(pc, field)
                if pawn ~= nil and valid(pawn) then return pc, pawn end
            end
        end
    end
    return nil
end
local function find_ghost(pc, player_pawn)
    local pawns = FindAllOf(PAWN_CLASS)
    if not pawns then return nil end
    for _, p in pairs(pawns) do
        if valid(p) and not same_object(p, player_pawn) and not fname_str(p):find("^Default__") then
            local ctl = prop(p, "Controller")
            local ctl_class = "nil"
            if ctl ~= nil and valid(ctl) then pcall(function() ctl_class = fname_str(ctl:GetClass()) end) end
            if not same_object(ctl, pc) and ctl_class:find("AIController") then return p end
        end
    end
    return nil
end

local last_ghost_name = nil
local function tick()
    local pc, player_pawn = player_controller_and_pawn()
    if not pc or not player_pawn then return end
    local ghost = find_ghost(pc, player_pawn)
    if ghost == nil then return end
    if same_object(ghost, player_pawn) or fname_str(ghost) == fname_str(player_pawn) then
        print(TAG .. " ABORT: chosen pawn is the player's -- nothing written\n")
        return
    end
    for _, flag in ipairs(FLAGS) do
        local before = prop(ghost, flag)
        if before ~= nil then
            local bv = before
            if type(bv) == "userdata" then pcall(function() bv = bv:get() end) end
            if bv ~= true then
                local ok, err = pcall(function() ghost[flag] = true end)
                local after = prop(ghost, flag)
                if type(after) == "userdata" then pcall(function() after = after:get() end) end
                print(string.format("%s %s on %s: %s -> %s (%s)\n", TAG, flag, fname_str(ghost), tostring(bv), tostring(after), ok and "written" or ("ERROR " .. tostring(err))))
            elseif last_ghost_name ~= fname_str(ghost) then
                print(string.format("%s %s already true on %s\n", TAG, flag, fname_str(ghost)))
            end
        end
    end
    last_ghost_name = fname_str(ghost)
end

print(TAG .. " loaded -- grants obtainedAttack? on the first AI-steered ghost, re-checked every 2 s\n")
LoopAsync(2000, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        if not ok then print(TAG .. " tick error: " .. tostring(err) .. "\n") end
    end)
    return false
end)
