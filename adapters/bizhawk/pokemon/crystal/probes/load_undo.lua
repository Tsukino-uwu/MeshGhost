-- MeshGhost — Pokémon Crystal: load the goto undo (slot 8). Dev tool, one action, then quiet.
local done = false
MESHGHOST_DEV_TICK = function()
	if done then return end
	done = true
	local ok = pcall(savestate.loadslot, 8)
	console.log(ok and "MeshGhost dev: loaded slot 8 (the goto undo)"
		or "MeshGhost dev: could not load slot 8")
end
