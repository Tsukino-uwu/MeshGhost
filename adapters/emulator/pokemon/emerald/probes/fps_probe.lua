-- MeshGhost -- is the EMULATOR keeping 60fps? (PROBE, never shipped)
--
-- WHY. os.clock inside the adapter measures the Lua process's own CPU, which said 0.44ms/frame
-- while the user still reported lag. That is not a contradiction: a Lua overlay's gui.* calls and
-- the emulator's own frame pacing are not in that number. client.get_approx_framerate() is, so it
-- is the instrument for the claim "the script makes it laggy" -- and unlike an impression it can
-- be compared before and after a flag is switched off.
local n, lo = 0, 999
local function tick()
    n = n + 1
    local f = client.get_approx_framerate and client.get_approx_framerate() or -1
    if f > 0 and f < lo then lo = f end
    if n % 120 == 0 then
        console.log(string.format("fps: now=%.1f lowest-seen=%.1f", f, lo))
        lo = 999
    end
end
if MESHGHOST_DEV_LOADER then MESHGHOST_DEV_TICK = tick
else while true do tick() emu.frameadvance() end end
