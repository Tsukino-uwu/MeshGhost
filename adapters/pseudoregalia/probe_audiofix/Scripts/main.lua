-- MeshGhost audio-listener fix probe -- **THIS ONE WRITES**, unlike every other probe in
-- `../PROBES.md`. It exists to test one fix before it is built into the shipping C++ mod, per the
-- user's call 2026-09-04: *"try with lua first, so we actually test the fix before making it"*.
--
-- THE FAULT (cause found 2026-09-04, `../UNVERIFIED.md`): `BP_PlayerGoatMain_C` pins the player
-- controller's audio ATTENUATION listener to its own collision capsule when it begins play --
-- caught twice out of two ghost spawns, ~0.1s before each one:
--
--   SetAudioListenerAttenuationOverride(CapsuleComponent ...BP_PlayerGoatMain_C_<ghost>.CollisionCylinder)
--
-- A ghost is a clone of that pawn, so every ghost steals the listener. While it lives it stands
-- near the player and everything sounds normal; when it despawns the override still names a
-- destroyed component and every SPATIALIZED sound attenuates to nothing, while music -- 2D, which
-- never consults attenuation -- keeps playing. The next ghost re-points it and the sound returns.
--
-- THE FIX UNDER TEST: on the tick a new ghost appears, put the attenuation listener back on the
-- LOCAL player's own capsule.
--
-- **CONFIRMED 2026-09-04 and SHIPPED** -- the user, after testing both cases: *"yee both the
-- spawn/despawn & zone transition sfx things are fixed now"*. This folder is kept as the record of
-- how it was proven, not as the fix: `Plugin.cpp`'s `register_audio_listener_guard` carries it in
-- production. **The shipping shape is deliberately different and better**: it REWRITES the
-- argument of `SetAudioListenerAttenuationOverride` in a pre-hook, so the engine's own call uses
-- the corrected component and there is no second call at all.
--
-- **The ordering lesson this file paid for, because a second call has to answer WHEN:** correcting
-- in a PRE hook applies the fix and then lets the engine overwrite it, so only the 5Hz poll below
-- ever healed anything -- a despawn recovered *most* times (*"works sometimes"*) and a zone
-- crossing never did, because on a crossing the poll had already spent its one shot on that
-- ghost's arrival before the steal. Moving the correction to the POST hook fixed both. A rewrite
-- sidesteps the question entirely, which is why the shipped one does that instead.
--
-- **What makes this safe enough to write from Lua:** the only call is on the ONE live
-- `PlayerController` that names a valid `AcknowledgedPawn` -- not on whatever `FindAllOf` handed
-- back first, and never on a ghost. It changes one listener attachment and nothing else; it writes
-- no save, no game state, no ROM.
--
-- **It is a DEV TOOL and must not be left armed.** It is not the shipping fix; it re-points on an
-- edge this probe polls for at 5Hz, where the real one belongs on the spawn itself. Delete the
-- folder (or its enabled.txt) once the answer is in.
--
-- Grounded APIs: APlayerController::SetAudioListenerAttenuationOverride(USceneComponent*, FVector)
-- (docs.unrealengine.com, PlayerController.h) -- and it is NATIVE, which is the one kind of
-- UFunction this host allows touching (`../CLAUDE.md`). UE4SS Lua FindAllOf / ExecuteInGameThread /
-- LoopAsync / IsValid / GetFullName (vendored RE-UE4SS/docs/lua-api).
--
-- Deploy: copy probe_audiofix/ to <install>\...\Win64\ue4ss\Mods\MeshGhostAudioFix\ with an
-- enabled.txt; reload via probe_reloader ("MeshGhostAudioFix <nonce>").

local TAG = "[MeshGhostAudioFix]"

local INTERVAL_MS = 200
local PAWN_CLASS = "BP_PlayerGoatMain_C"

local known_ghosts = {}   -- ghost pawn full name -> true, so each new ghost is answered once
local repoints = 0
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

local function prop(obj, name)
    local v
    local ok = pcall(function() v = obj[name] end)
    if not ok then return nil, false end
    return v, true
end

-- The controller is the authority on which pawn is the player -- asking each pawn whether it is
-- possessed does NOT work here, because a ghost reads as possessed too (measured 2026-09-04,
-- `../../agent_docs/pitfalls/method.md`). Returns the controller and its pawn, or nothing.
local function player_controller_and_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({"AcknowledgedPawn", "Pawn"}) do
                local pawn = prop(pc, field)
                if pawn ~= nil and valid(pawn) then return pc, pawn end
            end
        end
    end
    return nil
end

-- The capsule is the pawn's RootComponent on a Character, and the log confirms the shape the game
-- itself passes: an object named CollisionCylinder. The name is CHECKED rather than assumed, and a
-- mismatch is logged instead of written -- re-pointing the listener at the wrong component would
-- be a second bug wearing this fix's name.
local function player_capsule(pawn)
    local root = prop(pawn, "RootComponent")
    if root == nil or not valid(root) then return nil, "no RootComponent" end
    local n = full_name(root) or "?"
    if not n:find("CollisionCylinder", 1, true) then
        return nil, "RootComponent is '" .. n .. "', not the CollisionCylinder the game passes"
    end
    return root, n
end

local function repoint(reason)
    local pc, pawn = player_controller_and_pawn()
    if not pc then
        print(string.format("%s SKIP (%s): no controller names a pawn\n", TAG, reason))
        return
    end
    local capsule, detail = player_capsule(pawn)
    if not capsule then
        print(string.format("%s SKIP (%s): %s\n", TAG, reason, detail))
        return
    end
    local ok, err = pcall(function()
        pc:SetAudioListenerAttenuationOverride(capsule, {X = 0.0, Y = 0.0, Z = 0.0})
    end)
    if ok then
        repoints = repoints + 1
        print(string.format("%s REPOINT #%d (%s) -> '%s'\n", TAG, repoints, reason, detail))
    else
        print(string.format("%s REPOINT FAILED (%s): %s\n", TAG, reason, tostring(err)))
    end
end

local function sample()
    samples = samples + 1
    local pc, player = player_controller_and_pawn()
    if not player then return end
    local player_name = full_name(player)

    local found = FindAllOf(PAWN_CLASS)
    if not found then return end
    local seen_now = {}
    for _, pawn in pairs(found) do
        if valid(pawn) then
            local n = full_name(pawn)
            if n and n ~= player_name then
                seen_now[n] = true
                if not known_ghosts[n] then
                    known_ghosts[n] = true
                    -- A NEW ghost is exactly the moment its BeginPlay has taken the listener.
                    repoint("ghost appeared: " .. n:match("([^%.]+)$"))
                end
            end
        end
    end
    for n in pairs(known_ghosts) do
        if not seen_now[n] then known_ghosts[n] = nil end
    end

    if samples % 100 == 1 then
        local ghosts = 0
        for _ in pairs(known_ghosts) do ghosts = ghosts + 1 end
        print(string.format("%s WATCHING ghosts=%d repoints=%d samples=%d\n", TAG, ghosts, repoints, samples))
    end
end

-- The sample runs under pcall and reports its first failure once: a probe that throws goes silent,
-- and silence reads exactly like a game doing nothing (2026-09-04, the census probe).
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

-- Once at load as well, so a session that already lost its listener to a ghost recovers without
-- waiting for the next spawn -- and so the very first line says whether the call works at all.
ExecuteInGameThread(function() repoint("probe loaded") end)

print(string.format("%s loaded -- WRITES: puts the audio attenuation listener back on the player's capsule whenever a ghost appears.\n", TAG))
