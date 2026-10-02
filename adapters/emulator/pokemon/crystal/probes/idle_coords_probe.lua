-- Where the player stands right now, read without moving them (ap_coord_probe.lua walks). Read-only. Samples for 2
-- seconds and reports each candidate's range, so a drifting value shows; blind to whether the engine uses it this frame
-- (a warp rewrites it). Ends with the player object's wire position and meshghost-fakeadapter's -dims/-center.

local SAMPLES = 120 -- 2s at 60fps; long enough that a flickering address cannot look stable

-- Vanilla (V1.0, V1.1) and Speedchoice v8.1 keep the pair one byte apart: both are printed beside the map id, so
-- the build is picked on evidence rather than guessed.
local CANDIDATES = {
    { name = "layout A (0xDCB7/0xDCB8)", y = 0xDCB7, x = 0xDCB8 },
    { name = "layout B (0xDCB8/0xDCB9)", y = 0xDCB8, x = 0xDCB9 },
}
local MAPGROUP, MAPNUMBER = 0xDCB5, 0xDCB6 -- vanilla layout A's pair; printed, never trusted alone

-- The wire carries the player object's map coords as {mapX, mapY, mapX*16, mapY*16}, and the painted tier draws
-- from the pixel pair; wXCoord/wYCoord above have a different origin.
local OBJECT_STRUCTS = 0xD4D6
local F_MAP_X, F_MAP_Y = 0x10, 0x11

-- A file as well as the console, which nothing outside the emulator can read; beside this script, never by an
-- absolute path.
local function scriptDir()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end

local LOG = scriptDir() .. "/idle_coords_probe.log"

local function say(line)
    console.log(line)
    local f = io.open(LOG, "a")
    if f then
        f:write(line, "\n")
        f:close()
    end
end

local function u8(addr)
    -- $Cxxx/$Dxxx WRAM is reachable through BizHawk's System Bus on this platform.
    return memory.read_u8(addr, "System Bus") or 0
end

local n = 0
local seen = {}
for i = 1, #CANDIDATES do seen[i] = { xlo = 999, xhi = -1, ylo = 999, yhi = -1 } end

local function tick()
    n = n + 1
    for i, c in ipairs(CANDIDATES) do
        local x, y = u8(c.x), u8(c.y)
        local s = seen[i]
        if x < s.xlo then s.xlo = x end
        if x > s.xhi then s.xhi = x end
        if y < s.ylo then s.ylo = y end
        if y > s.yhi then s.yhi = y end
    end
    if n == SAMPLES then
        say(string.format("IDLE COORDS after %d samples -- map %d/%d",
            n, u8(MAPGROUP), u8(MAPNUMBER)))
        for i, c in ipairs(CANDIDATES) do
            local s = seen[i]
            say(string.format("  %s : x %d..%d   y %d..%d%s",
                c.name, s.xlo, s.xhi, s.ylo, s.yhi,
                (s.xlo == s.xhi and s.ylo == s.yhi) and "  [stable]" or "  [MOVING or wrong]"))
        end
        say("  (a stable pair of plausible tile values is the player; a drifting or "
            .. "out-of-range one is not this build's layout)")
        local mx, my = u8(OBJECT_STRUCTS + F_MAP_X), u8(OBJECT_STRUCTS + F_MAP_Y)
        say(string.format("  PLAYER OBJECT (what the wire carries): mapX=%d mapY=%d "
            .. "-> position = {%d, %d, %d, %d}", mx, my, mx, my, mx * 16, my * 16))
        say(string.format("  fakeadapter: -dims 4 -center \"%d,%d,%d,%d\"",
            mx, my, mx * 16, my * 16))
    end
end

MESHGHOST_DEV_UNLOAD = function()
    -- Nothing to undo: no global the game or the adapter can see, and no memory written.
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
