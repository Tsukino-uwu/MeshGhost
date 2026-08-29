-- MeshGhost light-check probe. ONE question, and it is a READBACK: after
-- `GHOST_HOLD_LIGHT_OFF` writes a ghost's ascendant light down to 0, does it STAY at 0, or does
-- the game put it back?
--
-- The shipping mod cannot answer that about itself. Its hold announces a lit light once per
-- component and is silent afterwards, so a light the game re-lights 60 times a second and the
-- hold re-darkens looks exactly like a light that was fixed on the first sweep. CLAUDE.md's rule
-- is the reason this file exists: never log the value you just wrote as proof it worked -- read it
-- back with a separate instrument.
--
-- What one run does: every second, prints one line per `PointLightComponent` in memory -- its full
-- name and its `Intensity`. Nothing else. Two ghosts and one player is three lines, and the answer
-- is read off the ghosts' column: steady 0 means the write took and nothing fights it; a value that
-- flickers between 0 and 5000 means the hold is working per-sweep and the game IS re-lighting it.
--
-- **Deliberately the smallest possible instrument, and that is the lesson it carries.** Its
-- ancestor `probe_dustlight/` went after two questions and a whole-world `ChildActorComponent`
-- walk in one run, called a UFunction on every object `FindAllOf` handed back, and CRASHED A LIVE
-- SESSION TWICE (2026-08-29, `UNVERIFIED.md`). This one:
--   * calls NO UFunction on anything -- `GetFullName` is UE4SS's own, not the game's;
--   * reads ONE property, guarded, and prints it;
--   * enumerates ONE class, the one that answered the original question.
-- `FindAllOf` still hands back class-default objects; reading a property off one is survivable,
-- which is precisely the line the crashing probe crossed.
--
-- Grounded APIs:
--   ULightComponentBase::Intensity -- docs.unrealengine.com, ULightComponentBase
--   FindAllOf, ExecuteInGameThread, LoopAsync -- vendored RE-UE4SS/docs/lua-api, checked not remembered.
--
-- Deploy: copy probe_lightcheck/ to <install>\...\Win64\ue4ss\Mods\MeshGhostLightCheck\ (the
-- folder carries its own enabled.txt). Dev-only tooling; never ships.

local TAG = "[MeshGhostLightCheck]"

-- OFF means print nothing at all. A probe that keeps logging through somebody else's test is a
-- suspect in every report that follows -- see probe_nametag's own note.
local PROBE_ENABLED = true

-- Stop on its own after this many samples, so a forgotten probe cannot log for an entire session.
-- 60 seconds is long enough to cross a level load and a few attacks, which is when a re-light
-- would happen if one ever does.
local MAX_SAMPLES = 60

local samples = 0

local function sample()
    local lights = FindAllOf("PointLightComponent")
    if not lights then
        print(string.format("%s no PointLightComponent in memory\n", TAG))
        return
    end
    for _, light in pairs(lights) do
        local name, intensity
        pcall(function() name = light:GetFullName() end)
        pcall(function() intensity = light.Intensity end)
        if name then
            print(string.format("%s LIGHT %s intensity=%s\n", TAG, name, tostring(intensity)))
        end
    end
end

LoopAsync(1000, function()
    if not PROBE_ENABLED then
        return true    -- stop the loop entirely
    end
    samples = samples + 1
    if samples > MAX_SAMPLES then
        print(string.format("%s done -- %d samples taken, stopping.\n", TAG, MAX_SAMPLES))
        return true
    end
    ExecuteInGameThread(sample)
    return false
end)

print(string.format("%s loaded -- sampling every PointLightComponent's Intensity once a second, %d times.\n", TAG, MAX_SAMPLES))
