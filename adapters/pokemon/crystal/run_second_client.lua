-- MeshGhost — Crystal: load the adapter as the SECOND client on this machine.
--
-- WHY THIS EXISTS
-- Two emulators on one machine need two cores, and two cores need two bridge ports. The port is
-- normally an environment variable — which is no help at all when the second emulator is already
-- open, because a running process cannot be given a new one. Asking someone to close and reopen an
-- emulator to change a port number is exactly the kind of friction that stops a test happening.
--
-- So: this sets the values as globals and then loads the real adapter, which reads a global in
-- preference to the environment. Nothing is duplicated — meshghost_crystal.lua stays the one
-- implementation, and this file is four lines of configuration.
--
-- HOW TO RUN
--   FIRST emulator:  open meshghost_crystal.lua      (bridge 7778)
--   SECOND emulator: open THIS file                  (bridge 7779)
--   Either ROM can be in either — vanilla and Archipelago each pick their own address table from
--   the ROM header, so the pairing does not matter and mixing them is a genuine test.

MESHGHOST_BRIDGE_PORT = 7779

-- The offset now defaults to 0 in the adapter itself, so this needs to set nothing: it exists only
-- for a loopback session, where a ghost echoing your own position would otherwise stand inside you.
local dir = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\]") or "."
dofile(dir .. "/meshghost_crystal.lua")
