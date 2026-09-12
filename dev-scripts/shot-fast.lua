-- Settings for bizhawk-screenshot-loop.lua: a shot every OTHER frame, into its own folder.
-- DEV TOOL, list it BEFORE the loop in the control file.
--
-- Two frames because the thing being caught lives in three: a facing transition's middle frames.
-- One sample cannot see a blinking thing (adapters/_template/probes.md), and at the loop's default
-- 120 frames it would take one picture per twenty transitions.
--
-- THE FOLDER IS RESOLVED FROM THIS SCRIPT, never written out: a machine path in a public repo stays
-- in every clone and fork, and .githooks/pre-commit refuses the commit -- as it did for the first
-- version of this file.
--
-- AND REMEMBER WHAT A SCREENSHOT CANNOT SEE: `client.screenshot` captures the emulator's video
-- output, so a PAINTED ghost -- a gui.* overlay -- is not in it (probes.md, "A screenshot does not
-- contain your overlay"). These shots answer questions about the GAME; the adapter's own counters
-- answer questions about the overlay.
--
-- The pattern below needs a LITERAL backslash in its character class. Written with the editor
-- rather than through a shell heredoc, which ate one and left `[/\]` -- a file that does not parse,
-- caught by preflight's `luac -p` sweep and by nothing else (2026-09-13).
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
MESHGHOST_SHOT_INTERVAL = 2
MESHGHOST_SHOT_PREFIX = "flip"
MESHGHOST_SHOT_DIR = here .. "/shots/flip"
