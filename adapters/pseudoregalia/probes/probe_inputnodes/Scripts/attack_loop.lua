-- MeshGhost INPUT-NODE CENSUS, the ATTACK LOOP variant (2026-09-08, the user's ask mid-census:
-- "can you make it do attacks constantly?"). Fires the pawn's three attack event nodes on a
-- GHOST pawn in blocks -- `_3` five times at 1.5 s, then `_4`, then `_5`, and round again --
-- so the person watching can say which block makes the ghost swing. Same identity guard as
-- main.lua (the pawn is never the player's: address/name identity, an AIController, a per-tick
-- refusal). Copy over the scratch slot's main.lua and reload; restore the stub afterwards.
-- Dev-only tooling; never ships.

local TAG = "[MeshGhostAttackLoop]"
local PAWN_CLASS = "BP_PlayerGoatMain_C"
local NODES = { 3, 4, 5 }
local PER_BLOCK = 5
local GAP_S = 1.5

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

local asset = nil
local ghost = nil
local node_i, fired, next_at = 1, 0, 0
local waited = 0

local function tick()
    local pc, player_pawn = player_controller_and_pawn()
    if not pc or not player_pawn then return end
    if ghost == nil or not valid(ghost) then
        ghost = find_ghost(pc, player_pawn)
        if ghost == nil then
            waited = waited + 1
            if waited % 300 == 1 then print(TAG .. " no ghost pawn yet -- waiting\n") end
            return
        end
        print(string.format("%s GHOST: %s (player pawn %s)\n", TAG, fname_str(ghost), fname_str(player_pawn)))
        if asset == nil then
            local assets = FindAllOf("InputAction")
            if assets then for _, a in pairs(assets) do if valid(a) and fname_str(a) == "IA_Attack" then asset = a end end end
        end
        next_at = os.clock() + 1.0
    end
    if same_object(ghost, player_pawn) or fname_str(ghost) == fname_str(player_pawn) then
        print(TAG .. " ABORT: the chosen pawn IS the player's -- no call is made\n")
        ghost = nil
        return
    end
    if os.clock() < next_at then return end
    local idx = NODES[node_i]
    local fname = string.format("InpActEvt_IA_Attack_K2Node_EnhancedInputActionEvent_%d", idx)
    local ok, err = pcall(function() ghost[fname](ghost, {}, 0.0, 0.0, asset) end)
    fired = fired + 1
    local as = prop(ghost, "actionState")
    print(string.format("%s CALL Attack _%d (%d of %d) -> %s actionState=%s\n", TAG, idx, fired, PER_BLOCK, ok and "ok" or ("ERROR " .. tostring(err)), tostring(type(as) == "userdata" and pcall(function() return as:get() end) and as:get() or as)))
    if fired >= PER_BLOCK then
        fired = 0
        node_i = node_i % #NODES + 1
        print(string.format("%s next block: Attack _%d\n", TAG, NODES[node_i]))
    end
    next_at = os.clock() + GAP_S
end

print(TAG .. " loaded -- attack nodes _3, _4, _5 in blocks of " .. PER_BLOCK .. " on the first AI-steered ghost\n")
LoopAsync(16, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        if not ok then print(TAG .. " tick error: " .. tostring(err) .. "\n") end
    end)
    return false
end)
