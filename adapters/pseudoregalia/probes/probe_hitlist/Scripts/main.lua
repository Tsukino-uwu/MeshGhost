-- MeshGhost HIT LIST WATCH (written 2026-09-15, NOT YET RUN): READ-ONLY. The instrument for the
-- three ghost-attack leaks the user still sees with GHOST_PREHIT_PLAYER on -- Sunsetter hurts,
-- Strikebreak hurts, ghost attacks move levers -- and for the first question of the chaser contact
-- plan (agent_docs/chaser-planning.md, Part A step 1 and Part B step 1): WHICH actor's already-hit
-- list records a victim, and WHERE the health that moves actually lives.
--
-- WHAT IT READS, every PERIOD_MS for TOTAL_S, on the player's pawn and on every OTHER pawn of the
-- player's class (the ghosts):
--   * `hitActorsArray` in full -- each element's address and object name (the elements are actors
--     the game itself holds live while they are in its list; the name read is guarded);
--   * `LastHitBy` as an address only (never dereferenced: it was `<none>` through every hurt the
--     C++ measured, and a stale pointee is exactly what crashes a probe);
--   * the pawn's `BP_HpHitable` ref (address) and, when the ref is the pawn's OWN component, its
--     `CurrentHp` / `maxHP`;
--   * the game instance's `CurrentHp` through `As MV Game Instance Ref` (a singleton the game owns).
-- One line per pawn per sample goes to `hitlist-<HHMMSS>.log` beside this mod, unfiltered. The
-- UE4SS.log gets a line ONLY when something CHANGED -- an array grew or shrank on any pawn, a
-- health value moved anywhere -- with the pawn, the before and the after, so the window around
-- a hit is readable without the file. Nothing is filtered before the file (probes.md, "Dump
-- everything"), and the change lines are the reading aid, not the record.
--
-- WHAT IT CANNOT SEE, said up front: an attack that queries from a SPAWNED actor (a projectile,
-- a hitbox actor) and records its victims THERE would show as "no pawn's array changed, and the
-- health moved anyway". That outcome is itself the answer to Part A's hypothesis -- and the next
-- instrument is then a class census at the moment of the hit (probe_leakcount's census), not a
-- deeper read of the pawns. A lever's own state is not read here either; the user's eyes are the
-- instrument for "the lever moved".
--
-- HOW TO RUN: a loopback ghost 2 tiles to the side (never on the player). Load over the scratch
-- slot (PROBES.md, probe_scratch), then have the ghost's player use Sunsetter next to the local
-- player, then Strikebreak, then swing at a lever, holding each for a slow count of five before
-- the next -- endurance, not timing. Restore the stub afterwards.
--
-- COST: FindAllOf("PlayerController") plus one FindAllOf of the pawn class per sample, a few
-- dozen named reads per pawn, no calls, no writes, no dereference of anything but the pawn's own
-- component and the game's singleton. Dev-only; never ships.

local TAG = "[MeshGhostHitList]"
local PERIOD_MS = 250
local TOTAL_S = 180
local ARRAY_MAX = 64

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../hitlist-" .. os.date("%H%M%S") .. ".log"
local out = io.open(OUT_PATH, "a")
local function log(line) print(TAG .. " " .. line .. "\n") end
local function fout(line) if out then out:write(line, "\n") end end

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
local function addr_str(x)
    if x == nil then return "nil" end
    local a = addr_of(x)
    if a == nil then return "<no address>" end
    if a == "0x0" or a == 0 then return "null" end
    return tostring(a)
end
local function num(obj, name)
    local v
    local ok = pcall(function() v = obj[name] end)
    if not ok or v == nil then return "?" end
    if type(v) == "userdata" then
        local got
        if pcall(function() got = v:get() end) and type(got) == "number" then return got end
        return "?"
    end
    if type(v) == "number" then return v end
    return "?"
end

local function player_pawn()
    local pcs = FindAllOf("PlayerController")
    if not pcs then return nil end
    for _, pc in pairs(pcs) do
        if valid(pc) then
            for _, field in ipairs({ "AcknowledgedPawn", "Pawn" }) do
                local pawn
                pcall(function() pawn = pc[field] end)
                if pawn ~= nil and valid(pawn) then return pawn end
            end
        end
    end
    return nil
end

-- The already-hit list, as "addr:name" per element, joined. The elements are actors the game
-- keeps in its own list; the name read is pcall-guarded and an element the walk cannot read is
-- written as its address alone.
local function hit_list(pawn)
    local list
    local ok = pcall(function() list = pawn.hitActorsArray end)
    if not ok or list == nil then return "<unread>", -1 end
    local ok2, n = pcall(function() return list:GetArrayNum() end)
    if not ok2 or type(n) ~= "number" then return "<unread>", -1 end
    local items = {}
    for i = 1, math.min(n, ARRAY_MAX) do
        local ok3, x = pcall(function() return list[i] end)
        if ok3 and x ~= nil then
            local name = valid(x) and fname_str(x) or "<invalid>"
            items[#items + 1] = addr_str(x) .. ":" .. name
        else
            items[#items + 1] = "<unread>"
        end
    end
    return "[" .. table.concat(items, " ") .. "]", n
end

-- The pawn's health component: the ref's address, whether it is the pawn's OWN (outer == pawn),
-- and its numbers only when it is.
local function hitable(pawn)
    local ref
    pcall(function() ref = pawn.BP_HpHitable end)
    if ref == nil or not valid(ref) then return addr_str(ref), "-", "-", "-" end
    local own = "shared"
    pcall(function()
        local outer = ref:GetOuter()
        if outer ~= nil and addr_of(outer) == addr_of(pawn) then own = "own" end
    end)
    if own ~= "own" then return addr_str(ref), own, "-", "-" end
    return addr_str(ref), own, num(ref, "CurrentHp"), num(ref, "maxHP")
end

local function instance_hp(pawn)
    local gi
    pcall(function() gi = pawn["As MV Game Instance Ref"] end)
    if gi == nil or not valid(gi) then return "-", addr_str(gi) end
    return num(gi, "CurrentHp"), addr_str(gi)
end

local prev = {}      -- per pawn address: the last line's parts, for the change lines
local t_start = os.clock()
local samples = 0
local player_class = nil

log("loaded -- " .. TOTAL_S .. " s, every " .. PERIOD_MS .. " ms, full lines to " .. OUT_PATH)
fout("hitlist started " .. os.date("%H:%M:%S"))

LoopAsync(PERIOD_MS, function()
    if os.clock() - t_start > TOTAL_S then
        log("done -- " .. samples .. " samples; " .. OUT_PATH)
        if out then out:close(); out = nil end
        return true
    end
    local me = player_pawn()
    if me == nil then return false end
    if player_class == nil then
        pcall(function() player_class = me:GetClass():GetFName():ToString() end)
        if player_class == nil then return false end
        log("player pawn class " .. player_class .. " at " .. addr_str(me))
    end
    samples = samples + 1
    local stamp = os.date("%H:%M:%S") .. string.format(".%03d", math.floor((os.clock() * 1000) % 1000))
    local all = FindAllOf(player_class) or {}
    local seen = 0
    for _, pawn in pairs(all) do
        if valid(pawn) then
            seen = seen + 1
            local addr = addr_str(pawn)
            local who = (addr == addr_str(me)) and "PLAYER" or "ghost"
            local list, n = hit_list(pawn)
            local href, own, hp, maxhp = hitable(pawn)
            local gihp, giaddr = instance_hp(pawn)
            local lhb
            pcall(function() lhb = pawn.LastHitBy end)
            local line = string.format("%s %s %s hits=%d %s lastHitBy=%s hitable=%s(%s) hp=%s/%s giHp=%s gi=%s",
                stamp, who, addr, n, list, addr_str(lhb), href, own, tostring(hp), tostring(maxhp), tostring(gihp), giaddr)
            fout(line)
            local key = addr
            local p = prev[key]
            local now = { n = n, list = list, hp = tostring(hp), gihp = tostring(gihp) }
            if p ~= nil and (p.n ~= now.n or p.list ~= now.list or p.hp ~= now.hp or p.gihp ~= now.gihp) then
                log(string.format("CHANGE %s %s: hits %d -> %d %s | own hp %s -> %s | instance hp %s -> %s",
                    who, addr, p.n, now.n, now.list, p.hp, now.hp, p.gihp, now.gihp))
            end
            prev[key] = now
        end
    end
    if samples % 40 == 1 then
        log(string.format("sample %d: %d pawn(s) of %s; watching", samples, seen, player_class))
    end
    return false
end)
