-- Loads the adapter pinned to bridge port 7779, for a second emulator on this machine: the adapter reads this global
-- before the environment, and a running emulator cannot be given a new environment variable. Either ROM can be in
-- either emulator; each picks its own address table from the ROM header.

MESHGHOST_BRIDGE_PORT = 7779

local dir = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
dofile(dir .. "/../meshghost_crystal.lua")
