-- Turn the bounded cross-map tier trace on for this session. Loaded BEFORE the adapter: the dev
-- loader shares one Lua environment, so a global set here is visible to it.
MESHGHOST_CRYSTAL_XTRACE = true
MESHGHOST_DEV_TICK = function() end
