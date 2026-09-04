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

local function short(name)
    -- "AudioComponent /Game/...:PersistentLevel.BP_PlayerGoatMain_C_2.Audio_0" -> the trailing part
    return (name and name:match("([^%.]+)$")) or name or "?"
end

-- Attribution is by NAME CONTAINMENT, the one test that has never failed here (`../CLAUDE.md`):
-- a component's full name carries its owning chain, while outer walks missed 12 of 12 on a ghost.
local function owner_of(comp_name, pawns)
    for _, p in ipairs(pawns) do
        if comp_name:find(p.short, 1, true) then return p.tag end
    end
    return "world"
end

-- The player is the pawn holding a Controller; a ghost is never possessed (the auto-possess fix,
-- phase7.md). The discriminator prints its own evidence on every coverage line, so a run where it
-- failed is readable as a failure rather than as a result.
local function pawn_table()
    local pawns = {}
    local found = FindAllOf(PAWN_CLASS)
    if not found then return pawns end
    for _, pawn in pairs(found) do
        if valid(pawn) then
            local n = full_name(pawn)
            if n then
                local ctrl = prop(pawn, "Controller")
                pawns[#pawns + 1] = {short = short(n), tag = ctrl and "PLAYER" or "ghost",
                                     full = n, possessed = ctrl ~= nil}
            end
        end
    end
    return pawns
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

local function describe(comp, kind, owner)
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
    print(string.format("%s %s owner=%s comp='%s' %s t=%.1f\n",
                        TAG, kind, owner, name, table.concat(fields, " "), os.clock()))
    if sound and valid(sound) then dump_sound(sound) end
end

local function sample()
    samples = samples + 1
    local pawns = pawn_table()

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
                    local owner = owner_of(name, pawns)
                    if not seen_comp[name] then
                        seen_comp[name] = true
                        -- The first sample sees the level's standing population; calling that
                        -- APPEAR would let the level's own audio read as something a ghost did.
                        describe(comp, samples == 1 and "BASELINE" or "APPEAR", owner)
                    end
                    local active = prop(comp, "bIsActive")
                    if active ~= nil then
                        local was = last_active[name]
                        if was ~= nil and was ~= active then
                            describe(comp, active and "START" or "STOP", owner)
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
        print(string.format("%s WATCHING AudioComponent=%d playing=%s pawns=[%s] samples=%d\n",
                            TAG, total, table.concat(play, " "), table.concat(who, " "), samples))
        if #pawns == 0 then
            print(string.format("%s COVERAGE WARNING: no %s found -- attribution is blind this sample\n",
                                TAG, PAWN_CLASS))
        end
    end
end

LoopAsync(INTERVAL_MS, function()
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- every audio component's appearance, start and stop is logged with its owner and its cue's concurrency settings.\n", TAG))
