-- MeshGhost — Pokémon Emerald: which OBJ tiles change, tick to tick (dev tool, read-only, never shipped).
-- Snapshots all of OBJ VRAM every tick and logs the runs of changed tiles (the first 300 lines), for when a write-watch
-- covers only the addresses it was pointed at. Heavy: 32KB read and compared per tick, so load it for one capture.

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
