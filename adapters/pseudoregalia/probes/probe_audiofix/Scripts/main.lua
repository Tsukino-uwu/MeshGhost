-- Audio-listener fix probe, and it writes: when a new ghost appears, points the PlayerController's attenuation
-- listener back at the local player's capsule, which the ghost's BeginPlay took. Never leave it armed: the DLL now
-- applies the same fix. Deploy as ue4ss\Mods\MeshGhostAudioFix with an enabled.txt; reload via probe_reloader.

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

-- The controller names the player's pawn: a ghost reads as possessed too.
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

-- The game itself passes the CollisionCylinder, so the root's name is checked and a mismatch logged, never written.
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
                    -- A new ghost's BeginPlay has just taken the listener.
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

-- A probe that throws goes silent, which reads like a game doing nothing: report the first failure once.
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

-- Once at load too: a session that already lost its listener recovers, and the first line says whether the call works.
ExecuteInGameThread(function() repoint("probe loaded") end)

print(string.format("%s loaded -- WRITES: puts the audio attenuation listener back on the player's capsule whenever a ghost appears.\n", TAG))
