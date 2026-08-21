-- MeshGhost — Pokémon Emerald: WHICH OBJ tiles change, tick to tick (PROBE, never shipped)
--
-- WHY. Something writes into the spawned ghost's OBJ tiles mid-frame at the start of surfing
-- (write-watch: BIOS CpuSet/LZ77 PCs, data not in ROM => decompressed/RAM source), and the
-- per-address write-watch only covers the addresses it was pointed at. This inverts the
-- question: snapshot ALL of OBJ VRAM every tick and report which tiles changed. The engine's
-- own legitimate copies show up too -- the point is the FOOTPRINT, read alongside which ranges
-- the adapter and the engine actually own. A region that changes while nobody owns it is the
-- stomp, and the allocator can be taught to avoid it permanently.
--
-- COST. 32KB read + compare per tick, in Lua. Diagnosis-only; loaded for one capture, dropped.

local BASE, SIZE = 0x06010000, 0x8000
local BS = string.char(92)
local dir = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BS .. "][^/" .. BS .. "]*$") or ".")
local fh = io.open(dir .. "/vramdiff_" .. os.date("%Y%m%d_%H%M%S") .. ".log", "w")
local prev = nil
local lines = 0

local function tick()
    local cur = memory.read_bytes_as_array(BASE, SIZE)
    if prev and lines < 300 then
        local changed = {}
        local runStart = nil
        for t = 0, 1023 do
            local diff = false
            local o = t * 32
            for k = 1, 32, 4 do
                if cur[o + k] ~= prev[o + k] then diff = true break end
            end
            if diff and not runStart then runStart = t
            elseif not diff and runStart then
                changed[#changed + 1] = runStart .. "-" .. (t - 1)
                runStart = nil
            end
        end
        if runStart then changed[#changed + 1] = runStart .. "-1023" end
        if #changed > 0 then
            lines = lines + 1
            fh:write(string.format("f=%d changed tiles: %s" .. string.char(10),
                emu.framecount(), table.concat(changed, " ")))
            if lines % 20 == 0 then fh:flush() end
        end
    end
    prev = cur
end

console.log("vramdiff probe: on")
MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function() pcall(function() fh:flush() fh:close() end) end
