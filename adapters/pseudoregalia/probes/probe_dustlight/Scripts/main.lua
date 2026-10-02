-- Which lights the player and each ghost carry, and whether landing dust fires on the wrong character's landing:
-- a light census, then every new Niagara or Cascade component on one clock with each character's landings.
-- Read-only, but it polls whole-world FindAllOf: judge nothing about smoothness while it runs.
-- Ships without an enabled.txt: it crashed the game twice, in its ChildActorComponent pass.

local UEHelpers = require("UEHelpers")

local TAG = "[MeshGhostDustLightProbe]"

-- Off prints one line and does nothing else: a polling census left running is a suspect in every later report.
local PROBE_ENABLED = true

-- Ghosts spawn from the player's pawn class, so every instance that is not UEHelpers.GetPlayer() is a ghost.
local PLAYER_CLASS = "BP_PlayerGoatMain_C"

local PHASE1_SECONDS = 10       -- light census, before any play
local WATCH_SECONDS = 180       -- VFX watch: jump, land, jump next to the ghost, repeatedly
local POLL_MS = 33              -- ~2 game frames; a Niagara burst outlives this comfortably
local COUNTDOWN_EVERY = 15      -- seconds between "keep going, N left" lines

----------------------------------------------------------------------------
-- Guarded readers: an absent property is reported as absent rather than taking the run down.
----------------------------------------------------------------------------

-- Safe to call a function on? FindAllOf returns class default objects and half-torn-down objects too, and a pcall
-- does not catch an access violation in native code, so the guard refuses the call rather than wrapping it.
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

-- The component's own transform, else its owning actor's: a world-spawned and an attached effect differ.
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
-- Who is who.
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

-- Which character an object belongs to, or nil; proximity is reported separately. Both chains are walked: a
-- ChildActorComponent's actor has the level as its Outer, and only AttachParent still connects it to the pawn.
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

-- "PLAYER 41.2 | GHOST1 903.7": raw distances, not a verdict, to read against the shipped mirror's radius.
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

-- An unowned light this close to a character is printed too; 600 is MIRROR_WORLD_VFX_RADIUS, so both agree on "at".
local LIGHT_NEAR_RADIUS = 600.0

local function censusLights(chars, phaseLabel)
    for _, className in ipairs(LIGHT_CLASSES) do
        local instances = FindAllOf(className) or {}
        local mine = 0
        local near = 0
        for _, comp in ipairs(instances) do
          if usable(comp) then
            local owner = ownerLabel(comp, chars)
            -- The proximity fallback, reported as one.
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

-- Every pawn property whose name mentions light, per character: a value that differs is a value being copied.
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

-- The player-state line that segments the log into jumps.
local function playerStateLine(chars)
    if #chars == 0 then return "<no player>" end
    local p = chars[1].obj
    return string.format("moveState=%s actionState=%s animJumpType=%s",
        describe(prop(p, "moveState")), describe(prop(p, "actionState")),
        describe(prop(p, "animJumpType")))
end

-- The landing timeline: each character's MovementMode transitions, printed raw, on the effects' clock. Z rides
-- along because a driven ghost may never run its movement component, and then Z is the only landing signal.
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
-- The run: fixed phases and a countdown.
----------------------------------------------------------------------------

local started = false
local elapsedMs = 0
local lastCountdown = 0

local function beginRun()
    print(string.format("%s ===== RUN START =====\n", TAG))
    -- Whoever holds still is the one whose log proves the dust fired without their own landing.
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
    -- The title screen map has a pawn too, so wait for a real zone.
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
