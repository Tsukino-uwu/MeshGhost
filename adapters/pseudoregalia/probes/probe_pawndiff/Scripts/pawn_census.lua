-- MeshGhost PAWN CENSUS + FUNCTION DUMP (2026-09-09): READ-ONLY, hot-loaded over the scratch
-- slot. Two questions from the driven-ghost session, both answered without a filter:
--
--  1. WHAT IS THE SECOND GHOST. The user sees two ghosts with one clip in `active/`. Every 5 s,
--     every pawn of the player's class: name, controller class, `bActorIsBeingDestroyed`,
--     `bHidden`, moveState, MovementMode, `Interaction Target`, location -- the driven ghost, the
--     player, and whatever else is standing (or sitting) in the world. Named reads only.
--  2. WHAT ENDS A SIT. Six named candidates were called on the seated driven pawn and none
--     moved `moveState` off 8 (`standup_hunt.lua`, 11:45-11:52). The census that named them was
--     filtered by substring (interact/sit/stand/chair/rest/heal/seat) -- a guess about the answer.
--     Once, this lists EVERY function name on the pawn's class chain, own classes first, to a
--     file beside the mod (`pawnfns-<HHMMSS>.log`), names only -- the safe walk the interact census
--     used. Filter while reading, never before.
--
-- Nothing written, nothing called. Restore the stub afterwards.

local TAG = "[MeshGhostPawnCensus]"

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../pawnfns-" .. os.date("%H%M%S") .. ".log"

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function fname_str(x)
    local s
    pcall(function() s = x:GetFName():ToString() end)
    return s or "?"
end
local function addr_of(x)
    local a
    pcall(function() a = x:GetAddress() end)
    return a
end
local function prop(obj, name)
    local v
    if not obj or not pcall(function() v = obj[name] end) then return nil end
    return v
end
local function plain(value)
    local t = type(value)
    if t == "boolean" or t == "number" or t == "string" or t == "nil" then return tostring(value) end
    if t == "userdata" then
        local got
        if pcall(function() got = value:get() end) and got ~= nil and type(got) ~= "userdata" then return tostring(got) end
        local okv, isvalid = pcall(function() return value:IsValid() end)
        if okv and isvalid == false then return "<unresolved>" end
        return "<obj " .. fname_str(value) .. ">"
    end
    return "<" .. t .. ">"
end
local function log(line) print(TAG .. " " .. line .. "\n") end

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

local function dump_functions(pawn)
    local out = io.open(OUT_PATH, "w")
    if not out then log("could not open " .. OUT_PATH) return end
    local cls = pawn:GetClass()
    local total = 0
    while cls and cls:IsValid() do
        local cname = fname_str(cls)
        local names = {}
        cls:ForEachFunction(function(fn) names[#names + 1] = fname_str(fn) end)
        table.sort(names)
        out:write(string.format("== %s: %d function(s)\n", cname, #names))
        for _, n in ipairs(names) do out:write(n, "\n") end
        total = total + #names
        local sup = nil
        pcall(function() sup = cls:GetSuperStruct() end)
        if sup and sup ~= cls and sup:IsValid() then cls = sup else cls = nil end
    end
    out:close()
    log(string.format("function names dumped: %d to %s", total, OUT_PATH))
end

local function location_text(pawn)
    local ok, v = pcall(function() return pawn:K2_GetActorLocation() end)
    if not ok or v == nil then return "?" end
    local x, y, z
    pcall(function() x, y, z = v.X, v.Y, v.Z end)
    if type(x) ~= "number" then return "?" end
    return string.format("%.0f,%.0f,%.0f", x, y, z)
end

local dumped = false
local ticks = 0
log("loaded -- pawn census every 5 s; one function-name dump of the pawn class chain")

LoopAsync(5000, function()
    ticks = ticks + 1
    local me = player_pawn()
    if not me then return false end
    -- Before the game is entered the controller holds an engine `DefaultPawn` (measured
    -- 11:54:16: the first dump listed DefaultPawn/Pawn/Actor/Object, 172 names, none the
    -- game's). Wait for the game's own pawn class.
    local early_class = "?"
    pcall(function() early_class = me:GetClass():GetFName():ToString() end)
    if not early_class:find("^BP_") then return false end
    if not dumped then
        dumped = true
        local ok, err = pcall(dump_functions, me)
        if not ok then log("dump error: " .. tostring(err)) end
    end
    local my_class = "?"
    pcall(function() my_class = me:GetClass():GetFName():ToString() end)
    local my_addr = addr_of(me)
    local count = 0
    for _, p in pairs(FindAllOf(my_class) or {}) do
        if valid(p) then
            count = count + 1
            local ctl = prop(p, "Controller")
            local cn = "<none>"
            if ctl ~= nil and valid(ctl) then pcall(function() cn = ctl:GetClass():GetFName():ToString() end) end
            local target = prop(p, "Interaction Target")
            local tname = (target ~= nil and valid(target)) and fname_str(target) or "none"
            local mv = prop(p, "CharacterMovement")
            local mm = mv and plain(prop(mv, "MovementMode")) or "?"
            log(string.format("t=%ds %s%s ctl=%s destroying=%s hidden=%s moveState=%s MovementMode=%s target=%s at %s",
                ticks * 5, fname_str(p), (addr_of(p) == my_addr) and " (PLAYER)" or "", cn,
                plain(prop(p, "bActorIsBeingDestroyed")), plain(prop(p, "bHidden")),
                plain(prop(p, "moveState")), mm, tname, location_text(p)))
        end
    end
    log(string.format("t=%ds %d pawn(s) of %s", ticks * 5, count, my_class))
    return false
end)
