-- MeshGhost — is the emulator keeping 60fps? (dev tool, read-only, never shipped). client.get_approx_framerate()
-- counts the overlay's gui calls and the frame pacing, which os.clock inside a script does not.
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
