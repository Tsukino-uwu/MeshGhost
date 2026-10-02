-- Runs left and right in long equal legs and logs the emulator's frame rate (dev tool), so two runs over the same
-- tiles compare; os.clock in the adapter misses gui.* calls and the emulator's own pacing. For an A/B, read the
-- summary with the adapter loaded, then with this alone. Its own cost is one call and one compare a frame.
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
