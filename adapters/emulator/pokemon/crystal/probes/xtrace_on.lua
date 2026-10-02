-- Turns the adapter's bounded cross-map tier trace on. Load it before the adapter: the dev loader shares one Lua
-- environment, so a global set here reaches it.
MESHGHOST_CRYSTAL_XTRACE = true
MESHGHOST_DEV_TICK = function() end
