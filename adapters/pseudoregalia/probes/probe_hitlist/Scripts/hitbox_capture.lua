-- MeshGhost HITBOX CAPTURE (written 2026-09-23): READ-ONLY. Part B of agent_docs/chaser-planning.md.
--
-- WHY THIS EXISTS. Four bare `BPI_*` calls moved no HP (2026-09-18). The class's own bytecode then
-- named the entry points (2026-09-23, the C++ `dump_hphitable.txt` one-shot, UBERGRAPH_ENTRY lines):
-- `BPI_TryDamage(Attacker, HitboxInfo, ForwardVector, QueryLocation)` is its own event (entry 603)
-- and the one path never tried, and `BP_HpHitable` keeps component properties of the same names
-- (`Attacker`, `incomingHitboxInfo`, `Forward Vector`, `Query Location`, `Hit Response`). So after a
-- REAL enemy hit those properties should hold what the game itself passed. This reads them back, so
-- a later call copies the game's own values instead of guessing a struct.
--
-- WHAT IT READS, on the player's own `BP_HpHitable`:
--   * at load: a baseline of every property below -- the resting state a hit is compared against;
--   * every SAMPLE_MS: `CurrentHp`. On a DROP, and again TAIL_READS times after it, every property
--     below with every struct field.
-- Objects are an address, plus the full name ONLY when `IsValid()` accepts it (an object it refuses
-- is address-only -- `checklists/before-a-probe.md`).
--
-- WHAT IT CANNOT SEE: which FUNCTION wrote these properties, or whether a hit that costs 0 HP wrote
-- them (it triggers on an HP drop only). A property that reads the same before and after a hit is
-- either unused by the hit or already held that value -- the baseline makes the difference visible.
--
-- HOW TO RUN: load through the scratch slot, let an ordinary enemy touch you two or three times.
-- Endurance, not timing. No calls, no writes, no save. Restore probe_scratch's stub afterwards.

local TAG = "[MeshGhostHitbox]"
local SAMPLE_MS = 25
local TOTAL_S = 600
local TAIL_READS = { 0, 100, 500 }   -- ms after the drop; the struct may be cleared after the hit

local PROPS = { "Attacker", "incomingHitboxInfo", "Forward Vector", "Query Location", "Hit Response",
                "intangible?", "isGuarding?" }

local function log(line) print(TAG .. " " .. line .. "\n") end

local function valid(obj)
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v == true
end
local function addr_of(x)
    local a
    pcall(function() a = x:GetAddress() end)
    if a == nil then return "<no address>" end
    if a == 0 or a == "0x0" then return "null" end
    if type(a) == "number" then return string.format("0x%X", a) end
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

-- **A WRITTEN LIST, never a walk** (preflight's "blind reflection walks" gate, and
-- `pseudoregalia/CLAUDE.md`: enumerate what you can name, never what an object holds). The first
-- run of this file (2026-09-23) walked the struct once to learn these names; they are now written
-- here, and a name that stops resolving reads `<unread>` instead of being skipped.
local HITBOX_FIELDS = {   -- ST_HitboxData, reflected names as this build spells them
    { "Damage_15_2068E77745C092F1FC7634A91107BEAB", "number" },
    { "HitStopDuration_16_E15EA3AC41362D7EA0AEB3A8064CF3A7", "number" },
    { "HitType_7_A22DD9384A13F44AE32A35B8483C5ED3", "bool" },
    { "HitSound_14_FB67671344A1F2B807571DAC05C7BC60", "object" },
    { "hitboxSocketName_13_3851CA34448DCDDECDDC9DAEE4FD19DE", "name" },
    { "lengthRadiusHalfHeight_12_596D9D47496CF530718FD78AB8AAE1CE", "vector" },
    { "DamageType_19_CC06EAD1426104EDCDC6BB915B624248", "number" },
}
local PROP_KINDS = {
    ["Attacker"] = "object", ["incomingHitboxInfo"] = "hitbox", ["Forward Vector"] = "vector",
    ["Query Location"] = "vector", ["Hit Response"] = "number", ["intangible?"] = "bool", ["isGuarding?"] = "bool",
}

-- One value, described without ever dereferencing an object IsValid refuses.
local describe
describe = function(v, kind)
    if kind == "object" then
        if v == nil then return "nil" end
        local a = addr_of(v)
        if a ~= "null" and valid(v) then
            local n = "?"
            pcall(function() n = v:GetFullName() end)
            return a .. " " .. n
        end
        return a
    elseif kind == "vector" then
        local x, y, z
        pcall(function() x, y, z = v.X, v.Y, v.Z end)
        return string.format("Vector{X=%s Y=%s Z=%s}", tostring(x), tostring(y), tostring(z))
    elseif kind == "hitbox" then
        local parts = {}
        for _, f in ipairs(HITBOX_FIELDS) do
            local x
            local ok = pcall(function() x = v[f[1]] end)
            parts[#parts + 1] = f[1]:match("^(.-)_%d+_") .. "=" .. (ok and describe(x, f[2]) or "<unread>")
        end
        return "ST_HitboxData{ " .. table.concat(parts, ", ") .. " }"
    elseif kind == "name" then
        local s
        if v ~= nil and pcall(function() s = v:ToString() end) and s then return tostring(s) end
        return tostring(v)
    else
        if type(v) == "userdata" then
            local s
            if pcall(function() s = v:get() end) and s ~= nil then return tostring(s) end
            return "<userdata>"
        end
        return tostring(v)
    end
end

local function read_all(hitable, label)
    for _, name in ipairs(PROPS) do
        local v
        local ok = pcall(function() v = hitable[name] end)
        local ok2, text = pcall(describe, v, PROP_KINDS[name])
        log(label .. " " .. name .. " = "
            .. (ok and (ok2 and text or ("<describe failed: " .. tostring(text) .. ">")) or "<unread>"))
    end
end

local function hp_of(hitable)
    local v
    pcall(function() v = hitable.CurrentHp end)
    if type(v) == "number" then return v end
    return nil
end

log("loaded " .. os.date("%H:%M:%S") .. " -- READ-ONLY. Let an ordinary enemy touch you two or three times.")

local t_start = os.clock()
local bound_hitable_addr
local prev_hp
local pending = {}   -- { due = clock, label = string }
local drops = 0
local samples, last_beat = 0, 0

local function tick()
    if os.clock() - t_start > TOTAL_S then
        log("done after " .. TOTAL_S .. "s, " .. drops .. " drop(s). Restore probe_scratch's stub.")
        return true
    end
    local me = player_pawn()
    if me == nil then return false end
    local hitable
    pcall(function() hitable = me.BP_HpHitable end)
    if hitable == nil or not valid(hitable) then return false end

    -- A respawn or transition makes a new pawn and a new component: re-bind, re-baseline.
    local a = addr_of(hitable)
    if a ~= bound_hitable_addr then
        bound_hitable_addr = a
        log("COVERAGE: bound to BP_HpHitable " .. a .. "; CurrentHp=" .. tostring(hp_of(hitable)))
        read_all(hitable, "BASELINE")
        prev_hp = hp_of(hitable)
        pending = {}
        return false
    end

    local hp = hp_of(hitable)
    if prev_hp ~= nil and hp ~= nil and hp < prev_hp then
        drops = drops + 1
        log(string.format("DROP #%d at %s: CurrentHp %s -> %s", drops, os.date("%H:%M:%S"), tostring(prev_hp), tostring(hp)))
        for _, ms in ipairs(TAIL_READS) do
            pending[#pending + 1] = { due = os.clock() + ms / 1000, label = string.format("DROP#%d+%dms", drops, ms) }
        end
    end
    prev_hp = hp

    local keep = {}
    for _, p in ipairs(pending) do
        if os.clock() >= p.due then read_all(hitable, p.label) else keep[#keep + 1] = p end
    end
    pending = keep

    samples = samples + 1
    if os.clock() - last_beat >= 10 then
        last_beat = os.clock()
        log(string.format("alive: %d samples, CurrentHp=%s, drops=%d", samples, tostring(hp), drops))
    end
    return false
end

local loop_error_said = false
LoopAsync(SAMPLE_MS, function()
    local ok, res = pcall(tick)
    if not ok then
        if not loop_error_said then
            loop_error_said = true
            log("LOOP ERROR (reported once, sampling continues): " .. tostring(res))
        end
        return false
    end
    return res
end)
