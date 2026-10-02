-- autoplay's UE4SS bootstrap, a dev tool that never ships: the one file copied into the game's
-- ue4ss\Mods\MeshGhostAutoplay\Scripts. It reads meshghost-autoplay.txt beside the mod (repo=, port=, game=) and loads
-- the driver from the repo, so an edit is live on the mod's next restart; with no config file nothing loads.

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
