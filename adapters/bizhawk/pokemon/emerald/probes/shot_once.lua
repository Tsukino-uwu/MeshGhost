-- MeshGhost -- one screenshot, then nothing (DEV TOOL, never shipped).
-- client.screenshot() writes the emulator's video output: BG layers and engine-drawn sprites, and
-- never the Lua-overlay drawn tier (agent_docs/playing.md, "Screenshots").
-- Resolve this script's own directory instead of hardcoding one developer's
-- checkout. A tracked absolute path is unusable on anyone else's machine and is
-- the class of leak .githooks/pre-commit now refuses (pitfalls.md).
local MESHGHOST_DIR = (function()
	local info = debug.getinfo(1, "S")
	if info and info.source and info.source:sub(1, 1) == "@" then
		return info.source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
	end
	return "."
end)()

local shot, n = false, 0
local function tick()
    n = n + 1
    if shot or n < 20 then return end
    shot = true
    local p = MESHGHOST_DIR .. "/../../../../../dev-scripts/shots/emerald/look-" .. os.date("%H%M%S") .. ".png"
    client.screenshot(p)
    console.log("shot_once: wrote " .. p)
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
