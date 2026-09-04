-- MeshGhost audio census probe. ONE question, the user's, reported 2026-09-03:
--
--   *"think ghosts are eating up the players sound, like sfx is not doing anything when the
--   player does things, but ghosts had them."*
--
-- Two shapes fit that report and they want different fixes (UNVERIFIED.md, the OPEN entry):
-- either a ghost is PLAYING sounds the silence clause never covered, or the ghost's sounds are
-- STEALING the player's voices through Unreal's sound concurrency. This probe separates them.
--
-- It logs every UAudioComponent that appears, starts and stops, attributed to the player or to a
-- ghost, with the sound asset each one carries -- and, the first time a given asset is seen, that
-- asset's own CONCURRENCY settings. That last part is the decisive read: if the cue a ghost plays
-- caps itself at a small count and resolves by stopping the oldest instance, the mechanism for
-- shape two is proven present without anybody having to trust an ear. If every cue overrides
-- nothing, shape two needs the game's global concurrency instead and this probe says so.
--
-- **What this instrument CANNOT see, stated up front so its silence is not read as coverage**
-- (`../../agent_docs/checklists/before-a-probe.md`: a filter applied before you look is a guess):
--
--   * A sound started by `PlaySoundAtLocation` / `PlaySound2D` creates NO audio component at all
--     -- it is fire-and-forget inside the audio device. An anim-notify "Play Sound" without
--     Follow is exactly that shape, and footsteps are usually anim notifies. So "no ghost
--     component started" does NOT mean "the ghost was silent"; it means the ghost was silent
--     THROUGH THE COMPONENT PATH. `SpawnSoundAttached` (what the game's own wallRideSFX uses) is
--     the path this does see.
--   * Concurrency resolution happens on the audio device's active-sound list, not on the
--     component. A component can read bIsActive=true while its voice was refused or stolen, so a
--     player component sitting at "active" is NOT evidence the player was audible.
--   * `FindAllOf` returns class-default objects too. Everything below is a NAMED property read
--     inside pcall, never a UFunction call on what FindAllOf handed us (`../CLAUDE.md`).
--
-- Property names are candidates until this build resolves them: every one is reported as it
-- resolved or as UNRESOLVED, so a missing property can never be read as a zero. Names from
-- Unreal Engine's own `Components/AudioComponent.h`, `Sound/SoundBase.h` and
-- `Sound/SoundConcurrency.h` (docs.unrealengine.com); UE4SS Lua surface FindAllOf /
-- ExecuteInGameThread / LoopAsync / IsValid / GetFullName (vendored RE-UE4SS/docs/lua-api).
--
-- Deploy: copy probe_audiocensus/ to <install>\...\Win64\ue4ss\Mods\MeshGhostAudioCensus\ and
-- create an enabled.txt to arm it; remove it once the question is answered. Reload via
-- probe_reloader ("MeshGhostAudioCensus <nonce>").

local TAG = "[MeshGhostAudioCensus]"

local INTERVAL_MS = 200 -- 2 classes x 5Hz, the probe_slashvfx budget; FindAllOf walks object space

local PAWN_CLASS = "BP_PlayerGoatMain_C"

-- Candidate property names, per object kind. Each is TRIED and its resolution reported; nothing
-- here is assumed to exist on this build.
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

-- Returns value, resolved. `resolved` is false only when the READ ITSELF failed -- the property
-- does not exist on this build -- which is a different fact from a property that exists and reads
-- nil or false. Conflating the two is how a missing property gets read as a zero.
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
    -- Type-checked, not merely nil-checked: a non-vector reaching here made string.format throw,
    -- which killed the whole sample loop for four minutes and read in the log exactly like a game
    -- that had gone quiet (2026-09-04). An instrument may return "?"; it may never raise.
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return "?" end
    return string.format("%.0f,%.0f,%.0f", x, y, z)
end

local function short(name)
    -- "AudioComponent /Game/...:PersistentLevel.BP_PlayerGoatMain_C_2.Audio_0" -> the trailing part
    return (name and name:match("([^%.]+)$")) or name or "?"
end

-- Attribution is by NAME CONTAINMENT, the one test that has never failed here (`../CLAUDE.md`):
-- a component's full name carries its owning chain, while outer walks missed 12 of 12 on a ghost.
local function owner_of(comp_name, pawns)
    for _, p in ipairs(pawns) do
        if comp_name:find(p.short, 1, true) then return p.tag, p.pos end
    end
    return "world", "?"
end

-- **The first version of this asked each pawn for its Controller and called a pawn holding one the
-- player. Measured 2026-09-04, in the run it was written for: EVERY pawn reads possessed, ghosts
-- included, so every ghost component was labelled PLAYER.** The coverage line is the only reason
-- that was visible rather than believed -- it prints the evidence the tag was decided from, which
-- is what `../../agent_docs/checklists/before-trusting-a-reading.md` asks of a boolean.
--
-- So the direction is reversed: ask the CONTROLLER which pawn it drives, and everything else of
-- that class is a ghost (or a corpse the transition has not collected yet). One authority, no
-- per-pawn guess.
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
                -- The owner's WORLD POSITION travels with every event, because the run turned into
                -- a spatial question: in a dead window a ghost's footstep cue spawns a component
                -- and the player's identical cue does not, and only the two positions say where
                -- the listener would have to be sitting for both of those to be true.
                local root = prop(pawn, "RootComponent")
                local loc = root ~= nil and prop(root, "RelativeLocation") or nil
                pawns[#pawns + 1] = {short = s, tag = (driven and s == driven) and "PLAYER" or "ghost",
                                     full = n, possessed = ctrl ~= nil, pos = vec_text(loc)}
            end
        end
    end
    return pawns, driven, via
end

-- Where the game is LISTENING from. Unreal's audio listener follows the camera manager's view
-- target unless a controller overrides it, and this adapter's SetViewTargetWithBlend hook rewrites
-- that argument when a ghost's own camera rig is chosen -- so a view target left on a rig from the
-- zone you just left would put the listener there too, which is a shape that fits "my own SFX went
-- quiet after a zone change" better than anything on the component. Logged only when it CHANGES.
local last_view_target = nil

-- Measured 2026-09-04: after a zone change with a ghost present, NOTHING spatialized spawns a
-- component any more -- not the player's cues, not the level's -- while music keeps playing, and it
-- all comes back the moment a ghost spawns (which our camera hook answers by re-applying the view
-- target). That is the signature of a LISTENER left behind, because SpawnSoundAttached refuses to
-- create a component for a sound out of audible range of the nearest listener. So the question is
-- no longer "who is playing what" but WHERE the game thinks it is listening from: the camera
-- manager's own cached point of view is what feeds the listener, so print it next to the player.
local function pov_location(cam)
    local cache = prop(cam, "CameraCache")
    local pov = cache ~= nil and prop(cache, "POV") or nil
    local loc = pov ~= nil and prop(pov, "Location") or nil
    return loc
end

-- **The report changed shape on 2026-09-04: the sound follows GHOST PRESENCE, not the zone change**
-- -- it came back when the chaser spawned and went away when it despawned. A ghost here is a real
-- player pawn and reads as POSSESSED, so the thing to count is how many controllers and local
-- players the game thinks it has: an audio listener belongs to a LOCAL PLAYER, and a second one
-- arriving with the ghost (or the surviving one being left behind when the ghost goes) would put
-- the listener somewhere other than the player without moving the camera at all. Logged on change.
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

-- **The listener-override fields were tried here first and DO NOT READ on this build**: every one
-- of `bOverrideAudioListener`, `AudioListenerComponent` and their neighbours handed back a fresh
-- UObject wrapper at a different address every sample -- a shape `prop()` reports as resolved,
-- because the read itself succeeds. Recorded rather than quietly dropped: a value that changes
-- every 200ms is the tell that a reflected read is returning a wrapper, not a value.
--
-- So the same question is asked from the other side. Sound that is PLAYED but INAUDIBLE, with
-- music unaffected and audibility following ghost presence, fits a SOUND CLASS whose volume is
-- being driven to zero as exactly as it fits a misplaced listener -- and a sound class's volume is
-- a plain named read. If a class drops to 0 on the despawn and returns on the next spawn, that is
-- the mechanism, and it says which class to look at. Logged only when a volume CHANGES.
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

-- A `USoundMix` can carry its own `Duration`: applied, it fades out and expires by itself with no
-- second call. That is the one shape that would explain sound dying with nothing calling anything
-- -- so the mixes this build has, and their durations, are worth one line at startup.
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
                -- Every ~2s: where the game is listening from, and where the player is. A gap
                -- between these two that opens at a zone change IS the fault; them tracking each
                -- other through a dead window rules the listener out and sends this elsewhere.
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

-- One dump per distinct sound asset, the first time any component is seen carrying it. This is
-- the half that answers shape two on its own.
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
            -- A TSet of USoundConcurrency*; stringifying its members would dereference pointers
            -- this probe does not own, so only its presence is reported.
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

-- ============================================================================================
-- TEMPORARY, AND THE ONLY WRITE IN THIS FILE -- remove once the 2026-09-04 verdict is in.
--
-- The fix under test lives in `../../probe_audiofix/`, which is where it belongs and where it
-- stays. It is hosted here for one session only because **UE4SS loads mod folders at launch**:
-- `RestartMod` answers "Could not find mod to reinstall" for a folder that was not there when the
-- game started (measured 2026-08-29, `../../PROBES.md`), and the alternative was making the user
-- relaunch mid-session. The census is otherwise read-only and goes back to being so.
--
-- What it does: when a new ghost appears -- the moment its BeginPlay has taken the player's audio
-- attenuation listener -- put the listener back on the LOCAL player's own capsule.
-- ============================================================================================
local TEST_REPOINT = true
local known_ghost_names = {}
local repoints = 0
local repointing = false   -- re-entrancy guard: our own call fires the hook below

local function repoint_listener(reason)
    if repointing then return end
    local pcs = FindAllOf("PlayerController")
    if not pcs then return end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            local pawn = prop(pc, "AcknowledgedPawn") or prop(pc, "Pawn")
            if pawn ~= nil and valid(pawn) then
                local root = prop(pawn, "RootComponent")
                local rn = (root ~= nil and valid(root)) and full_name(root) or nil
                -- The component is name-CHECKED against what the game itself passes; re-pointing
                -- the listener at the wrong thing would be a second bug wearing this fix's name.
                if rn and rn:find("CollisionCylinder", 1, true) then
                    -- The guard is set around the call ITSELF, because our own call re-enters
                    -- the hook that may have asked for it.
                    repointing = true
                    local ok, err = pcall(function()
                        pc:SetAudioListenerAttenuationOverride(root, {X = 0.0, Y = 0.0, Z = 0.0})
                    end)
                    repointing = false
                    repoints = repoints + 1
                    print(string.format("%s REPOINT #%d (%s) -> '%s'%s\n", TAG, repoints, reason, rn,
                                        ok and "" or (" FAILED: " .. tostring(err))))
                else
                    print(string.format("%s REPOINT SKIPPED (%s): root is '%s'\n", TAG, reason, tostring(rn)))
                end
                return
            end
        end
    end
end

local function sample()
    samples = samples + 1
    local pawns, driven, via = pawn_table()
    if TEST_REPOINT and driven then
        local present = {}
        for _, p in ipairs(pawns) do
            if p.tag == "ghost" then
                present[p.short] = true
                if not known_ghost_names[p.short] then
                    known_ghost_names[p.short] = true
                    repoint_listener("ghost appeared: " .. p.short)
                end
            end
        end
        for n in pairs(known_ghost_names) do
            if not present[n] then known_ghost_names[n] = nil end
        end
    end
    view_target_check()
    controller_census()
    sound_class_check()
    sound_mix_dump()

    -- The ghost's arrival is the boundary between the two halves of the run, so it marks itself.
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
                        -- The first sample sees the level's standing population; calling that
                        -- APPEAR would let the level's own audio read as something a ghost did.
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

    -- Coverage every ~10s: what was looked at, which pawns were found and how the player/ghost
    -- split was decided -- a boolean nobody can sanity-check is not a result.
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

-- **The audio-device side of the question, which no property read reaches.** A sound class's
-- `Properties.Volume` is the ASSET's default and is NOT written back when a SoundMix modifier
-- ducks that class at runtime, so the census above can read 1.00 through a completely silenced
-- SFX class. The calls that DO that are BlueprintCallable statics on GameplayStatics, and they are
-- native, which is the one kind of UFunction this host allows hooking (`../CLAUDE.md`: never hook
-- a Blueprint one). This game splits its classes exactly the way the symptom does --
-- `SoundClass_SFX`, `SoundClass_Music`, `SoundClass_UI` -- so a mix pushed or popped around a
-- ghost's life would explain "everything but the music" without any listener being involved.
--
-- Why this is the shape to suspect at all: a ghost is a CLONE OF THE PLAYER PAWN, so whatever the
-- game's own pawn does to audio on BeginPlay and EndPlay, the ghost does too -- to the one global
-- audio device the player is listening through.
--
-- **`SetAudioListenerOverride` is in this list for the reason the mix calls turned out NOT to be
-- the answer.** Measured 2026-09-04: a ghost spawn fires `SetBaseSoundMix(MySoundMix)` plus four
-- class overrides -- SFX at 1.0 -- from the GAME INSTANCE, and a despawn fires nothing at all,
-- while the sound classes' own volumes never change. Mix and class are therefore both innocent,
-- and what is left is a listener PINNED TO A COMPONENT ON THE GHOST: alive it sits by the player
-- and everything is audible, destroyed it leaves the listener on a dead component, and the next
-- ghost re-registers it. This hook either catches that call with a ghost-owned component in it or
-- takes the theory off the table.
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
                -- **REACTIVE CORRECTION, and the poll could not do this job.** Measured
                -- 2026-09-04: at a zone change the 5Hz repoint landed 6ms BEFORE a ghost's own
                -- BeginPlay took the listener again, so the poll "fixed" it and then lost it in
                -- the same frame. Answering the call itself is the only timing that cannot be
                -- raced -- the same shape the C++ mod already uses for SetViewTargetWithBlend.
                if TEST_REPOINT and fn == "SetAudioListenerAttenuationOverride" and first ~= nil
                   and not repointing then
                    local n = full_name(first)
                    local _, driven_pawn = nil, nil
                    local pcs2 = FindAllOf("PlayerController")
                    if pcs2 then
                        for _, pc2 in pairs(pcs2) do
                            if valid(pc2) then
                                local pw = prop(pc2, "AcknowledgedPawn") or prop(pc2, "Pawn")
                                if pw ~= nil and valid(pw) then driven_pawn = full_name(pw) break end
                            end
                        end
                    end
                    -- Only correct a call that names something OTHER than the pawn the controller
                    -- is driving, and only when we actually know which that is: the player's own
                    -- BeginPlay makes this same call legitimately, and a transition has a window
                    -- where no pawn is acknowledged yet. Refusing to act while blind is the
                    -- direction whose failure is a stale listener the poll below still catches.
                    if n and driven_pawn and not n:find(short(driven_pawn), 1, true) then
                        repoint_listener("stolen by " .. short(n))
                    end
                end
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
            -- The ARGUMENTS are the point, not the fact of the call: measured 2026-09-04, a ghost
            -- SPAWN fires SetBaseSoundMix plus four SetSoundMixClassOverride and a DESPAWN fires
            -- nothing at all -- so the sound coming back is a mix being re-applied, and whatever
            -- takes it away does not go through GameplayStatics. Which mix, which class and which
            -- volume is what separates "the ghost restores the gameplay mix" from "the ghost
            -- applies a mix that then expires on its own Duration".
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

-- The sample runs under pcall, and the first failure says so ONCE and then keeps sampling. An
-- error thrown out of here stops the loop for the rest of the session while the log goes quiet,
-- which is indistinguishable from a game doing nothing -- measured 2026-09-04, four minutes lost
-- to a string.format on a value that was not a vector.
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
