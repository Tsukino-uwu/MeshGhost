-- MeshGhost ENEMY HIT WATCH (written 2026-09-18): READ-ONLY. Part B step 1 of
-- agent_docs/chaser-planning.md, asked the way the plan actually asked it: let a REAL enemy hit the
-- player and watch what moves, instead of calling things and hoping.
--
-- WHY THIS EXISTS. The calling test ran first and came back a clean NEGATIVE (2026-09-18,
-- damage_sweep.lua): `BPI_PerformDamageResponse(DamageType, attackDirection)` called on the
-- PLAYER's own pawn moved no HP at any damage type tried, at +0/100/500/1000/2500 ms -- matching
-- what the shipped hurt mirror's tripwire has been saying about ghosts since 2026-08-27. So that
-- interface is the REACTION and not the damage, and whatever deducts HP has not been named yet.
-- Two independent facts also came out of that run and are recorded here because the next instrument
-- needs them: `attackDirection` is an **FVector** (the Lua table form is accepted), and UE4SS Lua
-- demands the EXACT arity -- the C++ helper only gets away with setting DamageType because it hands
-- ProcessEvent a fully zeroed parameter buffer.
--
-- WHAT IT WATCHES, at SAMPLE_MS on the local player's pawn, both health locations every sample
-- because which one is authoritative is the open question (the docs disagree; both read 80.0 at
-- rest, measured 2026-09-18):
--   * the GameInstance's `CurrentHp` through `As MV Game Instance Ref`;
--   * the pawn's own `BP_HpHitable` component's `CurrentHp` / `maxHP`;
--   * `LastHitBy` as an address only (established as staying null through a hurt -- if it ever is
--     NOT null, that is a finding, so it is watched rather than assumed).
--
-- HOW IT REPORTS -- a window, never a bare event. It keeps the last RING_SAMPLES samples in memory
-- and, on ANY change to either health value, dumps that whole window plus everything for
-- TAIL_MS afterwards. So the frames either side of a hit are readable, which is what makes an
-- ORDERING claim possible at all: if one location moves a sample before the other, that names the
-- authority and the mirror. If they always move in the same sample, say so and stop claiming
-- ordering -- SAMPLE_MS is the resolution limit and this file states it rather than implying more.
--
-- I-FRAMES come out of the same data for free: stand in an enemy and the gaps between consecutive
-- drops ARE the window, measured rather than guessed. The summary prints them at the end.
--
-- WHAT IT CANNOT SEE: which FUNCTION moved the value. It watches fields, so it can say "the
-- component moved first, by 5, and the GameInstance followed" and cannot say what called what.
-- Naming the function is the NEXT instrument (a dump of `BP_HpHitable_C`'s own functions), and it
-- is worth doing only once this run says which location to chase.
--
-- HOW TO RUN: load it, then go and let an ordinary enemy touch you two or three times. Endurance,
-- not timing -- there is no window to hit, it runs for TOTAL_S and logs only when something moves.
-- Read-only: no calls, no writes, no save. Restore probe_scratch's stub afterwards.

local TAG = "[MeshGhostEnemyHit]"
local SAMPLE_MS = 25            -- 40Hz: fine enough to separate two writes a frame apart at 144fps
local TOTAL_S = 300
local RING_SAMPLES = 40         -- 1s of history dumped ahead of every change
local TAIL_MS = 2000            -- and this much after it

local function scriptDir()
    local src = debug.getinfo(1, "S").source
    if src:sub(1, 1) == "@" then src = src:sub(2) end
    return src:match("^(.*[\\/])") or "./"
end
local OUT_PATH = scriptDir() .. "../enemyhit-" .. os.date("%H%M%S") .. ".log"
local out = io.open(OUT_PATH, "a")
local function log(line) print(TAG .. " " .. line .. "\n") end
local function fout(line) if out then out:write(line, "\n"); out:flush() end end
local function say(line) log(line); fout(line) end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function num(obj, name)
    local v
    local ok = pcall(function() v = obj[name] end)
    if not ok or v == nil then return nil end
    if type(v) == "userdata" then
        local got
        if pcall(function() got = v:get() end) and type(got) == "number" then return got end
        return nil
    end
    if type(v) == "number" then return v end
    return nil
end
local function addr_str(x)
    if x == nil then return "nil" end
    local a
    pcall(function() a = x:GetAddress() end)
    if a == nil then return "<no address>" end
    if a == "0x0" or a == 0 then return "null" end
    return tostring(a)
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

-- Both locations, read through the game's own refs every sample. Never cached between samples: a
-- transition makes an entirely new pawn, and a stale ref is how a reading outlives its subject.
local function sample(pawn)
    local gi_hp, own_hp, max_hp
    local gi
    pcall(function() gi = pawn["As MV Game Instance Ref"] end)
    if gi ~= nil and valid(gi) then gi_hp = num(gi, "CurrentHp") end
    local ref
    pcall(function() ref = pawn.BP_HpHitable end)
    if ref ~= nil and valid(ref) then
        own_hp = num(ref, "CurrentHp")
        max_hp = num(ref, "maxHP")
    end
    local lhb
    pcall(function() lhb = pawn.LastHitBy end)
    return {
        t = os.clock(),
        stamp = os.date("%H:%M:%S") .. string.format(".%03d", math.floor((os.clock() * 1000) % 1000)),
        gi = gi_hp, own = own_hp, max = max_hp, lhb = addr_str(lhb),
    }
end

local function line_of(s, mark)
    return string.format("%s %s gi=%s own=%s/%s lastHitBy=%s",
        s.stamp, mark or "   ", tostring(s.gi), tostring(s.own), tostring(s.max), s.lhb)
end

local ring = {}
local ring_at = 0
local t_start = os.clock()
local tail_until = nil
local prev = nil
local drops = {}                -- clock of every gi/own decrease, for the i-frame summary
local coverage_said = false

say("loaded " .. os.date("%H:%M:%S") .. " -- READ-ONLY. Go and let an enemy touch you a few times.")
say("sampling every " .. SAMPLE_MS .. "ms for " .. TOTAL_S .. "s; logs only when a health value moves. " .. OUT_PATH)

-- **HEARTBEAT, added 2026-09-18 after this probe's first run went silent mid-session and nobody
-- could tell whether it had died or the hits had simply stopped costing HP.** A watcher that logs
-- only on change cannot distinguish "nothing happened" from "I am dead" -- the exact trap
-- `checklists/before-trusting-a-reading.md` files twice. A counter that stops is readable; silence
-- is not.
local HEARTBEAT_MS = 5000
local last_beat = 0
local samples = 0

local function tick()
    if os.clock() - t_start > TOTAL_S then
        if #drops >= 2 then
            local gaps = {}
            for i = 2, #drops do gaps[#gaps + 1] = string.format("%.0fms", (drops[i] - drops[i - 1]) * 1000) end
            say("SUMMARY: " .. #drops .. " drop(s); gaps between consecutive drops: " .. table.concat(gaps, ", "))
            say("SUMMARY: the SMALLEST gap is the upper bound on the i-frame window -- a real window is at or below it.")
        else
            say("SUMMARY: " .. #drops .. " drop(s) seen -- not enough to say anything about i-frames.")
        end
        say("done. Restore probe_scratch's stub.")
        if out then out:close(); out = nil end
        return true
    end

    local me = player_pawn()
    if me == nil then return false end
    local s = sample(me)

    if not coverage_said then
        coverage_said = true
        say("COVERAGE: baseline " .. line_of(s, "base"))
        if s.gi == nil then say("COVERAGE: the GameInstance CurrentHp did NOT resolve -- treat every gi= below as blind, not as zero.") end
        if s.own == nil then say("COVERAGE: the pawn's own BP_HpHitable did NOT resolve -- treat every own= below as blind, not as zero.") end
    end

    ring_at = ring_at + 1
    ring[(ring_at % RING_SAMPLES) + 1] = s

    local changed = prev ~= nil and (s.gi ~= prev.gi or s.own ~= prev.own or s.max ~= prev.max)
    if changed then
        -- Which location moved THIS sample is the whole point, so say it explicitly rather than
        -- leaving it to be eyeballed out of two columns.
        local moved = {}
        if s.gi ~= prev.gi then moved[#moved + 1] = string.format("GI %s->%s", tostring(prev.gi), tostring(s.gi)) end
        if s.own ~= prev.own then moved[#moved + 1] = string.format("OWN %s->%s", tostring(prev.own), tostring(s.own)) end
        if s.max ~= prev.max then moved[#moved + 1] = string.format("MAX %s->%s", tostring(prev.max), tostring(s.max)) end
        say("CHANGE " .. s.stamp .. ": " .. table.concat(moved, " | ")
            .. ((#moved > 1) and "  <-- both in ONE sample: no ordering claim at this resolution" or "  <-- ONE location only this sample"))

        if (prev.gi and s.gi and s.gi < prev.gi) or (prev.own and s.own and s.own < prev.own) then
            drops[#drops + 1] = s.t
        end

        if tail_until == nil then
            fout("---- window before the change ----")
            for i = 1, RING_SAMPLES do
                local e = ring[((ring_at + i) % RING_SAMPLES) + 1]
                if e ~= nil and e ~= s then fout(line_of(e)) end
            end
            fout("---- the change ----")
        end
        fout(line_of(s, ">>>"))
        tail_until = os.clock() + (TAIL_MS / 1000)
    elseif tail_until ~= nil then
        fout(line_of(s))
        if os.clock() > tail_until then
            fout("---- end of window ----")
            tail_until = nil
        end
    end

    samples = samples + 1
    if os.clock() - last_beat >= (HEARTBEAT_MS / 1000) then
        last_beat = os.clock()
        log(string.format("alive: %d samples, %s", samples, line_of(s, "now")))
    end

    prev = s
    return false
end

-- A Lua error raised straight out of a LoopAsync body stops the loop with no line anywhere, which
-- is the other half of the silence problem above. Catch it, say it ONCE, and keep sampling.
local loop_error_said = false
LoopAsync(SAMPLE_MS, function()
    local ok, res = pcall(tick)
    if not ok then
        if not loop_error_said then
            loop_error_said = true
            say("LOOP ERROR (reported once, sampling continues): " .. tostring(res))
        end
        return false
    end
    return res
end)
