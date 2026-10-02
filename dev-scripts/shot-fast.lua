-- Settings for bizhawk-screenshot-loop.lua (list it before the loop): a shot every other frame, since a facing
-- transition's middle frames last three. A screenshot is the emulator's video, so a painted (gui.*) ghost is not in it.
-- The pattern needs a literal backslash in its class: a shell heredoc eats it and the file stops parsing.
local here = debug.getinfo(1, "S").source:sub(2):match("^(.*)[/\\][^/\\]*$") or "."
MESHGHOST_SHOT_INTERVAL = 2
MESHGHOST_SHOT_PREFIX = "flip"
MESHGHOST_SHOT_DIR = here .. "/shots/flip"
