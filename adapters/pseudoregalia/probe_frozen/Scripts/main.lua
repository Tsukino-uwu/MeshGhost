-- MeshGhost FROZEN-PLAYER signal probe. 2026-09-05, for ADR 0053.
--
-- THE QUESTION. The game holds the player still for an item popup and for the pause menu, and
-- probe_pickup (2026-09-04) proved that NOTHING the adapter samples marks it: 110 seconds of
-- byte-identical loc / h=550 / v=-290 / MovementMode=3 across a popup. The chaser now runs on a
-- clock the adapter can stop with a `player_frozen` message -- so what is the game's OWN fact
-- that says "frozen, not gameplay"? Not "the position stopped changing": that fires on a wall-hug
-- and fires late.
--
-- WHAT IT READS, all by NAME, all property reads, no UFunction on anything FindAllOf returned (that
-- crashed live sessions twice) and no ForEachProperty (banned in an armed probe; a blind walk
-- crashed three live sessions on 2026-08-29). Three families of candidate, so the answer can come
-- from whichever the game actually uses:
--
--   ENGINE PAUSE   WorldSettings.PauserPlayerState (the engine's own "who paused") and TimeDilation
--                  -- if the pause menu calls the engine's pause, this is the whole answer.
--                  probe_menuwatch read a field spelled `Pauser`, which may never have resolved;
--                  BOTH spellings are read here and the COVERAGE line says which exists.
--   INPUT GATES    PlayerController.IgnoreMoveInput / IgnoreLookInput (counters), bCinematicMode,
--                  bCinemaDisableInputMove / Look, bShowMouseCursor, bBlockInput, and the pawn's
--                  bBlockInput / CustomTimeDilation -- the usual ways a UE game freezes a player
--                  WITHOUT pausing the world, which is what a popup over a still-animating scene
--                  looks like.
--   WIDGETS        every live UserWidget's class name and its Visibility -- a popup and a pause
--                  menu are UMG widgets, so the set of visible widgets changing IS the event, and
--                  the widget's own name is a candidate signal the adapter could read back.
--
-- Property names are from the Unreal Engine API reference for APlayerController, AController,
-- AActor, AWorldSettings and UWidget (dev.epicgames.com/documentation, the per-class pages); the
-- probe does not assume any of them exists on THIS build -- a name that does not resolve is
-- reported in COVERAGE, never silently skipped. The measured names (BP_PlayerGoatMain_C,
-- CharacterMovement, horizontalSpeed, verticalSpeed) are this repo's own PLAYER_FIELDS.md.
--
-- NO WINDOW TO HIT. Everything logs ON CHANGE plus a few seconds of per-sample lines either side
-- of any change. Do these, in any order, taking as long as you like between them:
--   1. stand still a few seconds (baseline)
--   2. pick an item up, read the popup a while, press continue
--   3. open the PAUSE MENU, wait a few seconds, close it
--   4. do a ZONE TRANSITION
-- The log then shows, per event, which candidate moved and which did not.
--
-- COST: one FindAllOf per class per sample at 10Hz (4 classes), plus one Visibility read per live
-- widget; names are looked up ONCE per widget address and cached. Say if the game stutters -- the
-- cost is what you feel, not what the log says. UNLOAD IT AFTERWARDS (restore probe_scratch's
-- stub): a loaded probe is a suspect in every later report.

local TAG = "[MeshGhostFrozen]"
local INTERVAL_MS = 100
local CONTEXT_SAMPLES = 30

local last = {}
local samples = 0
local context_left = 0
local missing = {}
local seen_any = {}
local widget_names = {} -- address -> short class name, looked up once
local census_done = false

local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n
end

local function short(n)
    if not n then return "<nil>" end
    return n:match("([%w_]+_C_%d+)") or n:match("([^%.:%s]+)$") or n
end

local function class_short(n)
    -- GetFullName is "<ClassName> <outer path>:<object name>": the CLASS is the first token. The
    -- first version matched inside the path and named every widget after the GameEngine object
    -- that outers them all (first live run, 2026-09-05), which said nothing.
    if not n then return "<nil>" end
    return n:match("^(%S+)") or short(n)
end

local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end

-- A named read that keeps score: a field that never resolves is part of the answer.
local function read(obj, name, key)
    local v = prop(obj, name)
    if v == nil then
        if not seen_any[key] then missing[key] = true end
    else
        seen_any[key] = true
        missing[key] = nil
    end
    return v
end

local function first_live(class_name)
    local all = FindAllOf(class_name)
    if not all then return nil end
    for _, o in pairs(all) do
        local ok, valid = pcall(function() return o:IsValid() end)
        if ok and valid then
            local n = full_name(o)
            if n and not n:find("Default__") then return o end
        end
    end
    return nil
end

local function vec_text(v)
    if not v then return "?" end
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if x == nil then return "?" end
    return string.format("%.0f,%.0f,%.0f", x, y, z)
end

local function num(v)
    local n = tonumber(v)
    if n == nil then return -999999 end
    return n
end

-- A value UE4SS hands back as a WRAPPER (bitfield bools and some ints come back as a userdata, a
-- fresh one every read, whose tostring is its address) would otherwise "change" every sample. Try
-- the wrapper's own get(), else name the type once and stop: an unreadable field is a COVERAGE
-- fact, not an event. First live run 2026-09-05 spammed exactly this at 10Hz for five fields.
local function plain(value)
    local t = type(value)
    if t == "boolean" or t == "number" or t == "string" or t == "nil" then return tostring(value) end
    if t == "userdata" then
        local got
        if pcall(function() got = value:get() end) and got ~= nil and type(got) ~= "userdata" then
            return tostring(got)
        end
        -- The five controller gates came back as a UObject wrapper on this build (2026-09-05),
        -- which is what UE4SS hands back for a name it could NOT resolve as a property: an INVALID
        -- object. Say so, rather than printing an address that means nothing.
        local okv, valid = pcall(function() return value:IsValid() end)
        if okv and valid == false then return "<unresolved>" end
        local ok, tn = pcall(function() return value:type() end)
        return "<userdata " .. tostring(ok and tn or "?") .. ">"
    end
    return "<" .. t .. ">"
end

local function on_change(key, value)
    value = plain(value)
    if last[key] ~= value then
        local was = last[key]
        last[key] = value
        if was ~= nil then
            print(string.format("%s CHANGE %s: %s -> %s  t=%.1f s=%d\n", TAG, key, tostring(was), value, os.clock(), samples))
            context_left = CONTEXT_SAMPLES
        elseif census_done then
            print(string.format("%s FIRST %s = %s  t=%.1f s=%d\n", TAG, key, value, os.clock(), samples))
            context_left = CONTEXT_SAMPLES
        end
    end
end

-- The widget census: the set of live, non-default UserWidgets with each one's Visibility. Keyed
-- by address so the name lookup happens once per widget; Visibility is read every sample because
-- a pre-built pause menu is TOGGLED, not created, and a count alone would never see it.
-- ESlateVisibility, per the UE reference: 0 Visible, 1 Collapsed, 2 Hidden, 3 HitTestInvisible,
-- 4 SelfHitTestInvisible. Logged raw.
local function widget_signature()
    local all = FindAllOf("UserWidget")
    if not all then return "<no UserWidget instances>", 0 end
    local parts = {}
    local n = 0
    for _, w in pairs(all) do
        local ok, valid = pcall(function() return w:IsValid() end)
        if ok and valid then
            local addr
            pcall(function() addr = w:GetAddress() end)
            if addr then
                local name = widget_names[addr]
                if not name then
                    local fn = full_name(w)
                    if fn and fn:find("Default__") then
                        name = false
                    else
                        name = class_short(fn)
                    end
                    widget_names[addr] = name
                end
                if name then
                    n = n + 1
                    parts[#parts + 1] = name .. "=" .. tostring(read(w, "Visibility", "UserWidget.Visibility"))
                end
            end
        end
    end
    table.sort(parts)
    return table.concat(parts, " "), n
end

local function sample()
    samples = samples + 1
    local pawn = first_live("BP_PlayerGoatMain_C")
    local pc = first_live("PlayerController")
    local ws = first_live("WorldSettings")

    if not pawn then
        if samples % 100 == 1 then
            print(string.format("%s no player pawn (title screen / loading) pc=%s ws=%s s=%d\n", TAG,
                pc and "yes" or "no", ws and "yes" or "no", samples))
        end
        -- A transition is exactly when the pawn is absent, so the engine-side reads still run.
    end

    -- ENGINE PAUSE
    if ws then
        local pps = read(ws, "PauserPlayerState", "WorldSettings.PauserPlayerState")
        on_change("ws.PauserPlayerState", pps and short(full_name(pps)) or "<none>")
        local pauser = read(ws, "Pauser", "WorldSettings.Pauser")
        on_change("ws.Pauser", pauser and short(full_name(pauser)) or "<none>")
        on_change("ws.TimeDilation", read(ws, "TimeDilation", "WorldSettings.TimeDilation"))
    end

    -- INPUT GATES on the controller
    if pc then
        on_change("pc.IgnoreMoveInput", read(pc, "IgnoreMoveInput", "PlayerController.IgnoreMoveInput"))
        on_change("pc.IgnoreLookInput", read(pc, "IgnoreLookInput", "PlayerController.IgnoreLookInput"))
        on_change("pc.bCinematicMode", read(pc, "bCinematicMode", "PlayerController.bCinematicMode"))
        on_change("pc.bCinemaDisableInputMove", read(pc, "bCinemaDisableInputMove", "PlayerController.bCinemaDisableInputMove"))
        on_change("pc.bCinemaDisableInputLook", read(pc, "bCinemaDisableInputLook", "PlayerController.bCinemaDisableInputLook"))
        on_change("pc.bShowMouseCursor", read(pc, "bShowMouseCursor", "PlayerController.bShowMouseCursor"))
        on_change("pc.bBlockInput", read(pc, "bBlockInput", "PlayerController.bBlockInput"))
        local ppawn = read(pc, "Pawn", "PlayerController.Pawn")
        on_change("pc.Pawn", ppawn and short(full_name(ppawn)) or "<none>")
    end

    -- THE PAWN: the fields probe_pickup proved frozen, plus its own two gates.
    local moved = "?"
    if pawn then
        on_change("pawn.bBlockInput", read(pawn, "bBlockInput", "Pawn.bBlockInput"))
        on_change("pawn.CustomTimeDilation", read(pawn, "CustomTimeDilation", "Pawn.CustomTimeDilation"))
        local cm = read(pawn, "CharacterMovement", "Pawn.CharacterMovement")
        if cm then
            on_change("pawn.MovementMode", prop(cm, "MovementMode"))
        end
        local root = prop(pawn, "RootComponent")
        local loc = vec_text(root and prop(root, "RelativeLocation"))
        moved = tostring(last["__loc"] ~= nil and last["__loc"] ~= loc)
        last["__loc"] = loc
        if context_left > 0 or samples % 50 == 1 then
            print(string.format("%s TRACK loc=%s moved=%s h=%.1f v=%.1f mode=%s dil=%s ignoreMove=%s s=%d\n",
                TAG, loc, moved,
                num(read(pawn, "horizontalSpeed", "Pawn.horizontalSpeed")),
                num(read(pawn, "verticalSpeed", "Pawn.verticalSpeed")),
                tostring(cm and prop(cm, "MovementMode")),
                tostring(ws and prop(ws, "TimeDilation")),
                tostring(pc and prop(pc, "IgnoreMoveInput")), samples))
        end
    end

    -- WIDGETS: only the DIFF is printed. Three hundred live widgets make a full signature
    -- unreadable and the log truncates it; what changed is the whole question.
    local sig, count = widget_signature()
    if last["__widgets"] ~= sig then
        if last["__widgets"] ~= nil or census_done then
            local before, after = {}, {}
            for part in (last["__widgets"] or ""):gmatch("%S+") do before[part] = (before[part] or 0) + 1 end
            for part in sig:gmatch("%S+") do after[part] = (after[part] or 0) + 1 end
            local gone, came = {}, {}
            for k, v in pairs(before) do
                local d = v - (after[k] or 0)
                if d > 0 then gone[#gone + 1] = k .. (d > 1 and ("x" .. d) or "") end
            end
            for k, v in pairs(after) do
                local d = v - (before[k] or 0)
                if d > 0 then came[#came + 1] = k .. (d > 1 and ("x" .. d) or "") end
            end
            table.sort(gone); table.sort(came)
            print(string.format("%s WIDGETS (%d live) -%s +%s  t=%.1f s=%d\n", TAG, count,
                (#gone > 0) and table.concat(gone, ",") or "none",
                (#came > 0) and table.concat(came, ",") or "none", os.clock(), samples))
            context_left = CONTEXT_SAMPLES
        end
        last["__widgets"] = sig
    end

    if context_left > 0 then context_left = context_left - 1 end

    -- BASELINE CENSUS, once a pawn exists: every candidate's resting value, and what did not resolve.
    if pawn and not census_done then
        census_done = true
        print(string.format("%s ===== BASELINE -- pawn exists; this is the UNFROZEN state =====\n", TAG))
        local keys = {}
        for k in pairs(last) do
            if k:sub(1, 2) ~= "__" then keys[#keys + 1] = k end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            print(string.format("%s BASE %s = %s\n", TAG, k, tostring(last[k])))
        end
        print(string.format("%s BASE widgets (%d live): %s\n", TAG, count, sig))
        local unresolved = {}
        for k in pairs(missing) do unresolved[#unresolved + 1] = k end
        table.sort(unresolved)
        print(string.format("%s COVERAGE: %d named field(s) did not resolve on this build%s\n", TAG,
            #unresolved, (#unresolved > 0) and (": " .. table.concat(unresolved, ", ")) or ""))
        print(string.format("%s ===== now: item popup, pause menu, zone transition -- any order, no rush =====\n", TAG))
    end

    if samples % 100 == 1 then
        print(string.format("%s watching pawn=%s pc=%s ws=%s widgets=%d s=%d t=%.1f\n", TAG,
            pawn and "yes" or "no", pc and "yes" or "no", ws and "yes" or "no", count, samples, os.clock()))
    end
end

LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- stand still a moment, then: item popup, pause menu, zone transition. Everything logs on change; no window to hit.\n", TAG))
