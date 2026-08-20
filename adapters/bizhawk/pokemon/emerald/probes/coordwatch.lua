-- MeshGhost -- who moves whom at a seam crossing (DEV TOOL, never shipped)
--
-- THE QUESTION. When the player crosses a map CONNECTION, the coordinate frame changes. The
-- adapter now rebases its own bookkeeping by the seam delta -- but whether the ENGINE also
-- rebases the coordinates of live object events (our spawned ghosts among them) decides whether
-- that bookkeeping matches the world or fights it. Ghosts vanish at crossings; this says why.
--
-- One line whenever the player's map or any active object's tile changes: the map key, the
-- player's save-block coords, and every active object's currentCoords. Read across one crossing,
-- the answer is in whether the objects' numbers jump by the map height when the map key flips.
local GSAVEBLOCK1PTR_ADDR = 0x03005d8c
local GOBJECTEVENTS_ADDR = 0x02037350
local OBJECTEVENT_SIZE = 0x24

local BSLASH = string.char(92)
local logPath = ("%s/coordwatch.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."))
local logFile = io.open(logPath, "w")
local function say(s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

local last = nil
local n = 0
local function tick()
    n = n + 1
    local sb1 = memory.read_u32_le(GSAVEBLOCK1PTR_ADDR)
    if sb1 == 0 then return end
    local key = memory.read_u8(sb1 + 0x04) .. ":" .. memory.read_u8(sb1 + 0x05)
    local px, py = memory.read_s16_le(sb1 + 0x00), memory.read_s16_le(sb1 + 0x02)
    local objs = {}
    for i = 0, 15 do
        local a = GOBJECTEVENTS_ADDR + i * OBJECTEVENT_SIZE
        if (memory.read_u8(a) % 2) == 1 then
            objs[#objs + 1] = string.format("%d@(%d,%d)g%d", i,
                memory.read_s16_le(a + 0x10) - 7, memory.read_s16_le(a + 0x12) - 7,
                memory.read_u8(a + 0x05))
        end
    end
    local s = string.format("map=%s player=(%d,%d) objs: %s", key, px, py, table.concat(objs, " "))
    if s ~= last then
        last = s
        say(string.format("f=%d %s", n, s))
    end
end

if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
