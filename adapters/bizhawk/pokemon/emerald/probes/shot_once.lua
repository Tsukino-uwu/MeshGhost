-- MeshGhost -- one screenshot, then nothing (DEV TOOL, never shipped).
-- client.screenshot() writes the emulator's video output: BG layers and engine-drawn sprites, and
-- never the Lua-overlay drawn tier (agent_docs/playing.md, "Screenshots").
local shot, n = false, 0
local function tick()
    n = n + 1
    if shot or n < 20 then return end
    shot = true
    local p = "C:/dev/MeshGhost/dev-scripts/shots/emerald/look-" .. os.date("%H%M%S") .. ".png"
    client.screenshot(p)
    console.log("shot_once: wrote " .. p)
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
