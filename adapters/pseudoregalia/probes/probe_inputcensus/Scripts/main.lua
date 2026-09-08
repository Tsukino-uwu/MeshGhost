-- MeshGhost INPUT API CENSUS -- which way of reading what the player PRESSED actually works on
-- this build. The adapter half of ADR 0056 (the input track): the Go side records an
-- `input_sample` from any adapter, and no adapter sends one yet because `Plugin.cpp` has no input
-- read anywhere in it. This probe decides where the read comes from before a line of C++ is
-- written. Two stages, run as two reloads of the scratch slot; the second is the one that CALLS.
--
-- THE CANDIDATES, ranked by the plan (`ADR 0056`, "The open half"):
--   C  the pawn's own input-derived Blueprint properties. `jumpButtonHeld?`, `wallRideButtonHeld?`,
--      `hasMovementInput?`, `inputVectorWorld`, `moveInputAmount` all exist (the 2026-09-06 player
--      dump, `probe_dump/`), plus the engine's `Pawn.ControlInputVector` / `LastControlInputVector`
--      and `Character.bPressedJump`. Named reads, no call. Weakness: nothing named for attack,
--      crouch or throw was in that dump -- so C alone is probably PARTIAL, and that is the first
--      thing this census measures.
--   E  Enhanced Input's merged action state. This game IS Enhanced Input (its pawn has
--      `InpActEvt_IA_Crouch_K2Node_EnhancedInputActionEvent_15/_16`, `..._IA_Throw_...`;
--      `documentation.md`, `VERIFIED.md:1864`), so the game's own already-merged, rebind-proof
--      per-action value is `UEnhancedInputLibrary::GetBoundActionValue(Actor, Action)` -- a
--      BlueprintPure static (dev.epicgames.com, UEnhancedInputLibrary), i.e. a reflected UFunction
--      on the library's default object, taking two OBJECT pointers and no struct by value. The
--      action assets are `IA_*` (`FindAllOf("InputAction")`); the key->action table is each loaded
--      `InputMappingContext`'s `Mappings`. Stage 2 calls it.
--   A  `APlayerController::IsInputKeyDown(FKey)` / `WasInputKeyJustPressed` /
--      `GetInputAnalogKeyState` (dev.epicgames.com, APlayerController). Needs an FKey built by
--      hand; UE4SS fills a StructProperty parameter from a Lua table by field name
--      (`RE-UE4SS/UE4SS/src/LuaType/LuaUObject.cpp`, push_structproperty -> lua_table_to_memory),
--      and FKey's one reflected field is `KeyName`. Stage 2 calls it, AFTER E.
--   B  `UPlayerInput`'s key-state map: not a UPROPERTY, ruled out on paper; stage 1 dumps the
--      PlayerInput's property names anyway so the ruling is measured, not assumed.
--   D  raw OS keys: rejected by the ADR (records outside the game, ignores rebinding). Not tried.
--
-- STAGE 1 (this file as shipped, STAGE = 1) -- READ-ONLY, NO UFUNCTION IS CALLED ON ANYTHING.
--   1. A census to a file: the PlayerController's class chain with EVERY function name (flags:
--      native / BP / pure / static) and every parameter's name and type; the same for the pawn
--      (`BP_PlayerGoatMain_C` -- its `InpActEvt_*` functions ARE the action vocabulary) and for the
--      controller's `PlayerInput` object (option B's ruling); every property name + type on the
--      three chains; every loaded `InputAction` asset; every loaded `InputMappingContext` with its
--      `Mappings` (action name + `Key.KeyName`); and the legacy `InputSettings` default object's
--      `ActionMappings`/`AxisMappings`, for completeness. NO FILTER: everything is written, the
--      grep happens afterwards (`checklists/before-a-probe.md`).
--   2. A LIVE on-change log at 20 Hz on the game thread: every BoolProperty on the pawn's chain
--      (named at census time -- a named read of a scalar, never an object-valued property), a
--      short named list of ints / floats / vectors that the dump says are input-shaped, and the
--      engine's control input vectors. A one-frame press can slip between 50 ms samples; the
--      protocol below HOLDS every input, so what this stage measures is WHICH field moves for
--      WHICH action, not edge timing. Edge timing is the C++ half's job at frame rate.
--
-- STAGE 2 (STAGE = 2, a second reload once stage 1's file is on disk) -- THE CALLS.
--   Per sample, additionally: E for every loaded `IA_*` action (on the local player pawn only --
--   the one the controller names); A for every key the mapping census found bound (bounded), plus
--   the analog state of any axis-shaped key. Each path is pcall'd and DISARMS ITSELF on its first
--   Lua error, logging the error once; a path that never resolved is reported in COVERAGE. This
--   is the stage that can crash the game (a struct marshalled wrong is a native fault no pcall
--   sees), which is why it is separate and why stage 1's answers are already saved when it runs.
--
-- PROTOCOL FOR THE PERSON AT THE GAME -- endurance, not timing (`probes.md`, the standing rule).
-- Load in gameplay (not the title screen). When the log says READY, in this order, taking as long
-- as you like between steps -- hold each ~3 seconds, release, wait ~2 seconds:
--    1 stand still      2 JUMP (hold)     3 ATTACK (hold)     4 CROUCH / slide (hold)
--    5 move LEFT        6 move RIGHT      7 move UP (forward) 8 move DOWN (back)
--    9 camera LEFT     10 camera RIGHT   11 CLING (the wall-ride button, against a wall)
--   12 THROW the weapon (if you have it)  13 open the PAUSE MENU, wait, close it
-- Any order is fine; say the order afterwards if it differed. Then say whether that was keyboard
-- or gamepad -- both, one after the other, is the ideal run.
--
-- COST. Census: one walk of three class chains, once, on load. Live: ~130 named property reads
-- per sample at 20 Hz (~2,600 reads/s); the probe prints its OWN cost every 100 samples (ms per
-- sample, game thread) so the reading and its price sit on one line. Stage 2 adds one UFunction
-- call per action and per bound key per sample. UNLOAD AFTERWARDS (restore probe_scratch's stub):
-- a loaded probe is a suspect in every later report.
--
-- Output: `input_census-stage<N>-<HHMMSS>.log` beside this mod's Scripts folder, buffered and
-- flushed once a second (never a write per line); the same lines go to UE4SS.log under the TAG.
-- Read-only in stage 1; stage 2 calls BlueprintPure / const getters only. Nothing is written to
-- the game, a save or memory. Dev-only tooling; never ships.

-- RESULTS, 2026-09-08 (one session, keyboard then gamepad; the verdict lives in ../../UNVERIFIED.md):
--   A  WORKS end to end -- 118,000 IsInputKeyDown/GetInputAnalogKeyState calls with {KeyName=FName(k)},
--      every mapped key seen down and up in step with the pawn. GetInputVectorKeyState exists (untried).
--   E  CALLABLE and SAFE (55,000 calls, no fault) but the FInputActionValue comes back as an EMPTY
--      table: no reflected fields, so its value is a C++ question. ActionInstanceData IS reflected here.
--   C  PARTIAL: jump, cling, move, crouch, throw have pawn fields; look, interact, guard, lock-on,
--      power, pause do not. B confirmed unreflected. Cost 3-4.8 ms/sample at 20 Hz in stage 2.
--   The first run's census walked ONE entry per class -- see the RETURN NOTHING comment below.

local STAGE = 1

local TAG = "[MeshGhostInputCensus]"
local INTERVAL_MS = 50
local FLUSH_MS = 1000
local PAWN_CLASS = "BP_PlayerGoatMain_C"
local MAX_MAPPED_KEYS = 48
local AXIS_QUANT = 1 / 64

-- EFunctionFlags, from the vendored headers (RE-UE4SS/deps/first/Unreal/include/Unreal/UnrealFlags.hpp:355-373).
local FUNC_Native, FUNC_Static, FUNC_BlueprintCallable, FUNC_BlueprintEvent, FUNC_BlueprintPure =
    0x400, 0x2000, 0x4000000, 0x8000000, 0x10000000

-- Option C's named non-bool reads. Names from the 2026-09-06 player dump; a name that does not
-- resolve is a COVERAGE fact, never an error.
local NAMED_SCALARS = { "moveInputAmount", "jumpType", "animJumpType", "attackComboPosition", "moveState", "actionState" }
local NAMED_VECTORS = { "inputVectorWorld", "ControlInputVector", "LastControlInputVector" }

---------------------------------------------------------------------------- plumbing

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local MOD_ROOT = scriptDir() .. "../"
local OUT_PATH = string.format("%sinput_census-stage%d-%s.log", MOD_ROOT, STAGE, os.date("%H%M%S"))

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
local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n
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

-- A UE4SS read can come back as a wrapper (bitfield bools, some ints), a fresh userdata per read
-- whose tostring is its address; unwrap through get() or name the type once (probe_frozen, 2026-09-05).
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
    if type(x) ~= "number" then return plain(v) end
    local q = function(n) return string.format("%.3f", math.floor(n / AXIS_QUANT + 0.5) * AXIS_QUANT) end
    return q(x) .. "," .. q(y) .. "," .. q(z or 0)
end

-- The controller is the authority on which pawn is the player (a ghost reads as possessed too;
-- `pitfalls/method.md`, 2026-09-04).
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

---------------------------------------------------------------------------- stage 1: the census

local function class_chain(obj)
    local chain = {}
    local cls
    pcall(function() cls = obj:GetClass() end)
    while cls and valid(cls) do
        chain[#chain + 1] = cls
        local sup
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and valid(sup) and sup ~= cls then cls = sup else cls = nil end
    end
    return chain
end

local function flag_text(flags)
    local t = {}
    if flags & FUNC_Native ~= 0 then t[#t + 1] = "native" else t[#t + 1] = "BP" end
    if flags & FUNC_Static ~= 0 then t[#t + 1] = "static" end
    if flags & FUNC_BlueprintPure ~= 0 then t[#t + 1] = "pure" end
    if flags & FUNC_BlueprintCallable ~= 0 then t[#t + 1] = "callable" end
    if flags & FUNC_BlueprintEvent ~= 0 then t[#t + 1] = "event" end
    return table.concat(t, ",")
end

-- Every function on one class, with its parameters' names and property types. Enumerating a
-- CLASS's functions reads class metadata only; no instance is dereferenced.
-- THE CALLBACKS RETURN NOTHING: UE4SS stops the walk on ANY returned value, `false` included --
-- the first live run (2026-09-08) got exactly one function and one property per class from
-- `return false`, and the docs' "return true to stop" reads as if false were safe. It is not.
local function census_functions(cls, label)
    local n = 0
    pcall(function()
        cls:ForEachFunction(function(fn)
            n = n + 1
            local flags = 0
            pcall(function() flags = fn:GetFunctionFlags() end)
            local params = {}
            pcall(function()
                fn:ForEachProperty(function(p)
                    local ptype = "?"
                    pcall(function() ptype = p:GetClass():GetFName():ToString() end)
                    local extra = ""
                    if ptype == "StructProperty" then
                        pcall(function() extra = "<" .. p:GetStruct():GetFName():ToString() .. ">" end)
                    elseif ptype == "ObjectProperty" then
                        pcall(function() extra = "<" .. p:GetPropertyClass():GetFName():ToString() .. ">" end)
                    end
                    params[#params + 1] = fname_str(p) .. ":" .. ptype .. extra
                end)
            end)
            out(string.format("FUNC %s.%s [%s] (%s)", label, fname_str(fn), flag_text(flags), table.concat(params, ", ")))
        end)
    end)
    return n
end

-- Every property on one class: name and type only. Returns the BoolProperty names for the live
-- phase (the one kind of walk that is safe: names, never values).
local function census_properties(cls, label, bools)
    local n = 0
    pcall(function()
        cls:ForEachProperty(function(p)
            n = n + 1
            local pname = fname_str(p)
            local ptype = "?"
            pcall(function() ptype = p:GetClass():GetFName():ToString() end)
            local extra = ""
            if ptype == "StructProperty" then
                pcall(function() extra = "<" .. p:GetStruct():GetFName():ToString() .. ">" end)
            elseif ptype == "ObjectProperty" then
                pcall(function() extra = "<" .. p:GetPropertyClass():GetFName():ToString() .. ">" end)
            end
            out(string.format("PROP %s.%s %s%s", label, pname, ptype, extra))
            if ptype == "BoolProperty" and bools then bools[#bools + 1] = pname end
        end)
    end)
    return n
end

local function census_object(obj, what, bools)
    local chain = class_chain(obj)
    local names = {}
    for _, c in ipairs(chain) do names[#names + 1] = fname_str(c) end
    out(string.format("CHAIN %s: %s  (%s)", what, table.concat(names, " > "), full_name(obj) or "?"))
    local fn_total, prop_total = 0, 0
    for _, c in ipairs(chain) do
        local label = fname_str(c)
        fn_total = fn_total + census_functions(c, label)
        prop_total = prop_total + census_properties(c, label, bools)
    end
    out(string.format("CHAIN %s: %d classes, %d functions, %d properties", what, #chain, fn_total, prop_total))
end

-- Enhanced Input: the loaded action assets and the mapping contexts' key->action table. The
-- `Action` of a mapping is an asset reference held by a loaded data asset -- followed only after
-- IsValid, only for its name.
local function census_enhanced_input()
    local actions = FindAllOf("InputAction")
    local count = 0
    if actions then
        for _, a in pairs(actions) do
            if valid(a) then
                local n = full_name(a) or "?"
                if not n:find("Default__") then
                    count = count + 1
                    local vt = plain(prop(a, "ValueType"))
                    out(string.format("IA %s ValueType=%s", n, tostring(vt)))
                end
            end
        end
    end
    out(string.format("IA count=%d", count))

    local ctxs = FindAllOf("InputMappingContext")
    local ctx_count, map_count = 0, 0
    if ctxs then
        for _, c in pairs(ctxs) do
            if valid(c) then
                local cn = full_name(c) or "?"
                if not cn:find("Default__") then
                    ctx_count = ctx_count + 1
                    local maps = prop(c, "Mappings")
                    local n = 0
                    pcall(function() n = maps:GetArrayNum() end)
                    out(string.format("IMC %s mappings=%d", cn, n))
                    for i = 1, n do
                        local m
                        if pcall(function() m = maps[i] end) and m then
                            local action, key = "?", "?"
                            pcall(function()
                                local a = m.Action
                                if a and valid(a) then action = fname_str(a) end
                            end)
                            pcall(function() key = m.Key.KeyName:ToString() end)
                            map_count = map_count + 1
                            out(string.format("MAP %s <- %s  (%s)", action, key, fname_str(c)))
                        end
                    end
                end
            end
        end
    end
    out(string.format("IMC count=%d mappings=%d", ctx_count, map_count))

    -- Legacy input, for the record: absent on an Enhanced Input game is the expected answer.
    local settings
    pcall(function() settings = StaticFindObject("/Script/Engine.Default__InputSettings") end)
    if settings and valid(settings) then
        for _, field in ipairs({ "ActionMappings", "AxisMappings" }) do
            local arr = prop(settings, field)
            local n = -1
            pcall(function() n = arr:GetArrayNum() end)
            out(string.format("LEGACY InputSettings.%s count=%d", field, n))
            for i = 1, math.max(n, 0) do
                local m
                if pcall(function() m = arr[i] end) and m then
                    local an, kn = "?", "?"
                    pcall(function() an = m.ActionName:ToString() end)
                    pcall(function() an = m.AxisName:ToString() end)
                    pcall(function() kn = m.Key.KeyName:ToString() end)
                    out(string.format("LEGACYMAP %s <- %s", an, kn))
                end
            end
        end
    else
        out("LEGACY InputSettings default object: not found")
    end
end

---------------------------------------------------------------------------- live phase state

local pawn_bools = {}      -- BoolProperty names on the pawn chain, from the census
local mapped_keys = {}     -- FKey names the mapping census found, for stage 2's A path
local action_assets = {}   -- {name=, obj=} for stage 2's E path
local last = {}
local samples = 0
local cost_accum = 0
local census_done = false
local missing = {}
local coverage_reported = false

local function on_change(key, value, t)
    local v = tostring(value)
    if last[key] ~= v then
        local was = last[key]
        last[key] = v
        if was ~= nil then
            out(string.format("CHANGE %s: %s -> %s  t=%.2f s=%d", key, tostring(was), v, t, samples))
        elseif census_done then
            out(string.format("FIRST %s = %s  t=%.2f s=%d", key, v, t, samples))
        end
    end
end

---------------------------------------------------------------------------- stage 2: the calls

-- Each path disarms itself on its first Lua error; a native fault is not catchable and is the
-- reason this is a separate stage.
local path = {
    E = { armed = STAGE >= 2, lib = nil, err = nil, calls = 0 },
    A = { armed = STAGE >= 2, err = nil, calls = 0 },
}

local function disarm(p, name, err)
    p.armed = false
    p.err = tostring(err)
    out(string.format("PATH %s DISARMED after %d call(s): %s", name, p.calls, p.err))
end

-- Reads one FInputActionValue however UE4SS hands it back: a struct wrapper with Value/ValueType,
-- or a table. Returns a text form and a diagnosis of what it was.
local function action_value_text(v)
    local t = type(v)
    if t == "table" then
        local val = v.Value
        return (val and vec_text(val) or "?") .. "/" .. tostring(v.ValueType), "table"
    end
    if t == "userdata" then
        local val, vt
        pcall(function() val = v.Value end)
        pcall(function() vt = v.ValueType end)
        if val ~= nil then return vec_text(val) .. "/" .. tostring(plain(vt)), "struct" end
        local ok, tn = pcall(function() return v:type() end)
        return "<userdata " .. tostring(ok and tn or "?") .. ">", "opaque"
    end
    return tostring(v), t
end

local function sample_E(pawn, t)
    local p = path.E
    if not p.armed then return end
    if not p.lib then
        local ok, lib = pcall(StaticFindObject, "/Script/EnhancedInput.Default__EnhancedInputLibrary")
        if not ok or not lib or not valid(lib) then
            disarm(p, "E", "EnhancedInputLibrary default object not found: " .. tostring(lib))
            return
        end
        p.lib = lib
        out("PATH E: EnhancedInputLibrary default object resolved")
    end
    for _, a in ipairs(action_assets) do
        local ok, err = pcall(function()
            local v = p.lib:GetBoundActionValue(pawn, a.obj)
            p.calls = p.calls + 1
            local text, kind = action_value_text(v)
            if p.calls <= #action_assets then out(string.format("PATH E first read %s -> %s (%s)", a.name, text, kind)) end
            on_change("E." .. a.name, text, t)
        end)
        if not ok then disarm(p, "E", err); return end
    end
end

local function sample_A(pc, t)
    local p = path.A
    if not p.armed then return end
    for i, keyname in ipairs(mapped_keys) do
        local ok, err = pcall(function()
            local key = { KeyName = FName(keyname) }
            local down = pc:IsInputKeyDown(key)
            p.calls = p.calls + 1
            if p.calls <= #mapped_keys then out(string.format("PATH A first read IsInputKeyDown(%s) -> %s", keyname, tostring(plain(down)))) end
            on_change("A.down." .. keyname, plain(down), t)
            if keyname:find("Axis") or keyname:find("Gamepad_Left") or keyname:find("Gamepad_Right") or keyname:find("Mouse") then
                local analog = pc:GetInputAnalogKeyState(key)
                local n = tonumber(plain(analog))
                if n then n = math.floor(n / AXIS_QUANT + 0.5) * AXIS_QUANT end
                on_change("A.analog." .. keyname, n and string.format("%.3f", n) or tostring(plain(analog)), t)
            end
        end)
        if not ok then disarm(p, "A", err); return end
    end
end

---------------------------------------------------------------------------- the loop

-- Population count of the classes a ghost brings (probe_leakcount's WATCH list), so a reload of
-- this probe after a pack despawns answers "did anything stay behind?" on the same file. The
-- local player owns one pawn and one BP_PlayerCam_C; every live ghost adds one of each plus an
-- AIController; anything above that after a despawn is a leftover.
local COUNT_CLASSES = { "BP_PlayerGoatMain_C", "BP_PlayerCam_C", "SpringArmComponent", "CameraComponent",
    "AIController", "NiagaraComponent", "TextRenderComponent" }
local function count_classes(when)
    local parts = {}
    for _, cn in ipairs(COUNT_CLASSES) do
        local n, live = -1, 0
        local ok, all = pcall(FindAllOf, cn)
        if ok and all then
            n = 0
            for _, o in pairs(all) do
                n = n + 1
                if valid(o) and not (full_name(o) or ""):find("Default__") then live = live + 1 end
            end
        end
        parts[#parts + 1] = string.format("%s=%d(live %d)", cn, n, live)
    end
    out("COUNT " .. when .. ": " .. table.concat(parts, " "))
end

local function do_census(pc, pawn)
    out(string.format("CENSUS stage=%d engine=UE5.1 file=%s", STAGE, OUT_PATH))
    count_classes("at census")
    census_object(pc, "PlayerController", nil)
    local pi = prop(pc, "PlayerInput")
    if pi and valid(pi) then
        census_object(pi, "PlayerInput", nil)
    else
        out("CHAIN PlayerInput: controller's PlayerInput did not resolve")
    end
    census_object(pawn, "Pawn", pawn_bools)
    census_enhanced_input()
    -- Stage 2 targets, from what the census just saw.
    local seen = {}
    local actions = FindAllOf("InputAction")
    if actions then
        for _, a in pairs(actions) do
            if valid(a) then
                local n = full_name(a) or ""
                if not n:find("Default__") then action_assets[#action_assets + 1] = { name = fname_str(a), obj = a } end
            end
        end
    end
    local ctxs = FindAllOf("InputMappingContext")
    if ctxs then
        for _, c in pairs(ctxs) do
            if valid(c) and not (full_name(c) or ""):find("Default__") then
                local maps = prop(c, "Mappings")
                local n = 0
                pcall(function() n = maps:GetArrayNum() end)
                for i = 1, n do
                    local kn
                    pcall(function() kn = maps[i].Key.KeyName:ToString() end)
                    if kn and not seen[kn] and #mapped_keys < MAX_MAPPED_KEYS then
                        seen[kn] = true
                        mapped_keys[#mapped_keys + 1] = kn
                    end
                end
            end
        end
    end
    out(string.format("CENSUS done: %d pawn bools to watch, %d actions, %d mapped keys (stage 2 targets)",
        #pawn_bools, #action_assets, #mapped_keys))
    census_done = true
    flush()
    out("READY -- stand still ~3 s, then one input at a time, hold ~3 s, release, wait ~2 s: jump, attack, crouch, left, right, up, down, camera left, camera right, cling, throw, pause menu.")
end

local function sample()
    local t0 = os.clock()
    samples = samples + 1
    local pc, pawn = player_controller_and_pawn()
    if not pc or not pawn then
        if samples % 100 == 1 then out(string.format("no player pawn yet (title screen / loading) s=%d", samples)) end
        return
    end
    local pawn_class = fname_str(pawn:GetClass())
    if pawn_class ~= PAWN_CLASS then
        if samples % 100 == 1 then out(string.format("controller's pawn is %s, not %s -- waiting s=%d", pawn_class, PAWN_CLASS, samples)) end
        return
    end
    if not census_done then
        local ok, err = pcall(do_census, pc, pawn)
        if not ok then out("CENSUS FAILED: " .. tostring(err)); census_done = true end
        return
    end

    local t = os.clock()
    -- Option C: every bool on the pawn chain, by name.
    for _, b in ipairs(pawn_bools) do
        local v = prop(pawn, b)
        if v == nil then missing[b] = true else on_change("C." .. b, plain(v), t) end
    end
    for _, s in ipairs(NAMED_SCALARS) do
        local v = prop(pawn, s)
        if v == nil then missing[s] = true else on_change("C." .. s, plain(v), t) end
    end
    for _, vn in ipairs(NAMED_VECTORS) do
        local v = prop(pawn, vn)
        if v == nil then missing[vn] = true else on_change("C." .. vn, vec_text(v), t) end
    end
    -- Stage 2 paths.
    sample_E(pawn, t)
    sample_A(pc, t)

    if not coverage_reported and samples > 5 then
        coverage_reported = true
        local m = {}
        for k in pairs(missing) do m[#m + 1] = k end
        table.sort(m)
        out(string.format("COVERAGE: %d named field(s) did not resolve on the pawn%s", #m, (#m > 0) and (": " .. table.concat(m, ", ")) or ""))
        out(string.format("COVERAGE: path E %s, path A %s", path.E.armed and "armed" or ("off" .. (path.E.err and (": " .. path.E.err) or "")),
            path.A.armed and "armed" or ("off" .. (path.A.err and (": " .. path.A.err) or ""))))
    end

    cost_accum = cost_accum + (os.clock() - t0)
    if samples % 100 == 0 then
        out(string.format("COST %.2f ms/sample over the last 100 (game thread), E calls=%d A calls=%d s=%d", cost_accum * 10, path.E.calls, path.A.calls, samples))
        cost_accum = 0
    end
end

LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(sample)
        if not ok then out("sample error: " .. tostring(err)) end
    end)
    return false
end)

LoopAsync(FLUSH_MS, function()
    flush()
    return false
end)

out(string.format("loaded stage %d -- load in gameplay; the census runs once a player pawn exists, then READY. Output: %s", STAGE, OUT_PATH))
