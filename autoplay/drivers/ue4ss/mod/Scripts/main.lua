-- autoplay UE4SS bootstrap (DEV TOOL, never shipped; agent_docs/phases/autoplay/pseudoregalia.md)
--
-- The only file copied into a game: <install>\...\ue4ss\Mods\MeshGhostAutoplay\Scripts\main.lua, with an
-- enabled.txt beside Scripts\ and a meshghost-autoplay.txt naming `repo=<this repo's root>` and `port=<the core's>`
-- (and `game=`, default pseudoregalia). It loads the driver from the repo itself, so an edit there is live on the
-- next RestartMod (probe_reloader's trigger) with nothing to copy. No config file, nothing loads: a game started
-- without one runs as it would without this folder.

local src = debug.getinfo(1, "S").source
local scripts = src:match("^@(.*)[/\\][^/\\]*$") or "."
local modDir = scripts:gsub("[/\\]Scripts$", "")

local cfg = {}
local fh = io.open(modDir .. "\\meshghost-autoplay.txt", "r")
if not fh then
	print("[MeshGhostAutoplay] no meshghost-autoplay.txt beside the mod: not connecting\n")
	return
end
for line in fh:lines() do
	local k, v = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
	if k then cfg[k] = v end
end
fh:close()
if not cfg.repo or cfg.repo == "" then
	print("[MeshGhostAutoplay] meshghost-autoplay.txt names no repo: not connecting\n")
	return
end

AUTOPLAY = {
	repo = cfg.repo:gsub("\\", "/"):gsub("/$", ""),
	port = tonumber(cfg.port or "") or 7874,
	game = cfg.game or "pseudoregalia",
	mod_dir = modDir,
}
local ok, err = pcall(dofile, AUTOPLAY.repo .. "/autoplay/drivers/ue4ss/driver.lua")
if not ok then
	print("[MeshGhostAutoplay] driver failed to load: " .. tostring(err) .. "\n")
end
