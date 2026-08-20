-- MeshGhost -- run left and right, and say what the EMULATOR's frame rate did (DEV TOOL)
--
-- WHY. User, 2026-08-20: *"the game does feel laggy ... while moving around"*, and *"run left/right
-- a bit, and test/check the fps"*. An impression cannot be compared against anything; a number
-- taken the same way twice can, which is the whole point of driving the movement from a script
-- rather than by hand -- both runs then cover the same tiles at the same speed.
--
-- THE INSTRUMENT IS `client.get_approx_framerate`, for the reason `fps_probe.lua` records: os.clock
-- inside the adapter measures the Lua process's own CPU and said 0.44ms/frame while the user still
-- reported lag, because a Lua overlay's gui.* calls and the emulator's own pacing are not in that
-- number. The emulator's own framerate is.
--
-- HOW TO USE IT AS AN A/B. Load it with the adapter, read the summary; then drop the adapter from
-- the loader control file, load this alone, and read the summary again. Same route, same probe,
-- one variable. This probe's own cost is one call and one compare per frame, and it holds no
-- strings between samples -- it must stay that cheap to be usable as the control.
--
-- RUNNING, not walking: holding B is how a player actually crosses a map, it is the case the
-- report is about, and it moves twice as many tiles per second past the ghost logic.
-- BIASED LEFT (user, 2026-08-20: *"go a bit more to the left as well"*): the left legs are longer
-- than the right ones, so the route drifts westward across the map instead of shuttling over the
-- same few tiles. New ground is the point -- frame cost follows what is on screen, and a stretch
-- with more NPCs or more scenery is exactly where a drop would hide.
-- LONGER BOTH WAYS (user, 2026-08-20: *"a longer distance both left/right combined"*). The first
-- version shuttled over the same handful of tiles, and a biased one drifted west without ever
-- coming back -- neither crosses much map. Equal long legs walk a real stretch of route in each
-- direction, which is what the report is about.
local LEG_FRAMES = 240       -- ~4s of running, each way
local LEFT_LEG_FRAMES = 240
local LEGS = 8
local WARMUP = 60            -- the first frames after a reload are not representative

local BSLASH = string.char(92)
local logPath = ("%s/fpsride_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("fpsride: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

local n, leg, held, lo, hi, sum, samples, done = 0, 1, 0, 999, 0, 0, 0, false
local legLo = {}

local function tick()
    if done then return end
    n = n + 1
    if n <= WARMUP then
        joypad.set({})
        return
    end

    local f = client.get_approx_framerate and client.get_approx_framerate() or -1
    if f > 0 then
        if f < lo then lo = f end
        if f > hi then hi = f end
        sum, samples = sum + f, samples + 1
        local cur = legLo[leg] or 999
        if f < cur then legLo[leg] = f end
    end

    -- B is held with the direction: run, do not walk.
    joypad.set({ [(leg % 2 == 1) and "Left" or "Right"] = true, B = true })
    held = held + 1
    if held >= ((leg % 2 == 1) and LEFT_LEG_FRAMES or LEG_FRAMES) then
        say(string.format("leg %d (%s): lowest %.1f fps", leg, (leg % 2 == 1) and "left" or "right",
            legLo[leg] or -1))
        held = 0
        leg = leg + 1
        if leg > LEGS then
            joypad.set({})
            done = true
            say(string.format("DONE -- %d legs, %d samples: lowest %.1f, highest %.1f, average %.1f",
                LEGS, samples, lo, hi, samples > 0 and (sum / samples) or -1))
            say("log: " .. logPath)
        end
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) end
else
    while true do tick() emu.frameadvance() end
end
