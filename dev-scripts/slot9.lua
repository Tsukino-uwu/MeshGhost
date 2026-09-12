-- Set the savestate slot for load_slot.lua, which reads it as a global. DEV TOOL.
--
-- Slot 9 is the user's MACH bike position (given 2026-09-13), so a gait comparison starts from the
-- same mounted state every run rather than from wherever the last one finished. List it BEFORE
-- load_slot.lua, and load_slot.lua before the adapter -- a savestate load was recorded killing the
-- adapter on 2026-08-26, which is why the order is not a preference.
--
-- Slot 1 is the user's own and is never written or loaded by tooling.
MESHGHOST_LOAD_SLOT = 9
