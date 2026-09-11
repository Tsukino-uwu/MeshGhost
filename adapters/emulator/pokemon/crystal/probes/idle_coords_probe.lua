-- MeshGhost — Crystal: where is the player standing RIGHT NOW? (PROBE, never shipped)
--
-- READ-ONLY. Writes nothing, presses nothing, draws nothing. It exists because the two
-- instruments that could already answer this both cost more than the question is worth:
-- `ap_coord_probe.lua` WALKS the player to find coordinates differentially (the right tool for an
-- unknown build, the wrong one when the player must stay idle), and the adapter itself does not
-- print a status line the way Emerald's does.
--
-- WHY IT PRINTS BOTH CANDIDATES RATHER THAN PICKING ONE.
-- The adapter carries two vanilla layouts one byte apart -- wYCoord/wXCoord at 0xDCB7/0xDCB8 and
-- at 0xDCB8/0xDCB9 -- because V1.0 and V1.1 differ by exactly that shift. Choosing here would be
-- guessing which build is loaded; printing both, beside the map id, lets a human pick on evidence.
-- A probe that returns one number cannot be sanity-checked, which is the whole lesson behind this.
--
-- WHAT IT CANNOT SEE: whether the value it read is the coordinate the ENGINE is using this frame
-- (a warp in progress rewrites these), and nothing about sub-tile pixel offset. It samples for a
-- fixed window and reports the RANGE each address covered, so a value that is drifting shows as a
-- range rather than as a confident single number.

local SAMPLES = 120 -- 2s at 60fps; long enough that a flickering address cannot look stable

local CANDIDATES = {
    { name = "layout A (0xDCB7/0xDCB8)", y = 0xDCB7, x = 0xDCB8 },
    { name = "layout B (0xDCB8/0xDCB9)", y = 0xDCB8, x = 0xDCB9 },
}
local MAPGROUP, MAPNUMBER = 0xDCB5, 0xDCB6 -- vanilla layout A's pair; printed, never trusted alone

-- LOGS TO A FILE as well as the console. `console.log` is a GUI append that nothing outside the
-- emulator can read, and an instrument whose output only a human can see cannot be checked.
-- Resolve this script's own directory rather than naming one: an absolute path here would be a
-- machine-specific path in a public repo, which the pre-commit hook refuses (and was right to).
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
    end
end

MESHGHOST_DEV_UNLOAD = function()
    -- Stated rather than assumed: this probe owns no global the game or the adapter can see, and
    -- it wrote no memory, so there is nothing to undo. A probe global outliving its probe is the
    -- standing trap this line exists to answer.
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
