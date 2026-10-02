-- Audio census, read-only: is a ghost playing sounds, or spending the player's voices? Logs AudioComponents by owner,
-- each cue's concurrency settings once, and the listener's inputs. Blind to PlaySoundAtLocation and PlaySound2D, which
-- create no component; property names from Unreal's AudioComponent.h, SoundBase.h and SoundConcurrency.h.
-- Deploy as ue4ss\Mods\MeshGhostAudioCensus with an enabled.txt; reload via probe_reloader.

local TAG = "[MeshGhostAudioCensus]"

local INTERVAL_MS = 200 -- 2 classes at 5Hz: each FindAllOf walks object space

local PAWN_CLASS = "BP_PlayerGoatMain_C"

local COMP_PROPS = {"Sound", "bIsActive", "bAutoActivate", "VolumeMultiplier", "PitchMultiplier",
                    "bAllowSpatialization", "bIsUISound", "AttachParent"}
local SOUND_PROPS = {"bOverrideConcurrency", "ConcurrencyOverrides", "ConcurrencySet", "Priority",
                     "MaxDistance", "bLooping"}
local CONCURRENCY_PROPS = {"MaxCount", "bLimitToOwner", "ResolutionRule", "RetriggerTime",
                           "VolumeScale"}

local seen_comp = {}    -- component full name -> true
local last_active = {}  -- component full name -> last bIsActive read
local seen_sound = {}   -- sound asset full name -> true, so concurrency dumps once per asset
local last_ghosts = -1  -- ghost pawn count, so the ghost's arrival marks itself in the log
local samples = 0

local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n
end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

-- Returns value, resolved: resolved is false only when the read itself failed, so a missing property is never a zero.
local function prop(obj, name)
    local v
    local ok = pcall(function() v = obj[name] end)
    if not ok then return nil, false end
    return v, true
end

local function vec_text(v)
    if v == nil then return "?" end
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    -- Type-checked, not nil-checked: an instrument may return "?", never raise.
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return "?" end
    return string.format("%.0f,%.0f,%.0f", x, y, z)
end

local function short(name)
    return (name and name:match("([^%.]+)$")) or name or "?"
end

-- Attributed by name containment: a component's full name carries its owning chain, which an outer walk misses.
local function owner_of(comp_name, pawns)
    for _, p in ipairs(pawns) do
        if comp_name:find(p.short, 1, true) then return p.tag, p.pos end
    end
    return "world", "?"
end

-- A ghost reads as possessed too, so the controller names the pawn it drives and every other pawn of the class is a
-- ghost (or a corpse not yet collected).
local function player_pawn_name()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({"AcknowledgedPawn", "Pawn"}) do
                local p = prop(pc, field)
                if p ~= nil and valid(p) then
                    local n = full_name(p)
                    if n then return short(n), field end
                end
            end
        end
    end
    return nil
end

local function pawn_table()
    local pawns = {}
    local driven, via = player_pawn_name()
    local found = FindAllOf(PAWN_CLASS)
    if not found then return pawns, driven, via end
    for _, pawn in pairs(found) do
        if valid(pawn) then
            local n = full_name(pawn)
            if n then
                local s = short(n)
                local ctrl = prop(pawn, "Controller")
                -- The owner's position travels with every event: where the listener sits is a spatial question.
                local root = prop(pawn, "RootComponent")
                local loc = root ~= nil and prop(root, "RelativeLocation") or nil
                pawns[#pawns + 1] = {short = s, tag = (driven and s == driven) and "PLAYER" or "ghost",
                                     full = n, possessed = ctrl ~= nil, pos = vec_text(loc)}
            end
        end
    end
    return pawns, driven, via
end

-- The audio listener follows the camera manager's view target unless a controller overrides it; logged on change.
local last_view_target = nil

-- The camera manager's cached point of view is what feeds the listener.
local function pov_location(cam)
    local cache = prop(cam, "CameraCache")
    local pov = cache ~= nil and prop(cache, "POV") or nil
    local loc = pov ~= nil and prop(pov, "Location") or nil
    return loc
end

-- An audio listener belongs to a local player, so a second controller arriving with a ghost would move it without
-- moving the camera: each controller and the pawn it drives, logged on change.
local last_controller_census = nil
local function controller_census()
    local pcs = FindAllOf("PlayerController")
    local parts = {}
    if pcs then
        for _, pc in pairs(pcs) do
            if valid(pc) then
                local n = full_name(pc)
                if n then
                    local pawn = prop(pc, "AcknowledgedPawn") or prop(pc, "Pawn")
                    local pn = (pawn ~= nil and valid(pawn)) and short(full_name(pawn) or "?") or "<none>"
                    local player = prop(pc, "Player")
                    parts[#parts + 1] = short(n) .. "->" .. pn .. (player ~= nil and "(local)" or "(no Player)")
                end
            end
        end
    end
    table.sort(parts)
    local text = table.concat(parts, " ")
    if text ~= last_controller_census then
        print(string.format("%s CONTROLLERS %s t=%.1f\n", TAG, text == "" and "<none>" or text, os.clock()))
        last_controller_census = text
    end
end

-- The controller's listener-override fields return a fresh wrapper every read on this build, so the question is
-- asked from the other side: a sound class driven to 0 would also play sounds inaudibly. Logged on change.
local last_class_volumes = nil
local function sound_class_check()
    local classes = FindAllOf("SoundClass")
    if not classes then return end
    local parts = {}
    for _, sc in pairs(classes) do
        if valid(sc) then
            local n = full_name(sc)
            if n then
                local props = prop(sc, "Properties")
                local vol = props ~= nil and prop(props, "Volume") or nil
                local pitch = props ~= nil and prop(props, "Pitch") or nil
                if type(vol) == "number" then
                    parts[#parts + 1] = string.format("%s=%.2f/%.2f", short(n), vol,
                                                      type(pitch) == "number" and pitch or -1)
                end
            end
        end
    end
    table.sort(parts)
    local text = table.concat(parts, " ")
    if text ~= last_class_volumes then
        print(string.format("%s SOUNDCLASS %s t=%.1f\n", TAG, text == "" and "<none readable>" or text, os.clock()))
        last_class_volumes = text
    end
end

-- A SoundMix with a Duration expires by itself, the one way sound could die with no call, so each mix is dumped once.
local dumped_mixes = false
local function sound_mix_dump()
    if dumped_mixes then return end
    local mixes = FindAllOf("SoundMix")
    if not mixes then return end
    dumped_mixes = true
    for _, mix in pairs(mixes) do
        if valid(mix) then
            local n = full_name(mix)
            if n then
                local bits = {}
                for _, f in ipairs({"Duration", "FadeInTime", "FadeOutTime", "bApplyEQ"}) do
                    local v, resolved = prop(mix, f)
                    bits[#bits + 1] = f .. "=" .. (resolved and tostring(v) or "UNRESOLVED")
                end
                print(string.format("%s SOUNDMIX '%s' %s\n", TAG, n, table.concat(bits, " ")))
            end
        end
    end
end

local function view_target_check()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            local cam = prop(pc, "PlayerCameraManager")
            if cam ~= nil and valid(cam) then
                local vt = prop(cam, "ViewTarget")
                local target = vt ~= nil and prop(vt, "Target") or nil
                local name = (target ~= nil and valid(target)) and full_name(target) or "<none>"
                if name ~= last_view_target then
                    local ovr = prop(pc, "bOverrideAudioListener")
                    print(string.format("%s VIEWTARGET %s -> %s (bOverrideAudioListener=%s) t=%.1f\n",
                                        TAG, tostring(last_view_target), name, tostring(ovr), os.clock()))
                    last_view_target = name
                end
                -- Every ~2s: where the game listens from against where the player is.
                if samples % 10 == 0 then
                    local pawn = prop(pc, "AcknowledgedPawn") or prop(pc, "Pawn")
                    local proot = (pawn ~= nil and valid(pawn)) and prop(pawn, "RootComponent") or nil
                    local ploc = proot ~= nil and prop(proot, "RelativeLocation") or nil
                    local vroot = (target ~= nil and valid(target)) and prop(target, "RootComponent") or nil
                    local vloc = vroot ~= nil and prop(vroot, "RelativeLocation") or nil
                    print(string.format("%s POS player=%s viewtarget=%s pov=%s t=%.1f\n",
                                        TAG, vec_text(ploc), vec_text(vloc),
                                        vec_text(pov_location(cam)), os.clock()))
                end
                return
            end
        end
    end
end

-- One dump per distinct sound asset: a cue that caps its instances and stops the oldest is the concurrency shape.
local function dump_sound(sound)
    local name = full_name(sound)
    if not name or seen_sound[name] then return end
    seen_sound[name] = true
    local fields = {}
    for _, p in ipairs(SOUND_PROPS) do
        local v, resolved = prop(sound, p)
        if not resolved then
            fields[#fields + 1] = p .. "=UNRESOLVED"
        elseif p == "ConcurrencyOverrides" then
            local inner = {}
            for _, c in ipairs(CONCURRENCY_PROPS) do
                local cv, cresolved = prop(v, c)
                inner[#inner + 1] = c .. "=" .. (cresolved and tostring(cv) or "UNRESOLVED")
            end
            fields[#fields + 1] = "ConcurrencyOverrides{" .. table.concat(inner, " ") .. "}"
        elseif p == "ConcurrencySet" then
            -- Its members are pointers this probe does not own, so only its presence is reported.
            fields[#fields + 1] = "ConcurrencySet=present"
        else
            fields[#fields + 1] = p .. "=" .. tostring(v)
        end
    end
    print(string.format("%s SOUND asset='%s' %s\n", TAG, name, table.concat(fields, " ")))
end

local function describe(comp, kind, owner, owner_pos)
    local name = full_name(comp) or "<unnamed>"
    local fields = {}
    local sound
    for _, p in ipairs(COMP_PROPS) do
        local v, resolved = prop(comp, p)
        if not resolved then
            fields[#fields + 1] = p .. "=UNRESOLVED"
        elseif p == "Sound" then
            sound = v
            fields[#fields + 1] = "sound='" .. (v == nil and "<none>" or (full_name(v) or "<unnamed>")) .. "'"
        elseif p == "AttachParent" then
            fields[#fields + 1] = "attach='" .. (v == nil and "<none>" or (full_name(v) or "<unnamed>")) .. "'"
        else
            fields[#fields + 1] = p .. "=" .. tostring(v)
        end
    end
    print(string.format("%s %s owner=%s at=%s comp='%s' %s t=%.1f\n",
                        TAG, kind, owner, owner_pos or "?", name, table.concat(fields, " "), os.clock()))
    if sound and valid(sound) then dump_sound(sound) end
end

local function sample()
    samples = samples + 1
    local pawns, driven, via = pawn_table()
    view_target_check()
    controller_census()
    sound_class_check()
    sound_mix_dump()

    local ghosts = 0
    for _, p in ipairs(pawns) do if p.tag == "ghost" then ghosts = ghosts + 1 end end
    if ghosts ~= last_ghosts then
        print(string.format("%s GHOSTCOUNT %d -> %d t=%.1f\n", TAG, last_ghosts, ghosts, os.clock()))
        last_ghosts = ghosts
    end

    local total, playing = 0, {}
    local found = FindAllOf("AudioComponent")
    if found then
        for _, comp in pairs(found) do
            if valid(comp) then
                local name = full_name(comp)
                if name then
                    total = total + 1
                    local owner, owner_pos = owner_of(name, pawns)
                    if not seen_comp[name] then
                        seen_comp[name] = true
                        -- The first sample is the level's standing population, not something a ghost did.
                        describe(comp, samples == 1 and "BASELINE" or "APPEAR", owner, owner_pos)
                    end
                    local active = prop(comp, "bIsActive")
                    if active ~= nil then
                        local was = last_active[name]
                        if was ~= nil and was ~= active then
                            describe(comp, active and "START" or "STOP", owner, owner_pos)
                        end
                        last_active[name] = active
                        if active then playing[owner] = (playing[owner] or 0) + 1 end
                    end
                end
            end
        end
    end

    -- Coverage every ~10s, with the evidence the player/ghost split was decided from.
    if samples % 50 == 1 then
        local who = {}
        for _, p in ipairs(pawns) do
            who[#who + 1] = p.short .. "=" .. p.tag .. (p.possessed and "(possessed)" or "")
        end
        local play = {}
        for owner, n in pairs(playing) do play[#play + 1] = owner .. ":" .. n end
        if #play == 0 then play[1] = "none" end
        print(string.format("%s WATCHING AudioComponent=%d playing=%s driven=%s(via %s) pawns=[%s] samples=%d\n",
                            TAG, total, table.concat(play, " "), tostring(driven), tostring(via),
                            table.concat(who, " "), samples))
        if not driven then
            print(string.format("%s COVERAGE WARNING: no controller names a pawn -- every tag below is a guess this sample\n", TAG))
        end
        if #pawns == 0 then
            print(string.format("%s COVERAGE WARNING: no %s found -- attribution is blind this sample\n",
                                TAG, PAWN_CLASS))
        end
    end
end

-- A class's Properties.Volume is the asset's default, never what a runtime SoundMix modifier ducks, so the native
-- GameplayStatics mix calls and the controller's listener overrides are hooked instead (native, so hookable).
local AUDIO_STATICS = {"PushSoundMixModifier", "PopSoundMixModifier", "SetBaseSoundMix",
                       "ClearSoundMixModifiers", "SetSoundMixClassOverride",
                       "ClearSoundMixClassOverride", "StopAllSounds"}
local AUDIO_CONTROLLER_FNS = {"SetAudioListenerOverride", "ClearAudioListenerOverride",
                              "SetAudioListenerAttenuationOverride",
                              "ClearAudioListenerAttenuationOverride"}
local hooked, missing = {}, {}
for _, fn in ipairs(AUDIO_CONTROLLER_FNS) do
    local ok = pcall(function()
        local path = "/Script/Engine.PlayerController:" .. fn
        local f = StaticFindObject(path)
        if f and f:IsValid() then
            RegisterHook(path, function(ctx, a, b, c)
                local bits, first = {}, nil
                for i, p in ipairs({a, b, c}) do
                    local ok2, v = pcall(function() return p:get() end)
                    if i == 1 and ok2 then first = v end
                    bits[#bits + 1] = string.format("arg%d=%s", i,
                                                    (ok2 and v ~= nil) and (full_name(v) or tostring(v)) or "?")
                end
                print(string.format("%s LISTENERCALL %s %s t=%.1f\n", TAG, fn,
                                    table.concat(bits, " "), os.clock()))
            end)
            hooked[#hooked + 1] = fn
        else
            missing[#missing + 1] = fn
        end
    end)
    if not ok then missing[#missing + 1] = fn .. "(hook failed)" end
end
for _, fn in ipairs(AUDIO_STATICS) do
    local ok = pcall(function()
        local f = StaticFindObject("/Script/Engine.GameplayStatics:" .. fn)
        if f and f:IsValid() then
            -- The arguments are the point: which mix, which class, which volume.
            RegisterHook("/Script/Engine.GameplayStatics:" .. fn, function(ctx, a, b, c, d)
                local bits = {}
                for i, p in ipairs({a, b, c, d}) do
                    local ok, v = pcall(function() return p:get() end)
                    if ok and v ~= nil then
                        local n = full_name(v)
                        bits[#bits + 1] = string.format("arg%d=%s", i, n or tostring(v))
                    else
                        bits[#bits + 1] = string.format("arg%d=?", i)
                    end
                end
                print(string.format("%s AUDIOCALL %s %s t=%.1f\n", TAG, fn,
                                    table.concat(bits, " "), os.clock()))
            end)
            hooked[#hooked + 1] = fn
        else
            missing[#missing + 1] = fn
        end
    end)
    if not ok then missing[#missing + 1] = fn .. "(hook failed)" end
end
print(string.format("%s AUDIOCALL hooks: watching [%s]; not on this build or unhookable [%s]\n",
                    TAG, table.concat(hooked, " "), table.concat(missing, " ")))

-- An error out of the sample would stop the loop while the log reads like a quiet game: report once, keep sampling.
local reported_error = false
LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(function()
        local ok, err = pcall(sample)
        if not ok and not reported_error then
            reported_error = true
            print(string.format("%s SAMPLE ERROR (reported once, sampling continues): %s\n", TAG, tostring(err)))
        end
    end)
    return false
end)

print(string.format("%s loaded -- every audio component's appearance, start and stop is logged with its owner and its cue's concurrency settings.\n", TAG))
