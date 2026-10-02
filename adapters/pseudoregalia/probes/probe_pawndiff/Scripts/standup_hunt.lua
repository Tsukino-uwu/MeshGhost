-- Calling probe beside the C++ drive rig (ghost_drive.txt armed, stand_fn empty): on the false->true edge of
-- hasMovementInput? on the driven pawn while moveState == 8, calls the stand-up candidate the toggle file names,
-- then reads back moveState, MovementMode, Interaction Target and the montage at +0/+100/+500 ms.
--
--     <scratch slot>\standup_hunt.txt        (beside Scripts\, re-read every second)
--        fn=tryFinishHeal        the UFunction's name
--        on=pawn                 pawn | chair   (the chair is the pawn's `Interaction Target`)
--        arg=none                none | counterpart | <literal>   (counterpart = the chair for a pawn
--                                function, the pawn for a chair function; one object argument)
--        then_fn= / then_arg=    a second call on the pawn right after the first
--
-- Edge-triggered only: a seated walk (the table glitch) has no edge. Signatures are read by property class
-- name, never GetPropertyClass()/GetStruct(), which crash; a call whose object parameters do not fit arg is
-- refused (a zero-filled actor parameter is a null dereference in the Blueprint VM). Restore the stub after.

local TAG = "[MeshGhostStandHunt]"
local PAWN_FNS = { "EndInteract", "BPI_EndInteract", "BPI_TryInteract", "BPI_InteractConfirm", "exitTransition",
                   "enterTransition", "trySitHeal", "tryFinishHeal", "healPlayer", "healDing",
                   "change Move State", "onMoveStateChange", "change Action State", "onActionStateChange",
                   "changeControlState", "resetControlState", "setInputVariables", "customStopMontage",
                   "setStateUptimes", "timedResetControlVariables" }
local CHAIR_FNS = { "BPI_EndInteract", "BPI_TryInteract", "BPI_InteractConfirm" }

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local TOGGLE_PATH = scriptDir() .. "../standup_hunt.txt"

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

local function find_fn(obj, name)
    local found = nil
    local cls = obj:GetClass()
    while cls and cls:IsValid() and not found do
        cls:ForEachFunction(function(fn)
            if not found and fname_str(fn) == name then found = fn end
        end)
        local sup = nil
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and sup ~= cls and sup:IsValid() then cls = sup else cls = nil end
    end
    return found
end
-- A Blueprint UFunction's property list carries its locals beside its parameters; only the rest are inputs.
local function is_local(name)
    return name:find("^CallFunc_") or name:find("^K2Node_") or name:find("^Temp_")
end
local function signature(fn)
    local parts, objects, count, locals = {}, 0, 0, 0
    fn:ForEachProperty(function(p)
        local n, t = fname_str(p), "?"
        pcall(function() t = p:GetClass():GetFName():ToString() end)
        if is_local(n) then
            locals = locals + 1
        else
            count = count + 1
            if t == "ObjectProperty" then objects = objects + 1 end
            parts[#parts + 1] = n .. ":" .. t
        end
    end)
    return "[" .. table.concat(parts, ", ") .. "] +" .. locals .. " local(s)", count, objects
end

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

local cfg = { fn = "", on = "pawn", arg = "none", text = nil }
local function read_toggle()
    local f = io.open(TOGGLE_PATH, "r")
    if not f then
        if cfg.text ~= nil then log("toggle file gone -- calling nothing") end
        cfg = { fn = "", on = "pawn", arg = "none", text = nil }
        return
    end
    local text = f:read("a") or ""
    f:close()
    if text == cfg.text then return end
    local new = { fn = "", on = "pawn", arg = "none", text = text }
    for line in text:gmatch("[^\r\n]+") do
        local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
        if k == "fn" then new.fn = v elseif k == "on" then new.on = v elseif k == "arg" then new.arg = v
        elseif k == "then_fn" then new.then_fn = v elseif k == "then_arg" then new.then_arg = v end
    end
    cfg = new
    log(string.format("toggle: fn=%q on=%s arg=%s", cfg.fn, cfg.on, cfg.arg))
end

local driven, driven_addr = nil, nil
local last_input = nil
local player_last_ms = nil
local ticks = 0
local pending = {}
local signatures_done = false

-- The engine's own native getters on a live anim instance: a state can leave 8 with the sit montage still on.
local function montage_text(pawn)
    local mesh = prop(pawn, "Mesh")
    if mesh == nil or not valid(mesh) then return "mesh=?" end
    local anim = prop(mesh, "AnimScriptInstance")
    if anim == nil or not valid(anim) then return "anim=none" end
    local playing, name = "?", "none"
    pcall(function() playing = tostring(anim:IsAnyMontagePlaying()) end)
    pcall(function()
        local m = anim:GetCurrentActiveMontage()
        if m ~= nil and valid(m) then name = fname_str(m) end
    end)
    return string.format("montage_playing=%s montage=%s", playing, name)
end
local function readback(pawn, label)
    local target = prop(pawn, "Interaction Target")
    local tname = (target ~= nil and valid(target)) and fname_str(target) or "none"
    local mv = prop(pawn, "CharacterMovement")
    local mm = mv and tostring(prop(mv, "MovementMode")) or "?"
    log(string.format("%s: moveState=%s actionState=%s MovementMode=%s InteractionTarget=%s hasMovementInput?=%s %s", label,
        tostring(prop(pawn, "moveState")), tostring(prop(pawn, "actionState")), mm, tname,
        tostring(prop(pawn, "hasMovementInput?")), montage_text(pawn)))
end

local pawn_signatures_done = false
local function log_signatures(pawn)
    if not pawn_signatures_done then
        pawn_signatures_done = true
        for _, n in ipairs(PAWN_FNS) do
            local fn = find_fn(pawn, n)
            if fn then
                local sig, count, objects = signature(fn)
                log(string.format("pawn.%s: %d param(s), %d object(s) %s", n, count, objects, sig))
            else
                log("pawn." .. n .. ": NOT FOUND")
            end
        end
    end
    local chair = prop(pawn, "Interaction Target")
    if chair ~= nil and valid(chair) then
        for _, n in ipairs(CHAIR_FNS) do
            local fn = find_fn(chair, n)
            if fn then
                local sig, count, objects = signature(fn)
                log(string.format("chair(%s).%s: %d param(s), %d object(s) %s", fname_str(chair), n, count, objects, sig))
            else
                log("chair." .. n .. ": NOT FOUND")
            end
        end
    else
        log("no Interaction Target on the pawn yet -- chair signatures deferred")
        return false
    end
    return true
end

local function fire(pawn)
    if cfg.fn == "" then
        log("rising edge while seated -> no fn configured (toggle file), nothing called")
        return
    end
    local target = prop(pawn, "Interaction Target")
    local chair = (target ~= nil and valid(target)) and target or nil
    local on, counterpart, on_name
    if cfg.on == "chair" then
        if not chair then log("rising edge while seated -> on=chair but the pawn has no Interaction Target; nothing called") return end
        on, counterpart, on_name = chair, pawn, "chair " .. fname_str(chair)
    else
        on, counterpart, on_name = pawn, chair, "pawn"
    end
    local fn = find_fn(on, cfg.fn)
    if not fn then log(string.format("rising edge while seated -> %s.%s NOT FOUND; nothing called", on_name, cfg.fn)) return end
    local sig, count, objects = signature(fn)
    local ok, err
    if cfg.arg == "counterpart" then
        if objects ~= 1 or count ~= 1 then
            log(string.format("rising edge while seated -> %s.%s REFUSED for arg=counterpart: %d param(s), %d object(s) %s", on_name, cfg.fn, count, objects, sig))
            return
        end
        if not counterpart then log("rising edge while seated -> arg=counterpart but there is none; nothing called") return end
        ok, err = pcall(function() on[cfg.fn](on, counterpart) end)
    elseif cfg.arg == "true" or cfg.arg == "false" or tonumber(cfg.arg) then
        -- One literal argument (a bool or a number) for a function whose single input is one.
        local literal = (cfg.arg == "true") and true or ((cfg.arg == "false") and false or tonumber(cfg.arg))
        if count ~= 1 or objects ~= 0 then
            log(string.format("rising edge while seated -> %s.%s REFUSED for arg=%s: %d param(s), %d object(s) %s", on_name, cfg.fn, cfg.arg, count, objects, sig))
            return
        end
        ok, err = pcall(function() on[cfg.fn](on, literal) end)
    else
        if objects > 0 then
            log(string.format("rising edge while seated -> %s.%s REFUSED for arg=none: it has an object parameter %s", on_name, cfg.fn, sig))
            return
        end
        ok, err = pcall(function() on[cfg.fn](on) end)
    end
    log(string.format("rising edge while seated (moveState=8) -> %s.%s(%s) %s", on_name, cfg.fn, cfg.arg,
        ok and "called" or ("FAILED " .. tostring(err))))
    -- then_arg=none|<number>|true|false; same refusals as the first call.
    if cfg.then_fn and cfg.then_fn ~= "" then
        local fn2 = find_fn(pawn, cfg.then_fn)
        if not fn2 then
            log("  then: pawn." .. cfg.then_fn .. " NOT FOUND; nothing called")
        else
            local sig2, count2, objects2 = signature(fn2)
            local a = cfg.then_arg or "none"
            local ok2, err2
            if a == "none" then
                if objects2 > 0 then log("  then: REFUSED, object parameter " .. sig2) else ok2, err2 = pcall(function() pawn[cfg.then_fn](pawn) end) end
            elseif count2 == 1 and objects2 == 0 then
                local lit = (a == "true") and true or ((a == "false") and false or tonumber(a))
                ok2, err2 = pcall(function() pawn[cfg.then_fn](pawn, lit) end)
            else
                log(string.format("  then: REFUSED for then_arg=%s: %d param(s) %s", a, count2, sig2))
            end
            if ok2 ~= nil then log(string.format("  then: pawn.%s(%s) %s", cfg.then_fn, a, ok2 and "called" or ("FAILED " .. tostring(err2)))) end
        end
    end
    readback(pawn, "  +0ms")
    pending[#pending + 1] = { at_tick = ticks + 2, pawn = pawn, label = "  +100ms" }
    pending[#pending + 1] = { at_tick = ticks + 10, pawn = pawn, label = "  +500ms" }
end

log("loaded -- candidate stand-up call on the rising edge of hasMovementInput? while seated, driven pawn only; toggle: " .. TOGGLE_PATH)
read_toggle()

LoopAsync(50, function()
    ticks = ticks + 1
    if ticks % 20 == 1 then read_toggle() end
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
                log(string.format("watching driven pawn %s (player is %s)", fname_str(found), fname_str(me)))
            elseif not found then
                driven, driven_addr = nil, nil
            end
            if not signatures_done and found then
                signatures_done = log_signatures(found)
            end
        end
    end
    -- The player's own sit and stand, read-only, for comparison: what the game itself does to the montage.
    local me_now = player_pawn()
    if me_now then
        local pms = prop(me_now, "moveState")
        if player_last_ms ~= nil and pms ~= player_last_ms then
            log(string.format("PLAYER moveState %s -> %s", tostring(player_last_ms), tostring(pms)))
            readback(me_now, "  PLAYER +0ms")
            -- Every 50 ms for 600 ms: the ghost's montage stop has to match the blend-out's length.
            for step = 1, 12 do
                pending[#pending + 1] = { at_tick = ticks + step, pawn = me_now, label = string.format("  PLAYER +%dms", step * 50) }
            end
        end
        player_last_ms = pms
    end
    local keep = {}
    for _, d in ipairs(pending) do
        if ticks >= d.at_tick then
            if valid(d.pawn) then readback(d.pawn, d.label) end
        else
            keep[#keep + 1] = d
        end
    end
    pending = keep
    if not (driven and valid(driven)) then return false end
    local input = prop(driven, "hasMovementInput?")
    local ms = prop(driven, "moveState")
    if last_input == false and input == true and ms == 8 then
        local ok, err = pcall(fire, driven)
        if not ok then log("fire error: " .. tostring(err)) end
    end
    last_input = input
    return false
end)
