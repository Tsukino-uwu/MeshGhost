-- MeshGhost GHOST STRIP -- switch the parts of a live GHOST on and off, one at a time, to price each.
--
-- WHY (user, 2026-09-06): the census (`probe_leakcount/Scripts/census.lua`) and the dump
-- (`probe_dump/`) listed everything a ghost carries, because it is a clone of the player pawn. The
-- user's ask, in two steps: first *"can we do a test with these disabled? ... no ghost vs 1 ghost
-- ... and afterwards no ghost vs 50?"* for the six parts a ghost has no use for; then *"can you do
-- individual checks for all parts a model has? like spawn ghosts with only that thing and nothing
-- else ... so we can separate and make a proper list of what everything does performance wise"*.
-- A pawn cannot be spawned with one component, but it can be switched to ALL OFF and have one part
-- switched back on -- which is the same measurement. The frame-time sampler reads the cost with the
-- cap lifted; the user judges what each part looks like on screen; nothing here ships.
--
-- PARTS (the name is what a request uses). Each has an OFF and an ON through the engine's own
-- setters or a reflected property write, applied to GHOST pawns only -- never the local player's:
--   springarms   SpringArm, SpringArm1        SetComponentTickEnabled / Deactivate|Activate
--   dialoguecam  DialogueCam                  SetComponentTickEnabled ONLY (Activate on a camera
--                                             aborted the game -- see the part's own comment)
--   charmove     CharMoveComp                 SetComponentTickEnabled
--   niagara      the pawn's NiagaraComponents  Deactivate|Activate, SetHiddenInGame
--   aicontroller the AIController             SetActorTickEnabled; PathFollowing/PawnActions tick
--   animdriver   CharacterMesh0               bPauseAnims + bNoSkeletonUpdate (the animation
--                                             blueprint and IK stop running; the mesh is unseen)
--   visualmesh   VisualMesh                   SetVisibility + SetComponentTickEnabled (the model)
--   weaponmesh   WeaponMesh                   same (the sword)
--   shadow       BlobShadow                   SetVisibility
--   nametag      TextRenderComponents         SetVisibility (ours; attached to the ghost)
--   capsule      CollisionCylinder            SetComponentTickEnabled
--   pawntick     the pawn actor itself        SetActorTickEnabled (the Blueprint's own tick)
--   uro          the three skeletal meshes    bEnableUpdateRateOptimizations = true (ON means the
--                                             engine's far-mesh animation throttle is on; a cost
--                                             LEVER rather than a part, so it starts OFF like the rest)
--
-- HOW A GHOST IS TOLD FROM THE PLAYER. A pawn is a ghost when its Controller's class name contains
-- "AIController" and not "PlayerController" (every ghost here has had one since the auto-possess
-- finding). A pawn being destroyed is skipped: no UFunction is called on a torn-down object (host
-- CLAUDE.md). Components are found by NAME CONTAINMENT (full name starts with the pawn's full name
-- + "."), the attribution test that has never failed here. Everything armed stays armed: a ghost
-- that spawns later gets the same state within a second.
--
-- REQUESTS, beside this mod's Scripts folder, each consumed once:
--   strip_request.txt   off=all | off=<a,b,c> | on=<a,b,c> | on=all | restore | none
--                       (`off=all` then `on=visualmesh` is "a ghost with only the model")
--   ft_request.txt      <label>   frame-time sample (mean / median / p95 / worst over 10s) with
--                                 ghost count and the current OFF set on the line
--   cmd_request.txt     <cmd>     one console command (`t.MaxFPS 0` for the measuring)
--   census_request.txt  <label>   counts only
--
-- This is a WRITING probe (PROBES.md names it as such). Dev-only tooling; never ships. Unload before
-- judging anything it did not touch.

local TAG = "[MeshGhostStrip]"
local TICK_MS = 50
local SCAN_MS = 1000
local FT_SECONDS = 10

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local MOD_ROOT = scriptDir() .. "../"
local LOG_PATH = MOD_ROOT .. "strip.log"
local REQ = {
    strip = MOD_ROOT .. "strip_request.txt",
    ft = MOD_ROOT .. "ft_request.txt",
    cmd = MOD_ROOT .. "cmd_request.txt",
    census = MOD_ROOT .. "census_request.txt",
}
local UEHelpers = require("UEHelpers")

local function out(line)
    print(TAG .. " " .. line .. "\n")
    local f = io.open(LOG_PATH, "a")
    if f then f:write(os.date("%H:%M:%S "), line, "\n"); f:close() end
end

local function consume(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a") or ""
    f:close()
    os.remove(path)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return "unlabelled" end
    return text
end

local function full_name(obj)
    local ok, n = pcall(function() return obj:GetFullName() end)
    if ok and n then return n end
    return nil
end

local function addr_of(obj)
    local ok, a = pcall(function() return obj:GetAddress() end)
    if ok and a then return a end
    return nil
end

local function all_of(class_name)
    local ok, objs = pcall(FindAllOf, class_name)
    if ok and objs then return objs end
    return {}
end

local function call(obj, fn, ...)
    local args = { ... }
    local ok = pcall(function() obj[fn](obj, table.unpack(args)) end)
    return ok
end

local function setprop(obj, name, value)
    local ok = pcall(function() obj[name] = value end)
    return ok
end

---------------------------------------------------------------------------- ghost detection

local function ghost_controller(pawn)
    if pawn == nil or not pawn:IsValid() then return nil end
    local ok, dying = pcall(function() return pawn.bActorIsBeingDestroyed end)
    if not ok or dying == true then return nil end
    local ok2, ctrl = pcall(function() return pawn.Controller end)
    if not ok2 or ctrl == nil or not ctrl:IsValid() then return nil end
    local cname = full_name(ctrl) or ""
    if cname:find("PlayerController", 1, true) then return nil end
    if not cname:find("AIController", 1, true) then return nil end
    return ctrl
end

local function path_of(name) return name:match("^%S+%s+(.*)$") or name end

local function owned_components(owner_name, class_name)
    local found = {}
    local owner_path = path_of(owner_name)
    for _, c in ipairs(all_of(class_name)) do
        local n = full_name(c)
        if n then
            local p = path_of(n)
            if p:sub(1, #owner_path + 1) == owner_path .. "." then
                found[#found + 1] = { obj = c, leaf = p:sub(#owner_path + 2) }
            end
        end
    end
    return found
end

local function ghosts_now()
    local list = {}
    for _, pawn in ipairs(all_of("BP_PlayerGoatMain_C")) do
        local ctrl = ghost_controller(pawn)
        if ctrl ~= nil then list[#list + 1] = { pawn = pawn, ctrl = ctrl } end
    end
    return list
end

---------------------------------------------------------------------------- the parts

-- Each `apply(g, on)` switches the part to ON (its normal state) or OFF on ghost g = {pawn, ctrl,
-- name} and returns a short report string. "uro" is inverted on purpose: its ON state is the
-- engine throttle enabled, which is NOT the normal state -- so `off=all` leaves the throttle off.
local function comp_tick_activate(c, on)
    local a = call(c.obj, "SetComponentTickEnabled", on)
    local b = on and call(c.obj, "Activate", false) or call(c.obj, "Deactivate")
    return string.format("%s[tick=%s,act=%s]", c.leaf, tostring(a), tostring(b))
end

local function comp_visibility_tick(c, on)
    local a = call(c.obj, "SetVisibility", on, false)
    local b = call(c.obj, "SetComponentTickEnabled", on)
    return string.format("%s[vis=%s,tick=%s]", c.leaf, tostring(a), tostring(b))
end

local PARTS = {
    { name = "springarms", apply = function(g, on)
        local r = {}
        for _, c in ipairs(owned_components(g.name, "SpringArmComponent")) do r[#r + 1] = comp_tick_activate(c, on) end
        return table.concat(r, " ")
    end },
    { name = "dialoguecam", apply = function(g, on)
        -- TICK ONLY. `Activate()` on a ghost's camera component aborted the game (2026-09-06
        -- 14:12:32, "Abort signal received", the instant `on=dialoguecam` re-activated it on 50
        -- ghosts after `off=all` had deactivated it; every other part's ON had passed). A camera
        -- that becomes active is a view-target candidate, and this game's camera code and our
        -- SetViewTarget guard both act on that -- so a camera is never activated from here.
        local r = {}
        for _, c in ipairs(owned_components(g.name, "CameraComponent")) do
            if c.leaf == "DialogueCam" then
                r[#r + 1] = string.format("%s[tick=%s]", c.leaf, tostring(call(c.obj, "SetComponentTickEnabled", on)))
            end
        end
        return table.concat(r, " ")
    end },
    { name = "charmove", apply = function(g, on)
        local r = {}
        for _, c in ipairs(owned_components(g.name, "CharacterMovementComponent")) do
            r[#r + 1] = string.format("%s[tick=%s]", c.leaf, tostring(call(c.obj, "SetComponentTickEnabled", on)))
        end
        return table.concat(r, " ")
    end },
    { name = "niagara", apply = function(g, on)
        local r = {}
        for _, c in ipairs(owned_components(g.name, "NiagaraComponent")) do
            local a = on and call(c.obj, "Activate", false) or call(c.obj, "Deactivate")
            local b = call(c.obj, "SetHiddenInGame", not on, false)
            r[#r + 1] = string.format("%s[act=%s,hidden=%s]", c.leaf, tostring(a), tostring(b))
        end
        return table.concat(r, " ")
    end },
    { name = "aicontroller", apply = function(g, on)
        local r = { "AIController[tick=" .. tostring(call(g.ctrl, "SetActorTickEnabled", on)) .. "]" }
        local cname = full_name(g.ctrl)
        if cname then
            for _, cls in ipairs({ "PathFollowingComponent", "PawnActionsComponent" }) do
                for _, c in ipairs(owned_components(cname, cls)) do
                    r[#r + 1] = string.format("AI.%s[tick=%s]", c.leaf, tostring(call(c.obj, "SetComponentTickEnabled", on)))
                end
            end
        end
        return table.concat(r, " ")
    end },
    { name = "animdriver", apply = function(g, on)
        local r = {}
        for _, c in ipairs(owned_components(g.name, "SkeletalMeshComponent")) do
            if c.leaf == "CharacterMesh0" then
                local a = setprop(c.obj, "bPauseAnims", not on)
                local b = setprop(c.obj, "bNoSkeletonUpdate", not on)
                r[#r + 1] = string.format("%s[pause=%s,noskel=%s]", c.leaf, tostring(a), tostring(b))
            end
        end
        return table.concat(r, " ")
    end },
    { name = "visualmesh", apply = function(g, on)
        local r = {}
        for _, c in ipairs(owned_components(g.name, "SkeletalMeshComponent")) do
            if c.leaf == "VisualMesh" then r[#r + 1] = comp_visibility_tick(c, on) end
        end
        return table.concat(r, " ")
    end },
    { name = "weaponmesh", apply = function(g, on)
        local r = {}
        for _, c in ipairs(owned_components(g.name, "SkeletalMeshComponent")) do
            if c.leaf == "WeaponMesh" then r[#r + 1] = comp_visibility_tick(c, on) end
        end
        return table.concat(r, " ")
    end },
    { name = "shadow", apply = function(g, on)
        local r = {}
        for _, c in ipairs(owned_components(g.name, "StaticMeshComponent")) do
            if c.leaf == "BlobShadow" then
                r[#r + 1] = string.format("%s[vis=%s]", c.leaf, tostring(call(c.obj, "SetVisibility", on, false)))
            end
        end
        return table.concat(r, " ")
    end },
    { name = "nametag", apply = function(g, on)
        local r = {}
        for _, c in ipairs(owned_components(g.name, "TextRenderComponent")) do
            r[#r + 1] = string.format("%s[vis=%s]", c.leaf, tostring(call(c.obj, "SetVisibility", on, false)))
        end
        return table.concat(r, " ")
    end },
    { name = "capsule", apply = function(g, on)
        local r = {}
        for _, c in ipairs(owned_components(g.name, "CapsuleComponent")) do
            r[#r + 1] = string.format("%s[tick=%s]", c.leaf, tostring(call(c.obj, "SetComponentTickEnabled", on)))
        end
        return table.concat(r, " ")
    end },
    { name = "pawntick", apply = function(g, on)
        return "pawn[tick=" .. tostring(call(g.pawn, "SetActorTickEnabled", on)) .. "]"
    end },
    { name = "uro", apply = function(g, on)
        -- inverted lever: ON = throttle enabled
        local r = {}
        for _, c in ipairs(owned_components(g.name, "SkeletalMeshComponent")) do
            r[#r + 1] = string.format("%s[uro=%s]", c.leaf, tostring(setprop(c.obj, "bEnableUpdateRateOptimizations", on)))
        end
        return table.concat(r, " ")
    end },
}
local PART_BY_NAME = {}
for _, p in ipairs(PARTS) do PART_BY_NAME[p.name] = p end

-- desired[part] = false means OFF is armed (true for "uro" means its throttle is armed ON).
local desired = {}
-- applied[pawn address] = { name=, state = {part -> true/false as applied} }
local applied = {}

local function sync_ghost(g)
    local a = addr_of(g.pawn)
    local rec = applied[a] or { name = g.name, state = {} }
    local report = {}
    for _, p in ipairs(PARTS) do
        local want = desired[p.name]
        if want ~= nil and rec.state[p.name] ~= want then
            report[#report + 1] = p.apply(g, want)
            rec.state[p.name] = want
        end
    end
    applied[a] = rec
    if #report > 0 then
        out(string.format("%s: %s", g.name:match("BP_PlayerGoatMain_C_%d+") or g.name, table.concat(report, " ")))
    end
end

local function scan()
    if next(desired) == nil then return end
    for _, g in ipairs(ghosts_now()) do
        g.name = full_name(g.pawn)
        if g.name then sync_ghost(g) end
    end
end

local function off_list()
    local l = {}
    for _, p in ipairs(PARTS) do
        if p.name == "uro" then
            if desired.uro == true then l[#l + 1] = "uro:ON" end
        elseif desired[p.name] == false then
            l[#l + 1] = p.name
        end
    end
    return #l > 0 and table.concat(l, ",") or "none"
end

local function parse_parts(text)
    local names = {}
    if text == "all" then
        for _, p in ipairs(PARTS) do if p.name ~= "uro" then names[#names + 1] = p.name end end
        return names
    end
    for n in text:gmatch("[^,%s]+") do
        if PART_BY_NAME[n] then names[#names + 1] = n else out("unknown part '" .. n .. "' ignored") end
    end
    return names
end

local function handle_strip(text)
    if text == "restore" then
        for _, p in ipairs(PARTS) do desired[p.name] = (p.name == "uro") and false or true end
        scan()
        desired = {}
        applied = {}
        out("restore: every touched ghost back to normal; nothing armed")
        return
    end
    if text == "none" then
        desired = {}
        out("disarmed: new ghosts are left alone; touched ones stay as they are (use restore)")
        return
    end
    local verb, rest = text:match("^(%a+)%s*=%s*(.*)$")
    if verb ~= "off" and verb ~= "on" then
        out("bad request '" .. text .. "' -- want off=<parts>|on=<parts>|restore|none")
        return
    end
    for _, n in ipairs(parse_parts(rest)) do
        desired[n] = (verb == "on")
    end
    scan()
    out(string.format("armed: OFF=%s -- applied to every ghost now and to each new one", off_list()))
end

---------------------------------------------------------------------------- counts, frame time, console

local function counts_line()
    return string.format("ghosts=%d OFF=%s", #ghosts_now(), off_list())
end

local ft = nil
local function ft_sample()
    if ft == nil then return end
    local ok, dt = pcall(function()
        local world = UEHelpers.GetWorld()
        if world == nil or not world:IsValid() then return nil end
        local statics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        if statics == nil or not statics:IsValid() then return nil end
        return statics:GetWorldDeltaSeconds(world)
    end)
    if ok and dt ~= nil and dt > 0 then ft.samples[#ft.samples + 1] = dt * 1000.0 end
    if os.time() >= ft.ends_at then
        local s = ft.samples
        table.sort(s)
        local n = #s
        if n == 0 then
            out(string.format("FRAMETIME '%s': no samples", ft.label))
        else
            local sum = 0
            for _, v in ipairs(s) do sum = sum + v end
            local mean = sum / n
            out(string.format("FRAMETIME '%s': %d samples over %ds -- mean %.2f ms (%.1f fps), median %.2f, p95 %.2f, worst %.2f | %s",
                ft.label, n, FT_SECONDS, mean, 1000.0 / mean, s[math.max(1, math.floor(n * 0.5))],
                s[math.max(1, math.floor(n * 0.95))], s[n], counts_line()))
        end
        ft = nil
    end
end

local function run_console(cmd)
    local ok, err = pcall(function()
        UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(UEHelpers.GetWorld(), cmd, nil)
    end)
    out(string.format("CONSOLE '%s': %s", cmd, ok and "sent" or ("FAILED " .. tostring(err))))
end

---------------------------------------------------------------------------- one loop

local since_scan = 0
LoopAsync(TICK_MS, function()
    if ft ~= nil then
        ExecuteInGameThread(ft_sample)
        return false
    end
    local text = consume(REQ.ft)
    if text then
        ft = { label = text, samples = {}, ends_at = os.time() + FT_SECONDS }
        out(string.format("FRAMETIME '%s': sampling for %ds...", text, FT_SECONDS))
        return false
    end
    text = consume(REQ.cmd)
    if text then ExecuteInGameThread(function() run_console(text) end); return false end
    text = consume(REQ.census)
    if text then
        ExecuteInGameThread(function() out(string.format("COUNTS '%s': %s", text, counts_line())) end)
        return false
    end
    text = consume(REQ.strip)
    if text then
        ExecuteInGameThread(function()
            local ok, err = pcall(handle_strip, text)
            if not ok then out("strip FAILED: " .. tostring(err)) end
        end)
        return false
    end
    since_scan = since_scan + TICK_MS
    if since_scan >= SCAN_MS then
        since_scan = 0
        ExecuteInGameThread(function()
            local ok, err = pcall(scan)
            if not ok then out("scan FAILED: " .. tostring(err)) end
        end)
    end
    return false
end)

out("strip probe v2 loaded -- strip_request.txt: off=all | off=<parts> | on=<parts> | restore | none; parts: springarms,dialoguecam,charmove,niagara,aicontroller,animdriver,visualmesh,weaponmesh,shadow,nametag,capsule,pawntick,uro; nothing armed")
