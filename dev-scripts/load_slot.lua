-- Load one savestate slot, once, then go quiet. DEV TOOL.
--
-- Exists so a two-client rig can be put into a known position without asking anyone to press a
-- key. Deliberately loaded BEFORE the adapter rather than beside it: UNVERIFIED.md records a
-- savestate load killing the adapter (2026-08-26), and this rig has no need to find out whether
-- that is still true -- load the state first, attach the adapter afterwards.
--
-- Slot comes from MESHGHOST_LOAD_SLOT, or from the global MESHGHOST_LOAD_SLOT set by a script
-- loaded ahead of this one -- the dev loader shares one Lua environment, and the environment
-- variable is fixed at emulator launch, so the global is the only way to change slot without a
-- relaunch.
local SLOT = tonumber(MESHGHOST_LOAD_SLOT or os.getenv("MESHGHOST_LOAD_SLOT") or "") or 0
local n, done = 0, false
MESHGHOST_DEV_TICK = function()
	n = n + 1
	if done or SLOT == 0 then return end
	if n == 30 then
		local ok = pcall(savestate.loadslot, SLOT)
		done = true
		-- Report the slot AND whether it took; a load that silently did nothing leaves the rig in
		-- the wrong place and looks identical to one that worked.
		pcall(function() console.log("load_slot: slot " .. SLOT .. (ok and " loaded" or " FAILED")) end)
	end
end
