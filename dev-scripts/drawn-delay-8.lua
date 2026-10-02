-- Restores the Emerald drawn tier's old 8-frame trailing delay (list it before the adapter, which latches it at load)
-- for a tier comparison only: a spawned ghost trails by up to a step, since the engine cannot begin one mid-tile.
MESHGHOST_EMERALD_DRAWN_DELAY_FRAMES = 8
console.log("MeshGhost: drawn trailing delay = 8 frames (drawn-delay-8.lua) -- the old tier-comparison value")
