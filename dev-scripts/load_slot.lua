-- Loads one savestate slot once, then goes quiet, so a rig reaches a known position with no keypress. Load it before
-- the adapter: a savestate load has killed the adapter. The slot is the MESHGHOST_LOAD_SLOT global, set by a script
-- loaded ahead of this one, or else the environment variable, which is fixed at emulator launch.
local SLOT = tonumber(MESHGHOST_LOAD_SLOT or os.getenv("MESHGHOST_LOAD_SLOT") or "") or 0
local n, done = 0, false
MESHGHOST_DEV_TICK = function()
	n = n + 1
	if done or SLOT == 0 then return end
	if n == 30 then
		local ok = pcall(savestate.loadslot, SLOT)
		done = true
		-- Whether it took: a load that did nothing looks identical to one that worked.
		pcall(function() console.log("load_slot: slot " .. SLOT .. (ok and " loaded" or " FAILED")) end)
	end
end
