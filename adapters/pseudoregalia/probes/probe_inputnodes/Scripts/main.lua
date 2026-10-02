-- Which of the pawn's Enhanced Input event nodes is the press and which the release: calls each on a replay ghost
-- (a Blueprint UFunction is never hooked) and reads the pawn's fields back for 600 ms and at 2.5 s. From Lua the
-- ActionValue is always zero, so Move is not called. Over the scratch slot; unload it afterwards.

local TAG = "[MeshGhostInputNodes]"
local PAWN_CLASS = "BP_PlayerGoatMain_C"
local TICK_MS = 16
local WINDOW_S = 0.6
local SETTLE_S = 3.0
local LATE_S = 2.5

-- action -> its nodes, ascending. Round 2 reverses each list.
local ACTIONS = {
    { name = "Jump",     nodes = { 20, 21 } },
    { name = "Crouch",   nodes = { 15, 16 } }, -- the known pair: 16 down, 15 up (GHOST_CROUCH_INPUT_CALL)
    { name = "WallRide", nodes = { 13, 14 } },
    { name = "Attack",   nodes = { 3, 4, 5 } },
    { name = "Guard",    nodes = { 9 } },
    { name = "LockOn",   nodes = { 11, 12 } },
    { name = "Throw",    nodes = { 7 } },
    { name = "Power",    nodes = { 0, 1, 2 } },
    { name = "Look",     nodes = { 17, 18 } },
}
local NAMED_SCALARS = { "moveInputAmount", "jumpType", "animJumpType", "attackComboPosition", "moveState", "actionState", "currentAirKicks", "powerLevel" }
local NAMED_VECTORS = { "inputVectorWorld", "ControlInputVector", "LastControlInputVector" }

---------------------------------------------------------------------------- plumbing (probe_inputcensus's)

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local MOD_ROOT = scriptDir() .. "../"
local OUT_PATH = string.format("%sinput_nodes-%s.log", MOD_ROOT, os.date("%H%M%S"))

local buffer = {}
local out_file = nil
local function out(line)
    buffer[#buffer + 1] = line
    print(TAG .. " " .. line .. "\n")
end
local function flush()
    if #buffer == 0 then return end
    if not out_file then out_file = io.open(OUT_PATH, "a") end
    if not out_file then return end
    out_file:write(table.concat(buffer, "\n"), "\n")
    out_file:flush()
    buffer = {}
end

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
local function plain(value)
    local t = type(value)
    if t == "boolean" or t == "number" or t == "string" or t == "nil" then return value end
    if t == "userdata" then
        local got
        if pcall(function() got = value:get() end) and got ~= nil and type(got) ~= "userdata" then return got end
        local okv, isvalid = pcall(function() return value:IsValid() end)
        if okv and isvalid == false then return "<unresolved>" end
        local ok, tn = pcall(function() return value:type() end)
        return "<userdata " .. tostring(ok and tn or "?") .. ">"
    end
    return "<" .. t .. ">"
end
local function vec_text(v)
    if v == nil then return "<nil>" end
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if type(x) ~= "number" then return tostring(plain(v)) end
    return string.format("%.2f,%.2f,%.2f", x, y, z or 0)
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

-- A ghost: a player-class pawn that is not the player's, not a class default, and steered by an AIController.
-- Identity by address or FName: two UE4SS Lua wrappers of one object are never equal under ==.
local function same_object(a, b)
    if a == nil or b == nil then return false end
    local aa, ab
    pcall(function() aa = a:GetAddress() end)
    pcall(function() ab = b:GetAddress() end)
    if aa ~= nil and ab ~= nil then return aa == ab end
    return fname_str(a) == fname_str(b)
end
local function find_ghost(pc, player_pawn)
    local pawns = FindAllOf(PAWN_CLASS)
    if not pawns then return nil end
    for _, p in pairs(pawns) do
        if valid(p) and not same_object(p, player_pawn) then
            local n = fname_str(p)
            if not n:find("^Default__") then
                local ctl = prop(p, "Controller")
                local ctl_class = "nil"
                if ctl ~= nil and valid(ctl) then pcall(function() ctl_class = fname_str(ctl:GetClass()) end) end
                if not same_object(ctl, pc) and ctl_class:find("AIController") then return p, ctl_class end
            end
        end
    end
    return nil
end

-- Every BoolProperty name on the pawn's class chain (class metadata only), once.
local function bool_names(pawn)
    local names, seen = {}, {}
    local cls
    pcall(function() cls = pawn:GetClass() end)
    while cls and valid(cls) do
        pcall(function()
            cls:ForEachProperty(function(p)
                local ptype = "?"
                pcall(function() ptype = p:GetClass():GetFName():ToString() end)
                if ptype == "BoolProperty" then
                    local n = fname_str(p)
                    if not seen[n] then seen[n] = true; names[#names + 1] = n end
                end
            end)
        end)
        local sup
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and valid(sup) and sup ~= cls then cls = sup else cls = nil end
    end
    table.sort(names)
    return names
end

---------------------------------------------------------------------------- the reading

local bools = nil
local missing = {}

local function snapshot(pawn)
    local s = {}
    for _, b in ipairs(bools) do
        local v = prop(pawn, b)
        if v == nil then missing[b] = true else s[b] = plain(v) end
    end
    for _, n in ipairs(NAMED_SCALARS) do
        local v = prop(pawn, n)
        if v == nil then missing[n] = true else s[n] = plain(v) end
    end
    for _, n in ipairs(NAMED_VECTORS) do
        local v = prop(pawn, n)
        if v == nil then missing[n] = true else s[n] = vec_text(v) end
    end
    local z
    pcall(function() z = pawn:K2_GetActorLocation().Z end)
    if type(z) == "number" then s["actor.Z"] = string.format("%.1f", z) end
    return s
end

local function diff(base, now)
    local changes = {}
    for k, v in pairs(now) do
        if base[k] ~= v then changes[#changes + 1] = string.format("%s: %s -> %s", k, tostring(base[k]), tostring(v)) end
    end
    table.sort(changes)
    return changes
end

local actions_by_name = {}
local function resolve_action_assets()
    local assets = FindAllOf("InputAction")
    if not assets then return end
    for _, a in pairs(assets) do
        if valid(a) then actions_by_name[fname_str(a)] = a end
    end
end

local function node_name(action, idx)
    return string.format("InpActEvt_IA_%s_K2Node_EnhancedInputActionEvent_%d", action, idx)
end

-- A zero ActionValue (an empty table zero-fills the struct), zero times, and the action asset if one loaded (the
-- shipped crouch call passes none and works). A native fault is the one thing this pcall cannot see.
local function call_node(pawn, action, idx)
    local fname = node_name(action, idx)
    local fn = prop(pawn, fname)
    if fn == nil then return false, "no such function on the pawn" end
    local asset = actions_by_name["IA_" .. action]
    local ok, err = pcall(function() pawn[fname](pawn, {}, 0.0, 0.0, asset) end)
    if not ok then return false, tostring(err) end
    return true, asset and "with IA asset" or "without IA asset"
end

---------------------------------------------------------------------------- the schedule

local plan = {}
local function build_plan()
    for round = 1, 2 do
        for _, a in ipairs(ACTIONS) do
            local order = {}
            for i, n in ipairs(a.nodes) do order[i] = n end
            if round == 2 then
                local r = {}
                for i = #order, 1, -1 do r[#r + 1] = order[i] end
                order = r
            end
            for _, n in ipairs(order) do plan[#plan + 1] = { round = round, action = a.name, idx = n } end
        end
    end
end

local state = "waiting" -- waiting | window | settle | done
local step = 0
local ghost = nil
local base = nil
local window_t0 = 0
local last_change_text = nil
local next_at = 0
local waited = 0
local started = false

local function begin_step(pawn)
    step = step + 1
    if step > #plan then
        state = "done"
        local m = {}
        for k in pairs(missing) do m[#m + 1] = k end
        table.sort(m)
        out(string.format("DONE: %d calls. COVERAGE: %d named field(s) never resolved on the ghost%s", #plan, #m,
            (#m > 0) and (": " .. table.concat(m, ", ")) or ""))
        out("Move (_19) was NOT called: its value cannot be passed from Lua (FInputActionValue has no reflected fields); that is the C++ half's measurement.")
        flush()
        return
    end
    local p = plan[step]
    base = snapshot(pawn)
    local ok, note = call_node(pawn, p.action, p.idx)
    window_t0 = os.clock()
    last_change_text = ""
    out(string.format("CALL r%d %s _%d -> %s (%s)", p.round, p.action, p.idx, ok and "ok" or "ERROR", note))
    state = ok and "window" or "settle"
    next_at = os.clock() + (ok and 0 or SETTLE_S)
end

local function tick()
    if state == "done" then return end
    local pc, player_pawn = player_controller_and_pawn()
    if not pc or not player_pawn then return end
    if ghost == nil or not valid(ghost) then
        local ctl_class
        ghost, ctl_class = find_ghost(pc, player_pawn)
        if ghost == nil then
            waited = waited + 1
            if waited % 300 == 1 then out("no ghost pawn yet (a replay ghost must be on screen: the active clip loops) -- waiting") end
            return
        end
        out(string.format("GHOST: %s steered by %s (player pawn %s)", fname_str(ghost), tostring(ctl_class), fname_str(player_pawn)))
    end
    -- Every tick, before any call: if the chosen pawn is ever the player's, stop for good.
    if same_object(ghost, player_pawn) or fname_str(ghost) == fname_str(player_pawn) then
        out("ABORT: the chosen pawn IS the player's pawn -- no call is made; fix find_ghost")
        state = "done"
        flush()
        return
    end
    do
        if bools == nil then
            bools = bool_names(ghost)
            out(string.format("%d BoolProperty name(s) on the pawn chain will be read by name each frame of a window", #bools))
            resolve_action_assets()
        end
    end
    if not started then
        started = true
        build_plan()
        out(string.format("PLAN: %d calls, two rounds (ascending, then descending), %.0f s each. Move is not in it (see the header).", #plan, SETTLE_S))
        state = "settle"
        next_at = os.clock() + 1.0
        return
    end
    local now = os.clock()
    if state == "window" then
        local s = snapshot(ghost)
        local ch = diff(base, s)
        local text = table.concat(ch, " | ")
        if text ~= last_change_text then
            last_change_text = text
            out(string.format("  +%3.0f ms: %s", (now - window_t0) * 1000, (#ch > 0) and text or "(no change from baseline)"))
        end
        if now - window_t0 >= WINDOW_S then
            state = "settle"
            next_at = window_t0 + LATE_S
        end
    elseif state == "settle" then
        if now >= next_at then
            if base ~= nil and step > 0 and step <= #plan then
                local ch = diff(base, snapshot(ghost))
                out(string.format("  +%3.0f ms (late): %s", (now - window_t0) * 1000, (#ch > 0) and table.concat(ch, " | ") or "(back at baseline)"))
                -- Hold the rest of the settle so the next call starts from a still pawn.
                base = nil
                next_at = window_t0 + SETTLE_S
                return
            end
            begin_step(ghost)
        end
    end
end

out("loaded -- " .. OUT_PATH)
LoopAsync(TICK_MS, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(tick)
        if not ok then out("tick error: " .. tostring(err)) end
    end)
    return false
end)
LoopAsync(1000, function()
    flush()
    return false
end)
