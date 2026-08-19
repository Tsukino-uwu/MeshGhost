-- MeshGhost -- one screenshot, then nothing (DEV TOOL, never shipped).
-- client.screenshot() writes the emulator's video output, so it carries the BG layers and the
-- ENGINE-drawn sprites -- including a spawned ghost and the player's own reflection -- and never
-- the drawn tier, which is a Lua overlay (playing.md, "Screenshots"). That is exactly what is
-- wanted here: the engine's own treatment of a reflection at a shoreline, as the reference to
-- measure ours against.
local shot = false
local n = 0
local function tick()
    n = n + 1
    if shot or n < 30 then return end
    shot = true
    local path = "C:/dev/MeshGhost/dev-scripts/shots/emerald/reflection-edge-"
        .. os.date("%H%M%S") .. ".png"
    client.screenshot(path)
    console.log("shot_once: wrote " .. path)
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
