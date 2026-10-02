-- Pokémon Crystal: reports the adapter's MG_CRY_SPANS counter as spans painted per frame. Reads no game memory.
-- A tier that silently stops painting gets faster, so a frame-rate change is trusted only while this rate holds:
-- note it, make the change, reload and compare. It says nothing about where the pixels land.

local WINDOW = 300 -- frames, matching Emerald's profiler window

local SCRIPT_DIR = (function()
    local info = debug.getinfo(1, "S")
    if info and info.source and info.source:sub(1, 1) == "@" then
        -- Either separator may arrive; the backslash is doubled inside a Lua string.
        return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
    end
    return "."
end)()

local LOG = SCRIPT_DIR .. "/paintcount_probe.log"

local frames, last = 0, 0

local function say(line)
    console.log(line)
    local f = io.open(LOG, "a")
    if f then
        f:write(line, "\n")
        f:close()
    end
end

local function tick()
    frames = frames + 1
    if frames >= WINDOW then
        local now = MG_CRY_SPANS or 0
        say(string.format("CRYSTAL PAINT: %.0f spans/frame over %d frames (total %d)",
            (now - last) / frames, frames, now))
        last, frames = now, 0
    end
end

MESHGHOST_DEV_UNLOAD = function()
    -- Owns no game state and wrote nothing; stated rather than assumed.
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
else
    while true do tick() emu.frameadvance() end
end
