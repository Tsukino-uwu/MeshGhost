-- MeshGhost dust/light probe. TWO questions, both from UNVERIFIED.md's 2026-08-28 entry "Two
-- ghost cosmetics the user saw wrong on screen" -- the only entries in that file the user has
-- already looked at and called wrong. Neither has ever been measured, so this probe measures
-- rather than fixes, and nothing below writes game state.
--
--   1. LANDING DUST, and the user sharpened it on 2026-08-29: the dust fires *"whenever you
--      land after jumping"*, the ghost *"doesn't handle it on its own"*, so it *"just happens
--      whenever the player does it, and gets replicated onto the ghost at wrong times"* --
--      first seen on a TWO-INSTANCE session. So this is not a missing effect, it is an effect
--      fired by the wrong character's landing. That makes WHEN the measurement, not WHAT: the
--      run has to put the landings and the effects on one clock and show them disagreeing.
--      The shipped mirror carries a `dl` row (`NS_DustLand`, world-spawned, attributed to the
--      SENDER by proximity) -- reading whether that row's timing can ever match the ghost's
--      own landing is the point of the timeline below.
--   2. ASCENDANT LIGHT. The user: it *"emits from the player itself, or maybe from the
--      ascendant light upgrade"*, and *"makes the game look a bit too bright when nearby other
--      ghosts/players"* -- i.e. every ghost carries its own copy of the player's emitter and
--      they add up. Earlier the same week: these *"should always be off for a ghost similar to
--      the blue outline things"*. Before it can be forced off, the thing that is on has to be
--      named -- a light component, a child actor, a pawn property, or some combination.
--
-- What one run does, in fixed phases with a countdown (never a window to hit):
--   PHASE 1, ~10s: LIGHT CENSUS. Every light component and ChildActorComponent in the world,
--      attributed to its owning actor via GetOuter(), with the PLAYER and each GHOST called out
--      by name. Then every property on the pawn class whose name mentions light, dumped for the
--      player and each ghost SIDE BY SIDE -- a value that differs is a value being copied.
--   PHASE 2, until the end: VFX WATCH. Polls the world for NiagaraComponent and
--      ParticleSystemComponent instances and prints each one the moment it FIRST appears, with
--      its asset, owner, attach parent, world position, and its distance to the player and to
--      every ghost. Cascade is polled as well as Niagara deliberately: `VERIFIED.md` records a
--      pass that silently assumed Niagara purely because the sword's ring happened to be Niagara.
--   PHASE 3, ~10s: the light census again, so anything the play session turned on is visible as
--      a change rather than as an absolute.
--
-- Dump everything and filter afterwards (`_template/probes.md`): the run prints every new
-- component, not the ones whose names look like dust. `NS_DustLand` fires on ordinary landings
-- too, so a jump that produces it is not evidence of a jump effect -- the segmentation is the
-- player-state line printed alongside, which carries moveState/actionState/animJumpType.
--
-- COST: this is a polling census over two whole-world FindAllOf calls. `../../CLAUDE.md` --
-- a diagnostic can break the thing it measures. Nothing here is a spawn, a hook or a write, but
-- the poll is not free, so judge nothing about SMOOTHNESS while it runs, and re-run with
-- PROBE_ENABLED false before believing any timing result.
--
-- Grounded APIs, none from memory. UE4SS Lua surface (FindAllOf, StaticFindObject, IsValid,
-- GetFullName, GetOuter, GetClass, GetSuperStruct, UStruct:ForEachProperty, ExecuteInGameThread,
-- LoopAsync, UEHelpers.GetPlayer/GetWorld) -- vendored RE-UE4SS/docs/lua-api, and every one of
-- them is already exercised by probe_nametag/Scripts/main.lua on this build. Reflected engine
-- names come from Epic's public API documentation and are ALL pcall-guarded and reported when
-- absent, because availability on this build is a runtime question (`../CLAUDE.md`):
--   UNiagaraComponent::Asset                  -- docs.unrealengine.com, UNiagaraComponent
--   UParticleSystemComponent::Template        -- docs.unrealengine.com, UParticleSystemComponent
--   USceneComponent::{AttachParent, bVisible} -- docs.unrealengine.com, USceneComponent
--   UActorComponent::bIsActive                -- docs.unrealengine.com, UActorComponent
--   ULightComponentBase::{Intensity, LightColor, bAffectsWorld} -- docs.unrealengine.com
--   UChildActorComponent::{ChildActorClass, ChildActor}         -- docs.unrealengine.com
--   AActor::K2_GetActorLocation               -- docs.unrealengine.com, AActor
--
-- Deploy: copy probe_dustlight/ to <install>\...\Win64\ue4ss\Mods\MeshGhostDustLightProbe\ (the
-- folder carries its own enabled.txt), then reload it through probe_reloader/ rather than the
-- Ctrl+R keybind. READ-ONLY: no spawns, no writes, no saves. Dev-only tooling; never ships.

local UEHelpers = require("UEHelpers")

local TAG = "[MeshGhostDustLightProbe]"

-- OFF means: print one line and do nothing else. Set it false the moment the question of the
-- hour is not dust or light -- a polling census left running is a suspect in every report that
-- follows, and this adapter has already had that happen once (probe_nametag, 2026-08-29).
local PROBE_ENABLED = true

-- The player's own Blueprint class. Both the local player and every ghost are instances of it
-- (the ghost is spawned from the player's pawn class -- Plugin.cpp's SpawnActor), so "every
-- instance that is not UEHelpers.GetPlayer()" is exactly the set of ghosts.
local PLAYER_CLASS = "BP_PlayerGoatMain_C"

local PHASE1_SECONDS = 10       -- light census, before any play
local WATCH_SECONDS = 180       -- VFX watch: jump, land, jump next to the ghost, repeatedly
local POLL_MS = 33              -- ~2 game frames; a Niagara burst outlives this comfortably
local COUNTDOWN_EVERY = 15      -- seconds between "keep going, N left" lines

----------------------------------------------------------------------------
-- Small guarded readers. Everything reflected goes through one of these, so an absent
-- property is REPORTED as absent rather than taking the run down.
----------------------------------------------------------------------------

-- Is this object safe to CALL A FUNCTION ON? Added 2026-08-29 after the first attempt to run this
-- probe coincided with a crash at LoadMap -- EXCEPTION_ACCESS_VIOLATION reading 0x20, with a
-- callstack ~15 frames deep inside UE4SS's own Lua/reflection machinery and no game or adapter
-- frame in it. Not proven to be this probe (the run's log was truncated by a second instance
-- launching), but this is the shape that would do it.
--
-- `FindAllOf` returns every object of a class in memory, which includes CLASS DEFAULT OBJECTS and
-- objects the engine is midway through tearing down. Reading a property off one of those is
-- usually survivable; calling a UFunction like K2_GetComponentLocation on one dereferences a
-- transform that is not there. **A Lua pcall does not catch an access violation in native code**,
-- so the guard has to be a refusal to call, not a wrapper around the call.
--
-- CDOs are named `Default__<Class>` by engine convention, which is the cheap half. `IsValid` is
-- the other half and is the one that moves during a transition -- this adapter's own CLAUDE.md:
-- a transition invalidates every cached reference, and the crash was at LoadMap.
local function usable(obj)
    if obj == nil then return false end
    local ok, result = pcall(function()
        if not obj:IsValid() then return false end
        local name = obj:GetFullName()
        if name == nil or name:find("Default__", 1, true) then return false end
        return true
    end)
    return ok and result == true
end

local function fullName(obj)
    local ok, name = pcall(function()
        if obj == nil or not obj:IsValid() then return "<invalid>" end
        return obj:GetFullName()
    end)
    return ok and name or "<unnameable>"
end

-- Reads obj[name], returning nil when the property does not exist on this build.
local function prop(obj, name)
    local ok, value = pcall(function() return obj[name] end)
    if not ok then return nil end
    return value
end

local function describe(value)
    if value == nil then return "<absent>" end
    local t = type(value)
    if t == "number" or t == "string" or t == "boolean" then return tostring(value) end
    local text = nil
    pcall(function() text = value:ToString() end)                                    -- FName/FText
    if text == nil then pcall(function() text = value:GetFullName() end) end         -- UObject
    if text == nil then
        pcall(function() text = string.format("(%.3f, %.3f, %.3f)", value.X, value.Y, value.Z) end)
    end
    if text == nil then
        pcall(function() text = string.format("(%.3f, %.3f, %.3f, %.3f)", value.R, value.G, value.B, value.A) end)
    end
    if text == nil then pcall(function() text = tostring(value) end) end
    return text or "<?>"
end

local function actorLocation(actor)
    local ok, loc = pcall(function() return actor:K2_GetActorLocation() end)
    if not ok or loc == nil then return nil end
    local x, y, z
    local read = pcall(function() x, y, z = loc.X, loc.Y, loc.Z end)
    if not read or x == nil then return nil end
    return { X = x, Y = y, Z = z }
end

-- A component's world position, preferring the component's own transform and falling back to
-- its owning actor -- a world-spawned effect and an attached one need different answers.
local function componentLocation(comp)
    local ok, loc = pcall(function() return comp:K2_GetComponentLocation() end)
    if ok and loc ~= nil then
        local x, y, z
        if pcall(function() x, y, z = loc.X, loc.Y, loc.Z end) and x ~= nil then
            return { X = x, Y = y, Z = z }
        end
    end
    local outer = nil
    pcall(function() outer = comp:GetOuter() end)
    if outer ~= nil then return actorLocation(outer) end
    return nil
end

local function distance(a, b)
    if a == nil or b == nil then return nil end
    local dx, dy, dz = a.X - b.X, a.Y - b.Y, a.Z - b.Z
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

----------------------------------------------------------------------------
-- Who is who. The label is what makes every line below readable at a glance.
----------------------------------------------------------------------------

-- Returns { {obj=, label=, loc=}, ... } -- the local player first, then each ghost.
local function characters()
    local out = {}
    local player = nil
    pcall(function()
        local p = UEHelpers.GetPlayer()
        if usable(p) then player = p end
    end)
    local playerAddr = nil
    if player ~= nil then
        pcall(function() playerAddr = player:GetAddress() end)
        out[#out + 1] = { obj = player, label = "PLAYER", loc = actorLocation(player) }
    end
    local all = FindAllOf(PLAYER_CLASS) or {}
    local ghostIndex = 0
    for _, pawn in ipairs(all) do
        local addr = nil
        pcall(function() addr = pawn:GetAddress() end)
        local isPlayer = (playerAddr ~= nil and addr == playerAddr)
        if usable(pawn) and not isPlayer then
            ghostIndex = ghostIndex + 1
            out[#out + 1] = { obj = pawn, label = string.format("GHOST%d", ghostIndex),
                              loc = actorLocation(pawn) }
        end
    end
    return out
end

-- Which character an object belongs to. Returns a label or nil. Proximity is reported
-- separately and never conflated with this.
--
-- TWO chains are walked, not one, and the second is the reason this function is not three
-- lines. A component's Outer reaches its owning actor -- but a ChildActorComponent spawns a
-- separate ACTOR whose own Outer is the LEVEL, so a light living inside a child actor (which
-- is exactly the shape UNVERIFIED.md names for `PlayerLight`/`PointLight`) is invisible to an
-- Outer walk and would have been silently reported as belonging to nobody. AttachParent is
-- what still connects it to the pawn, so both are followed at every step.
local function ownerLabel(obj, chars)
    local addrs = {}
    for _, c in ipairs(chars) do
        local a = nil
        pcall(function() a = c.obj:GetAddress() end)
        if a ~= nil then addrs[a] = c.label end
    end
    local seenNodes = {}
    local queue = { obj }
    local head = 1
    while head <= #queue and head <= 32 do
        local node = queue[head]
        head = head + 1
        if node ~= nil then
            local a = nil
            pcall(function() a = node:GetAddress() end)
            if a ~= nil and not seenNodes[a] then
                seenNodes[a] = true
                if addrs[a] ~= nil then return addrs[a] end
                local outer, attach = nil, nil
                pcall(function() outer = node:GetOuter() end)
                pcall(function() attach = node.AttachParent end)
                if outer ~= nil then queue[#queue + 1] = outer end
                if attach ~= nil then queue[#queue + 1] = attach end
            end
        end
    end
    return nil
end

-- "PLAYER 41.2 | GHOST1 903.7" -- the proximity line, printed for every new effect. This is
-- how a world-spawned effect gets attributed, and it is deliberately a raw number rather than
-- a verdict: the shipped mirror's own radius is 600, and reading whether a real jump falls
-- inside that is the point.
local function proximityLine(loc, chars)
    if loc == nil then return "<no location>" end
    local parts = {}
    for _, c in ipairs(chars) do
        local d = distance(loc, c.loc)
        parts[#parts + 1] = string.format("%s %s", c.label, d and string.format("%.1f", d) or "?")
    end
    return table.concat(parts, " | ")
end

----------------------------------------------------------------------------
-- PHASE 1 and 3 -- the light census.
----------------------------------------------------------------------------

local LIGHT_CLASSES = {
    "PointLightComponent", "SpotLightComponent", "RectLightComponent",
    "DirectionalLightComponent", "SkyLightComponent", "LightComponent",
    "ChildActorComponent",
}

local LIGHT_FIELDS = {
    "Intensity", "LightColor", "AttenuationRadius", "bAffectsWorld",
    "bVisible", "bHiddenInGame", "bIsActive", "ChildActorClass", "ChildActor",
}

-- How close an UNATTRIBUTED light has to be to a character to be worth printing. The user's
-- report is that the scene goes too bright *near* other ghosts, and a light that turns out to
-- be parented to nothing would never appear in an ownership walk -- so a light nobody owns but
-- which is sitting on top of a character is precisely the case that must not be filtered out.
-- 600 matches the shipped mirror's own MIRROR_WORLD_VFX_RADIUS so the two agree on "at".
local LIGHT_NEAR_RADIUS = 600.0

local function censusLights(chars, phaseLabel)
    for _, className in ipairs(LIGHT_CLASSES) do
        local instances = FindAllOf(className) or {}
        local mine = 0
        local near = 0
        for _, comp in ipairs(instances) do
          if usable(comp) then
            local owner = ownerLabel(comp, chars)
            -- Proximity fallback, reported AS a fallback: an unowned light close enough to a
            -- character to be the thing the user is seeing.
            if owner == nil then
                local loc = componentLocation(comp)
                for _, c in ipairs(chars) do
                    local d = distance(loc, c.loc)
                    if d ~= nil and d <= LIGHT_NEAR_RADIUS then
                        owner = string.format("<unowned, %.0f from %s>", d, c.label)
                        near = near + 1
                        break
                    end
                end
            else
                mine = mine + 1
            end
            if owner ~= nil then
                local fields = {}
                for _, field in ipairs(LIGHT_FIELDS) do
                    local value = prop(comp, field)
                    if value ~= nil then
                        fields[#fields + 1] = string.format("%s=%s", field, describe(value))
                    end
                end
                local attach = prop(comp, "AttachParent")
                print(string.format("%s LIGHT[%s]: %s owner=%s %s attach=%s\n",
                    TAG, phaseLabel, fullName(comp), owner,
                    table.concat(fields, " "), attach and fullName(attach) or "<none>"))
            end
          end
        end
        print(string.format("%s LIGHT[%s]: %s -- %d in world, %d on a character, %d unowned but within %.0f.\n",
            TAG, phaseLabel, className, #instances, mine, near, LIGHT_NEAR_RADIUS))
    end
end

-- Every property on the pawn class whose name mentions light, for each character. A value that
-- differs between PLAYER and GHOST is a value somebody is copying; one that matches on a run
-- where the player HAS the upgrade and the ghost should not is the bug named.
local function censusLightProperties(chars, phaseLabel)
    if #chars == 0 then return end
    local names = {}
    local ok = pcall(function()
        local cls = chars[1].obj:GetClass()
        while cls ~= nil and cls:IsValid() do
            cls:ForEachProperty(function(p)
                local n = p:GetFName():ToString()
                if n:lower():find("light") then names[#names + 1] = n end
            end)
            cls = cls:GetSuperStruct()
        end
    end)
    if not ok then
        print(string.format("%s LIGHTPROP[%s]: property walk FAILED on the pawn class.\n", TAG, phaseLabel))
        return
    end
    if #names == 0 then
        print(string.format("%s LIGHTPROP[%s]: no property on %s mentions 'light'.\n", TAG, phaseLabel, PLAYER_CLASS))
        return
    end
    for _, name in ipairs(names) do
        local parts = {}
        for _, c in ipairs(chars) do
            parts[#parts + 1] = string.format("%s=%s", c.label, describe(prop(c.obj, name)))
        end
        print(string.format("%s LIGHTPROP[%s]: %s  %s\n", TAG, phaseLabel, name, table.concat(parts, "  ")))
    end
end

local function runLightCensus(phaseLabel)
    local chars = characters()
    local labels = {}
    for _, c in ipairs(chars) do labels[#labels + 1] = c.label end
    print(string.format("%s ===== LIGHT CENSUS [%s]: %d character(s) -- %s =====\n",
        TAG, phaseLabel, #chars, table.concat(labels, ", ")))
    if #chars < 2 then
        print(string.format("%s LIGHT[%s]: NO GHOST IN THE WORLD. The census still stands for the player, but the comparison this phase exists for needs a peer connected.\n", TAG, phaseLabel))
    end
    censusLights(chars, phaseLabel)
    censusLightProperties(chars, phaseLabel)
end

----------------------------------------------------------------------------
-- PHASE 2 -- the VFX watch.
----------------------------------------------------------------------------

local VFX_CLASSES = { "NiagaraComponent", "ParticleSystemComponent" }

local seen = {}          -- address -> true, so each component prints exactly once
local newCount = 0

-- The player-state line that segments the log into jumps. These three fields are the ones
-- `effect-investigation.md` settled the slide with, so they are the ones that make a burst
-- readable as "this happened during a jump" afterwards.
local function playerStateLine(chars)
    if #chars == 0 then return "<no player>" end
    local p = chars[1].obj
    return string.format("moveState=%s actionState=%s animJumpType=%s",
        describe(prop(p, "moveState")), describe(prop(p, "actionState")),
        describe(prop(p, "animJumpType")))
end

-- The LANDING TIMELINE, and the half of this probe that the user's own report asks for: the
-- dust is said to fire on the ghost when the LOCAL PLAYER lands rather than when the GHOST
-- does. That is a claim about WHEN, so a list of effects can never settle it -- the log needs
-- the landings themselves next to the effects, on the same clock.
--
-- MovementMode is what marks a landing (UCharacterMovementComponent::MovementMode --
-- docs.unrealengine.com; the engine's EMovementMode has 1=Walking, 3=Falling). It is read
-- rather than assumed: the value is printed raw and the transition is what is reported, so a
-- build whose enum differs still produces a readable timeline. Z is printed alongside because
-- a driven ghost may never run the movement component at all -- in which case its mode never
-- changes and the Z trace is the only landing signal there is, which is itself the answer.
local lastMode = {}      -- character address -> last MovementMode seen
local lastZ = {}

local function pollMovement(chars, elapsedS)
    for _, c in ipairs(chars) do
        local addr = nil
        pcall(function() addr = c.obj:GetAddress() end)
        if addr ~= nil then
            local mode = nil
            pcall(function() mode = c.obj.CharacterMovement.MovementMode end)
            local z = c.loc and c.loc.Z or nil
            if mode ~= nil and lastMode[addr] ~= nil and mode ~= lastMode[addr] then
                print(string.format("%s MOVE t=%.2f %s MovementMode %s -> %s  z=%s (prev z=%s)\n",
                    TAG, elapsedS, c.label, tostring(lastMode[addr]), tostring(mode),
                    z and string.format("%.1f", z) or "?",
                    lastZ[addr] and string.format("%.1f", lastZ[addr]) or "?"))
            end
            if mode ~= nil then lastMode[addr] = mode end
            if z ~= nil then lastZ[addr] = z end
        end
    end
end

local function pollWorld(elapsedS)
    local chars = characters()
    pollMovement(chars, elapsedS)
    for _, className in ipairs(VFX_CLASSES) do
        local instances = FindAllOf(className) or {}
        for _, comp in ipairs(instances) do
            local addr = nil
            if usable(comp) then pcall(function() addr = comp:GetAddress() end) end
            if addr ~= nil and not seen[addr] then
                seen[addr] = true
                newCount = newCount + 1
                local asset = prop(comp, "Asset")            -- Niagara
                if asset == nil then asset = prop(comp, "Template") end   -- Cascade
                local attach = prop(comp, "AttachParent")
                local loc = componentLocation(comp)
                local outer = nil
                pcall(function() outer = comp:GetOuter() end)
                print(string.format(
                    "%s VFX t=%.2f: %s asset=%s owner=%s outer=%s attach=%s active=%s visible=%s loc=%s dist[%s] %s\n",
                    TAG, elapsedS, className, describe(asset),
                    ownerLabel(comp, chars) or "<not a character>",
                    fullName(outer), attach and fullName(attach) or "<none>",
                    describe(prop(comp, "bIsActive")), describe(prop(comp, "bVisible")),
                    loc and string.format("(%.1f, %.1f, %.1f)", loc.X, loc.Y, loc.Z) or "?",
                    proximityLine(loc, chars), playerStateLine(chars)))
            end
        end
    end
end

----------------------------------------------------------------------------
-- The run. Fixed phases, a countdown, and no moment the user has to hit.
----------------------------------------------------------------------------

local started = false
local elapsedMs = 0
local lastCountdown = 0

local function beginRun()
    print(string.format("%s ===== RUN START =====\n", TAG))
    -- Two instances, and the halves deliberately do not overlap: whoever holds still is the
    -- one whose log proves the dust fired without their own landing. Nothing has to be timed.
    print(string.format("%s WHAT TO DO: for the next %ds -- ON ONE INSTANCE jump and land over and over, near the other character and away from it. ON THE OTHER INSTANCE stand completely still and do not jump at all, then swap for the second half. A dust burst logged on the still instance is the defect, caught with the landing that did not happen.\n", TAG, PHASE1_SECONDS + WATCH_SECONDS))
    ExecuteInGameThread(function()
        local ok, err = pcall(function() runLightCensus("phase1-before") end)
        if not ok then print(string.format("%s phase 1 FAILED: %s\n", TAG, tostring(err))) end
    end)

    LoopAsync(POLL_MS, function()
        elapsedMs = elapsedMs + POLL_MS
        local elapsedS = elapsedMs / 1000
        if elapsedS < PHASE1_SECONDS then return false end

        if elapsedS >= PHASE1_SECONDS + WATCH_SECONDS then
            ExecuteInGameThread(function()
                local ok, err = pcall(function() runLightCensus("phase3-after") end)
                if not ok then print(string.format("%s phase 3 FAILED: %s\n", TAG, tostring(err))) end
                print(string.format("%s ===== RUN END: %d distinct VFX component(s) seen. =====\n", TAG, newCount))
            end)
            return true
        end

        if elapsedS - lastCountdown >= COUNTDOWN_EVERY then
            lastCountdown = elapsedS
            print(string.format("%s watching -- %ds left, %d VFX component(s) so far. Keep jumping.\n",
                TAG, math.floor(PHASE1_SECONDS + WATCH_SECONDS - elapsedS), newCount))
        end

        ExecuteInGameThread(function()
            local ok, err = pcall(function() pollWorld(elapsedS) end)
            if not ok then print(string.format("%s poll error: %s\n", TAG, tostring(err))) end
        end)
        return false
    end)
end

if not PROBE_ENABLED then
    print(TAG .. " loaded but DISABLED (PROBE_ENABLED = false). Nothing polled, nothing printed.\n")
else
    -- Wait for a real zone. The title screen map has a pawn too (measured 2026-08-29), so a
    -- pawn alone is not "in the game".
    LoopAsync(1000, function()
        if started then return true end
        local ready = false
        pcall(function()
            local pawn = UEHelpers.GetPlayer()
            if pawn == nil or not pawn:IsValid() then return end
            local world = UEHelpers.GetWorld()
            if world == nil or not world:IsValid() then return end
            if world:GetFullName():find("TitleScreen") then return end
            ready = true
        end)
        if not ready then return false end
        started = true
        beginRun()
        return true
    end)
    print(TAG .. " loaded; waiting for a player pawn in a real zone.\n")
end
