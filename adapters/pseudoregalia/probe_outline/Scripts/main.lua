-- MeshGhost OUTLINE probe -- READ-ONLY. Who turns the PLAYER's through-walls outline on and off?
--
-- THE REPORT (user, 2026-09-05, screenshot in the session): standing among ghosts, the player's
-- own SWORD shows the blue silhouette THROUGH THE PLAYER'S OWN BODY, and it stays that way after
-- the ghosts are gone. Vanilla never draws that: body and sword both write custom depth, the
-- custom-depth pass keeps the NEAREST writer per pixel, so a sword behind the body is not "behind
-- scene depth" and gets no outline. The picture therefore says the BODY stopped writing custom
-- depth (or its render state did -- `documentation.md`, "The through-walls outline": the flag is
-- render-thread state and the bool can disagree with what is drawn). Separately: the player gets
-- outlined whenever a ghost stands between camera and player, because a ghost is opaque scene
-- depth that writes no custom depth. The user's call: a ghost must never do either.
--
-- THE THEORY THIS TESTS FIRST. `Plugin.cpp`'s GHOST_HOLD_OUTLINE_OFF walks EVERY object-typed
-- property on a ghost pawn (and on its thrown-weapon actor) and calls SetRenderCustomDepth(false)
-- on any value that has a `bRenderCustomDepth`. The pawn is a clone of the player's class; if any
-- of those properties refers to a component OWNED BY ANOTHER ACTOR -- the local player's mesh --
-- the hold strips the player every tick and says nothing (it logs once per property NAME, not per
-- owner). So the probe lists, for each ghost, every object-typed property whose value carries a
-- custom-depth flag and whose OUTER is not that ghost: a "CROSS-OWNER" line. None found is a
-- result too, and then the hunt widens (the game's own SetRenderCustomDepth calls, the afterimage
-- guard's proximity attribution, render-state drift).
--
-- WHAT ONE RUN DOES, fixed phases, a countdown, no window to hit (standing user preference):
--   every 500 ms for 90 s, the clock starting when the player pawn first exists (a launch is
--   not a window to hit either) --
--   1. FLAGS: for the PLAYER and every GHOST, `VisualMesh` / `WeaponMesh` / `LightMesh`:
--      bRenderCustomDepth, CustomDepthStencilValue, bRenderInMainPass, bVisible, the component's
--      outer. Printed in full once, then ON CHANGE only, with the sample number as a clock.
--   2. CROSS-OWNER: the walk described above, every 10th sample, with coverage counts (how many
--      properties were walked) so "none" and "the walk did nothing" can never be confused.
--   3. AFTERIMAGES: every live BP_AfterImage_C -- copyActor and PoseableMesh's custom depth --
--      on change, so a player image stripped by proximity attribution shows up.
--   Countdown at 60/30/10 s. Stops itself; nothing is left running.
--
-- What it CANNOT see: what is DRAWN. A flag that reads true with a stale render state looks
-- exactly like a healthy one here. If every flag reads healthy while the screen still shows the
-- silhouette, the next instrument is the engine setter itself (call SetRenderCustomDepth(true) on
-- the body and watch the screen), not a finer read of the same fields.
--
-- Grounded APIs, none from memory: UE4SS Lua FindAllOf, IsValid, GetFullName, GetFName, GetOuter,
-- GetClass, GetSuperStruct, UStruct:ForEachProperty, LoopAsync (vendored RE-UE4SS/docs/lua-api,
-- all exercised by probe_namecensus and probe_dustlight on this build). Engine fields:
-- UPrimitiveComponent::bRenderCustomDepth / CustomDepthStencilValue / bRenderInMainPass,
-- USceneComponent::bVisible (docs.unrealengine.com). Every read is pcall-guarded and an absent
-- field prints as "?" rather than vanishing.
--
-- Deploy: over the scratch slot -- copy to <install>\...\ue4ss\Mods\MeshGhostScratch\Scripts\
-- main.lua, then `echo MeshGhostScratch <nonce> > ...\Mods\MeshGhostProbeReloader\reload_request.txt`.
-- Restore the stub from probe_scratch/ afterwards. Dev-only tooling; never ships.

local TAG = "[MeshGhostOutlineProbe]"
local PAWN_CLASS = "BP_PlayerGoatMain_C"
local IMAGE_CLASS = "BP_AfterImage_C"
local MESHES = { "VisualMesh", "WeaponMesh", "LightMesh" }
local FIELDS = { "bRenderCustomDepth", "CustomDepthStencilValue", "bRenderInMainPass", "bVisible" }
local INTERVAL_MS = 500
local DURATION_S = 90
local CROSS_EVERY = 10 -- samples

local samples = 0
local clock_samples = 0   -- counts only once the player pawn exists: the run starts when play does
local last_line = {}      -- key -> last printed line, for on-change printing
local cross_found = 0
local cross_walked = 0
local announced_end = false

local function full_name(obj)
    local n
    pcall(function() n = obj:GetFullName() end)
    return n or "?"
end

local function short(name)
    -- "Class /Game/.../Actor.Comp" -> "Actor.Comp"
    return (tostring(name):gsub("^.*[/%.]([^/%.]+%.[^/%.]+)$", "%1"))
end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end

local function prop(obj, name)
    local v
    local ok = pcall(function() v = obj[name] end)
    if not ok then return nil end
    return v
end

local function is_default(obj)
    return full_name(obj):find("Default__", 1, true) ~= nil
end

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

local function outer_name(obj)
    local outer
    pcall(function() outer = obj:GetOuter() end)
    if outer == nil or not valid(outer) then return "?" end
    return full_name(outer)
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
        parts[#parts + 1] = f:gsub("^b", "") .. "=" .. (v == nil and "?" or tostring(v))
    end
    return table.concat(parts, " ")
end

local function sample_flags(pawns, player)
    for _, pawn in ipairs(pawns) do
        local role = (player and full_name(pawn) == full_name(player)) and "PLAYER" or "GHOST "
        for _, m in ipairs(MESHES) do
            local comp = prop(pawn, m)
            if comp ~= nil and valid(comp) then
                emit(full_name(pawn) .. "/" .. m,
                     string.format("%s %s.%s: %s outer=%s", role, short(full_name(pawn)), m,
                                   flags_line(comp), short(outer_name(comp))))
            else
                emit(full_name(pawn) .. "/" .. m,
                     string.format("%s %s.%s: (absent)", role, short(full_name(pawn)), m))
            end
        end
    end
end

-- The theory test. For each GHOST pawn: every object-typed property on its class chain whose
-- value has a custom-depth flag and whose outer is not the ghost itself.
local function sample_cross_owner(pawns, player)
    local player_name = player and full_name(player) or ""
    for _, pawn in ipairs(pawns) do
        local pawn_name = full_name(pawn)
        if pawn_name ~= player_name then
            local walked, found = 0, 0
            local c = nil
            pcall(function() c = pawn:GetClass() end)
            local depth = 0
            while c and valid(c) and depth < 12 do
                depth = depth + 1
                pcall(function()
                    c:ForEachProperty(function(p)
                        walked = walked + 1
                        pcall(function()
                            if p:GetClass():GetFName():ToString() ~= "ObjectProperty" then return end
                            local pname = p:GetFName():ToString()
                            local v = pawn[pname]
                            if v == nil or not valid(v) then return end
                            local cd = prop(v, "bRenderCustomDepth")
                            if cd == nil then return end
                            local o = outer_name(v)
                            if o ~= pawn_name then
                                found = found + 1
                                local whose = (o == player_name) and "THE PLAYER'S" or "another actor's"
                                emit("cross/" .. pawn_name .. "/" .. pname,
                                     string.format("CROSS-OWNER on %s: property '%s' -> %s (customdepth=%s) owned by %s: %s",
                                                   short(pawn_name), pname, short(full_name(v)), tostring(cd), whose, short(o)))
                            end
                        end)
                    end)
                end)
                local sup = nil
                pcall(function() sup = c:GetSuperStruct() end)
                if sup and sup ~= c and valid(sup) then c = sup else c = nil end
            end
            cross_walked = cross_walked + walked
            cross_found = cross_found + found
            emit("coverage/" .. pawn_name,
                 string.format("coverage %s: %d properties walked over %d class level(s), %d cross-owner value(s)",
                               short(pawn_name), walked, depth, found))
        end
    end
end

local function sample_afterimages(player)
    local images = FindAllOf(IMAGE_CLASS)
    if not images then return end
    local n = 0
    for _, img in pairs(images) do
        if valid(img) and not is_default(img) then
            n = n + 1
            if n <= 24 then
                local copy = prop(img, "copyActor")
                local copy_name = (copy ~= nil and valid(copy)) and short(full_name(copy)) or "nil"
                local pm = prop(img, "PoseableMesh")
                local cd = (pm ~= nil and valid(pm)) and tostring(prop(pm, "bRenderCustomDepth")) or "?"
                local whose = (copy ~= nil and valid(copy) and player and full_name(copy) == full_name(player)) and " (PLAYER'S)" or ""
                emit("img/" .. full_name(img),
                     string.format("afterimage %s: copyActor=%s%s PoseableMesh.customdepth=%s", short(full_name(img)), copy_name, whose, cd))
            end
        end
    end
    emit("img/count", string.format("afterimages alive: %d", n))
end

local function sample()
    samples = samples + 1
    local player = player_pawn()
    local pawns = {}
    for _, p in pairs(FindAllOf(PAWN_CLASS) or {}) do
        if valid(p) and not is_default(p) then pawns[#pawns + 1] = p end
    end
    if samples == 1 then
        print(string.format("%s START: %d pawn(s) of %s, player=%s. Full dump now, then changes only.\n",
                            TAG, #pawns, PAWN_CLASS, player and short(full_name(player)) or "NOT FOUND"))
    end
    sample_flags(pawns, player)
    if samples % CROSS_EVERY == 1 then sample_cross_owner(pawns, player) end
    sample_afterimages(player)

    if player then clock_samples = clock_samples + 1 end
    local left = DURATION_S - (clock_samples * INTERVAL_MS) / 1000
    if left == 60 or left == 30 or left == 10 then
        print(string.format("%s %ds left.\n", TAG, left))
    end
    if left <= 0 and not announced_end then
        announced_end = true
        print(string.format("%s END after %d samples: %d cross-owner value(s) over %d properties walked. Stopped; nothing left running.\n",
                            TAG, samples, cross_found, cross_walked))
    end
end

LoopAsync(INTERVAL_MS, function()
    if announced_end then return true end
    local ok, err = pcall(sample)
    if not ok then print(string.format("%s sample error: %s\n", TAG, tostring(err))) end
    return false
end)

print(string.format("%s loaded: %d s at %d ms, read-only.\n", TAG, DURATION_S, INTERVAL_MS))
