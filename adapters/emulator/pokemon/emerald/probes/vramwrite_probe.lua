-- MeshGhost — Pokémon Emerald: WHO writes the ghost's OBJ tiles mid-frame (PROBE, never shipped)
--
-- WHY
-- The spawned ghost renders scrambled for ~one frame at the start of surfing, and every per-tick
-- instrument reads clean: the sprite struct, the hardware OAM, the tile bitmap and OBJ VRAM are
-- all correct at every frame BOUNDARY. So the corruption exists only BETWEEN ticks -- somebody
-- writes the ghost's tiles mid-frame and somebody else repairs them before the next tick. A
-- boundary probe cannot see that; a WRITE BREAKPOINT can, and it also names the writer: the
-- callback records the CPU's PC, and the .sym file turns a PC into a function name.
--
-- The ghost's post-swap range is deterministic in the replay (tiles 84.., measured three runs in
-- a row), so the addresses are fixed rather than chased.
--
-- COST. An execute/write breakpoint can push the emulator core onto a slow per-instruction path
-- (FLAGS.md, the fish-hook measurement) -- this is a diagnosis-only probe, loaded for one capture
-- and dropped, never left on.
--
-- HOW TO RUN: in the loader set before the adapter, during a scripted surf start. Writes
-- probes/vramwrite_<stamp>.log.

local BASE = 0x06010000 + 192 * 32          -- tile 84
local SPAN = 16 * 32                       -- the whole 16-tile frame

local BS = string.char(92)
local dir = (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BS .. "][^/" .. BS .. "]*$") or ".")
local fh = io.open(dir .. "/vramwrite_" .. os.date("%Y%m%d_%H%M%S") .. ".log", "w")
local n = 0

local function onWrite(addr, val, flags)
    if n >= 1500 then return end -- a budget: the interesting window is a handful of frames
    n = n + 1
    -- PC landed in the BIOS (0x2A0 -- the CpuSet loop), which names the MECHANISM, not the
    -- CALLER. The caller is in the link register: the BIOS returns through R14, which still
    -- holds the game-code address just after the SWI that started the copy.
    local pc, lr = 0, 0
    pcall(function() pc = emu.getregister("R15") end)
    pcall(function() lr = emu.getregister("R14") end)
    fh:write(string.format("f=%d addr=%08X val=%04X pc=%08X lr=%08X" .. string.char(10),
        emu.framecount(), addr or 0, val or 0, pc or 0, lr or 0))
    if n % 40 == 0 then fh:flush() end
end

local ok, err = pcall(function()
    -- One registration covering the range, if this build supports a length; else per-address.
    local ok2 = pcall(event.onmemorywrite, onWrite, BASE, "meshghost_vramwatch")
    if not ok2 then error("onmemorywrite refused") end
    -- Sample the rest of the range at one address per tile, so a big copy is still caught.
    for t = 1, 15 do
        pcall(event.onmemorywrite, onWrite, BASE + t * 32, "meshghost_vramwatch_" .. t)
    end
end)
console.log("vramwrite probe: " .. tostring(ok) .. " " .. tostring(err) .. " -> " .. dir)

MESHGHOST_DEV_TICK = function() end
MESHGHOST_DEV_UNLOAD = function()
    pcall(function() fh:flush() fh:close() end)
end
