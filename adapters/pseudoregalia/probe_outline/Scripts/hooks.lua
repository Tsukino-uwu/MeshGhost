-- MeshGhost OUTLINE probe, stage 2 -- who CALLS the custom-depth setters, and does a re-sync fix it.
-- **THIS ONE CAN WRITE, on an explicit trigger only** -- see the RESYNC block; without the trigger
-- file it is read-only. Stage 1 (main.lua) is the flags-only instrument; run that first.
--
-- WHAT STAGE 1 FOUND (2026-09-05, one run, user attacking once among ghosts): the player's
-- VisualMesh and WeaponMesh read bRenderCustomDepth=true, CustomDepthStencilValue=0 before AND after
-- the melee attack, unchanged -- while the screen showed the sword's silhouette through the player's
-- own body from the attack onward. Healthy flags, wrong picture: `documentation.md`'s "the flag is
-- render-thread state" is the first suspect, and the property reads cannot see it. Also: the
-- cross-owner walk found nothing real (its filter was wrong: a missing property reads back as a
-- placeholder object, not nil -- fixed here by requiring a boolean), and 113 BP_AfterImage_C were
-- alive after 90 s, most with copyActor=nil and custom depth off.
--
-- WHAT THIS RUN DOES, from the moment the player pawn exists, for 180 s:
--   1. HOOKS (read-only): every call of PrimitiveComponent:SetRenderCustomDepth and
--      SetCustomDepthStencilValue, PRE and POST, with the component, its OWNER KIND (PLAYER pawn /
--      GHOST pawn / AFTERIMAGE / other) and the value. Pre and post both printed, because the
--      shipping mod's own pre-hook rewrites the parameter for afterimages: a pre=true/post=false
--      pair is that rewrite, seen from outside. Afterimage calls are counted and summarised once a
--      second (a dash spawns many); player and ghost calls print in full, every one.
--   2. CENSUS (read-only): EVERY skeletal, static and poseable mesh component whose outer is the
--      player pawn -- not just the three named ones -- with custom depth, stencil, main-pass and
--      visibility, on change. If the game swaps the body to another component during an attack,
--      this is where it shows.
--   2b. TEMPLATES (read-only): the class default objects of the pawn and afterimage classes and
--      every `*_GEN_VARIABLE` / `Default__` mesh template of theirs, with the same flags, on change.
--      A template reading custom depth OFF means every future spawn inherits it -- the player's
--      own pawn after a same-level reload included, which is exactly when stage 1's healthy
--      pawn was replaced by one whose body reads OFF (16:01:06, LoadMap PRE, this session).
--   3. RESTORE (WRITES, one shot, only when asked): create `outline_resync.txt` in this mod's folder
--      (beside Scripts\). On the next sample the probe calls SetRenderCustomDepth(true) on the
--      player's VisualMesh and WeaponMesh -- the vanilla state of a fresh pawn -- logs the readback
--      and deletes the trigger. If the sword's silhouette through the body vanishes on screen, the
--      body's custom depth being OFF is the mechanism and re-enabling it is the shape of a fix; who
--      turned it off is what the HOOK lines around the attack or slide say.
--   Countdown at 120/60/30/10 s; hooks are unregistered at the end. Nothing is left running.
--
-- What it CANNOT see: a change made without either setter (a raw property write plus a render-state
-- rebuild, or a mesh swap through a path that never calls these). The census is there for the swap;
-- the raw-write case would show as flags changing with no hook line beside them.
--
-- Grounded APIs, none from memory: UE4SS Lua RegisterHook/UnregisterHook (pre AND post callbacks for
-- a /Script/ function; RemoteUnrealParam:get()), FindAllOf, IsValid, GetFullName, GetOuter, GetClass,
-- LoopAsync (vendored RE-UE4SS/docs/lua-api). Engine: UPrimitiveComponent::SetRenderCustomDepth(bool),
-- SetCustomDepthStencilValue(int32), bRenderCustomDepth, CustomDepthStencilValue, bRenderInMainPass;
-- USceneComponent::bVisible (docs.unrealengine.com). The C++ mod hooks the first of these already
-- (Plugin.cpp, register_afterimage_outline_guard) -- proof it is reachable on this build.
--
-- Deploy over the scratch slot and trigger the reloader (see main.lua). Restore the stub after.
-- Dev-only tooling; never ships. Unload before judging anything else -- it can write.

local TAG = "[MeshGhostOutlineProbe2]"
local PAWN_CLASS = "BP_PlayerGoatMain_C"
local IMAGE_CLASS = "BP_AfterImage_C"
local INTERVAL_MS = 500
local DURATION_S = 180
local MESH_CLASSES = { "SkeletalMeshComponent", "StaticMeshComponent", "PoseableMeshComponent" }
local FIELDS = { "bRenderCustomDepth", "CustomDepthStencilValue", "bRenderInMainPass", "bVisible" }

local function script_dir()
    local src = debug.getinfo(1, "S").source or ""
    src = src:gsub("^@", "")
    return src:match("^(.*[\\/])") or "./"
end
local RESYNC_PATH = script_dir() .. "../outline_resync.txt"

local samples, clock_samples = 0, 0
local last_line = {}
local ended = false
local hook_ids = {}
local image_calls = { pre = 0, post = 0, pre_true = 0, post_true = 0 }
local other_calls = 0

local function full_name(obj) local n; pcall(function() n = obj:GetFullName() end); return n or "?" end
local function short(name) return (tostring(name):gsub("^.*[/%.]([^/%.]+%.[^/%.]+)$", "%1")) end
local function valid(obj) local ok, v = pcall(function() return obj:IsValid() end); return ok and v == true end
local function prop(obj, name) local v; if not pcall(function() v = obj[name] end) then return nil end; return v end
local function is_default(obj) return full_name(obj):find("Default__", 1, true) ~= nil end

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

local player_name_cache = nil

-- Walks the outer chain of a component and names what owns it.
local function owner_kind(comp)
    local o = nil
    pcall(function() o = comp:GetOuter() end)
    local hops = 0
    while o ~= nil and valid(o) and hops < 6 do
        hops = hops + 1
        local cls = "?"
        pcall(function() cls = o:GetClass():GetFName():ToString() end)
        if cls == IMAGE_CLASS then return "AFTERIMAGE", full_name(o) end
        if cls == PAWN_CLASS then
            local n = full_name(o)
            if player_name_cache and n == player_name_cache then return "PLAYER", n end
            return "GHOST", n
        end
        local nxt = nil
        pcall(function() nxt = o:GetOuter() end)
        o = nxt
    end
    return "other", "?"
end

local function emit(key, line)
    if last_line[key] ~= line then
        last_line[key] = line
        print(string.format("%s #%d %s\n", TAG, samples, line))
    end
end

local function flags_line(comp)
    local parts = {}
    for _, f in ipairs(FIELDS) do
        local v = prop(comp, f)
        parts[#parts + 1] = f:gsub("^b", "") .. "=" .. ((type(v) == "boolean" or type(v) == "number") and tostring(v) or "?")
    end
    return table.concat(parts, " ")
end

-- 1. HOOKS ---------------------------------------------------------------------------------------
local function hook_report(fn_label, phase, ctx_param, value_param)
    local comp = nil
    pcall(function() comp = ctx_param:get() end)
    local value = nil
    pcall(function() value = value_param:get() end)
    if comp == nil or not valid(comp) then return end
    local kind, owner = owner_kind(comp)
    if kind == "AFTERIMAGE" then
        image_calls[phase] = image_calls[phase] + 1
        if value == true or (type(value) == "number" and value ~= 0) then image_calls[phase .. "_true"] = image_calls[phase .. "_true"] + 1 end
        return
    end
    if kind == "other" then other_calls = other_calls + 1; return end
    print(string.format("%s #%d HOOK %s %s on %s %s.%s = %s\n", TAG, samples, fn_label, phase:upper(), kind,
                        short(owner), short(full_name(comp)):gsub("^[^%.]*%.", ""), tostring(value)))
end

local function install_hooks()
    local specs = {
        { "/Script/Engine.PrimitiveComponent:SetRenderCustomDepth", "SetRenderCustomDepth" },
        { "/Script/Engine.PrimitiveComponent:SetCustomDepthStencilValue", "SetCustomDepthStencilValue" },
    }
    for _, spec in ipairs(specs) do
        local path, label = spec[1], spec[2]
        local ok, err = pcall(function()
            local pre, post = RegisterHook(path,
                function(ctx, v) hook_report(label, "pre", ctx, v) end,
                function(ctx, v) hook_report(label, "post", ctx, v) end)
            hook_ids[#hook_ids + 1] = { path, pre, post }
        end)
        print(string.format("%s hook %s: %s\n", TAG, label, ok and "armed (pre+post)" or ("FAILED: " .. tostring(err))))
    end
end

local function remove_hooks()
    for _, h in ipairs(hook_ids) do
        pcall(function() UnregisterHook(h[1], h[2], h[3]) end)
    end
    hook_ids = {}
end

-- 2. CENSUS of every mesh component owned by the player ------------------------------------------
local function player_meshes(player)
    local out = {}
    local pn = full_name(player)
    for _, cls in ipairs(MESH_CLASSES) do
        for _, c in pairs(FindAllOf(cls) or {}) do
            if valid(c) and not is_default(c) then
                local o = nil
                pcall(function() o = c:GetOuter() end)
                if o ~= nil and valid(o) and full_name(o) == pn then out[#out + 1] = c end
            end
        end
    end
    return out
end

local function sample_census(player)
    local meshes = player_meshes(player)
    for _, c in ipairs(meshes) do
        emit("census/" .. full_name(c), string.format("PLAYER MESH %s (%s): %s",
             short(full_name(c)):gsub("^[^%.]*%.", ""), (function() local k = "?"; pcall(function() k = c:GetClass():GetFName():ToString() end); return k end)(),
             flags_line(c)))
    end
    emit("census/count", string.format("player owns %d mesh component(s) across %s", #meshes, table.concat(MESH_CLASSES, "/")))
end

-- 2b. TEMPLATES: class default objects and component templates -------------------------------------
-- FindAllOf returns class-default objects too (PROBES.md). A pawn spawned by the game is built
-- from BP_PlayerGoatMain_C's default object and its component templates (`*_GEN_VARIABLE`); an
-- afterimage from BP_AfterImage_C's. If one of those reads custom depth OFF, the question "who
-- strips the PLAYER" has its answer: nobody, per instance -- the template was stripped once, and
-- every later spawn (the player's own after a same-level reload included) inherits it.
local function sample_templates()
    local n = 0
    for _, cls in ipairs({ PAWN_CLASS, IMAGE_CLASS }) do
        for _, o in pairs(FindAllOf(cls) or {}) do
            if valid(o) and is_default(o) then
                n = n + 1
                for _, m in ipairs({ "VisualMesh", "WeaponMesh", "LightMesh", "PoseableMesh" }) do
                    local c = prop(o, m)
                    if c ~= nil and type(c) ~= "boolean" and type(c) ~= "number" and valid(c) then
                        emit("tmpl/" .. full_name(o) .. "/" .. m,
                             string.format("TEMPLATE %s.%s: %s (%s)", short(full_name(o)), m, flags_line(c), full_name(c)))
                    end
                end
            end
        end
    end
    for _, cls in ipairs(MESH_CLASSES) do
        for _, c in pairs(FindAllOf(cls) or {}) do
            if valid(c) then
                local fn = full_name(c)
                if (fn:find("GEN_VARIABLE", 1, true) or fn:find("Default__", 1, true))
                   and (fn:find("PlayerGoat", 1, true) or fn:find("AfterImage", 1, true)) then
                    n = n + 1
                    emit("tmpl/" .. fn, string.format("TEMPLATE component %s: %s", fn, flags_line(c)))
                end
            end
        end
    end
    emit("tmpl/count", string.format("templates seen: %d", n))
end

-- 2c. AFTERIMAGE PROPERTIES, once: every object-typed property on a live afterimage's class chain,
-- with the value and the kind of actor that OWNS the value. The mod's sweep strips any such value
-- that has a custom-depth flag; a value owned by the PLAYER is the player's own mesh being stripped
-- through an afterimage's reference to it.
local image_props_dumped = false
local function dump_image_props()
    if image_props_dumped then return end
    for _, img in pairs(FindAllOf(IMAGE_CLASS) or {}) do
        if valid(img) and not is_default(img) then
            image_props_dumped = true
            local walked = 0
            local c = nil
            pcall(function() c = img:GetClass() end)
            local depth = 0
            while c and valid(c) and depth < 12 do
                depth = depth + 1
                pcall(function()
                    c:ForEachProperty(function(pr)
                        walked = walked + 1
                        pcall(function()
                            if pr:GetClass():GetFName():ToString() ~= "ObjectProperty" then return end
                            local pname = pr:GetFName():ToString()
                            local v = img[pname]
                            if v == nil or type(v) == "boolean" or type(v) == "number" or not valid(v) then return end
                            local cd = prop(v, "bRenderCustomDepth")
                            local kind, owner = owner_kind(v)
                            print(string.format("%s #%d IMAGEPROP %s.%s -> %s customdepth=%s owner=%s %s\n", TAG, samples,
                                                short(full_name(img)), pname, short(full_name(v)),
                                                type(cd) == "boolean" and tostring(cd) or "n/a", kind, short(owner)))
                        end)
                    end)
                end)
                local sup = nil
                pcall(function() sup = c:GetSuperStruct() end)
                if sup and sup ~= c and valid(sup) then c = sup else c = nil end
            end
            print(string.format("%s #%d IMAGEPROP coverage: %d properties walked over %d class level(s) on %s\n", TAG, samples, walked, depth, short(full_name(img))))
            return
        end
    end
end

-- 3. RESYNC, one shot on a trigger file -----------------------------------------------------------
local function trigger_present()
    local f = io.open(RESYNC_PATH, "r")
    if f then f:close(); return true end
    return false
end

local function resync_step(player)
    if not trigger_present() then return end
    -- Vanilla state for a live pawn: VisualMesh and WeaponMesh both write custom depth (stage 1 read
    -- both ON on a fresh pawn). Put both back through the engine's own setter and read back.
    print(string.format("%s RESTORE requested: SetRenderCustomDepth(true) on the player's VisualMesh and WeaponMesh. Watch the screen now.\n", TAG))
    for _, m in ipairs({ "VisualMesh", "WeaponMesh" }) do
        local c = prop(player, m)
        if c ~= nil and type(c) ~= "boolean" and type(c) ~= "number" and valid(c) then
            local before = prop(c, "bRenderCustomDepth")
            local ok, err = pcall(function() c:SetRenderCustomDepth(true) end)
            print(string.format("%s   %s: was %s -> %s, reads back %s\n", TAG, m, tostring(before),
                                ok and "called" or ("FAILED " .. tostring(err)), tostring(prop(c, "bRenderCustomDepth"))))
        else
            print(string.format("%s   %s: not found on the player pawn\n", TAG, m))
        end
    end
    pcall(function() os.remove(RESYNC_PATH) end)
    print(string.format("%s RESTORE done; trigger %s.\n", TAG, trigger_present() and "STILL PRESENT -- delete it by hand" or "removed"))
end

-- MAIN LOOP ---------------------------------------------------------------------------------------
local function sample()
    samples = samples + 1
    local player = player_pawn()
    if player then
        clock_samples = clock_samples + 1
        player_name_cache = full_name(player)
        if clock_samples == 1 then
            print(string.format("%s START: player=%s. Census in full once, then changes; every setter call on player/ghost meshes in full.\n", TAG, short(player_name_cache)))
        end
        sample_census(player)
        if clock_samples % 4 == 1 then sample_templates() end
        dump_image_props()
        resync_step(player)
    end
    if samples % 2 == 0 and (image_calls.pre + image_calls.post) > 0 then
        emit("img/summary", string.format("afterimage setter calls so far: pre=%d (true %d) post=%d (true %d); other-owner calls=%d",
             image_calls.pre, image_calls.pre_true, image_calls.post, image_calls.post_true, other_calls))
    end
    local left = DURATION_S - (clock_samples * INTERVAL_MS) / 1000
    if left == 120 or left == 60 or left == 30 or left == 10 then print(string.format("%s %ds left.\n", TAG, left)) end
    if left <= 0 and not ended then
        ended = true
        remove_hooks()
        print(string.format("%s END after %d samples; hooks removed. Afterimage setter calls pre=%d post=%d. Stopped; nothing left running.\n",
                            TAG, samples, image_calls.pre, image_calls.post))
    end
end

install_hooks()
LoopAsync(INTERVAL_MS, function()
    if ended then return true end
    local ok, err = pcall(sample)
    if not ok then print(string.format("%s sample error: %s\n", TAG, tostring(err))) end
    return false
end)
print(string.format("%s loaded: %d s at %d ms; writes ONLY when %s exists.\n", TAG, DURATION_S, INTERVAL_MS, RESYNC_PATH))
