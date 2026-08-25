-- MeshGhost -- what the ENGINE does with a wheelie, frame by frame (DEV TOOL, never shipped)
--
-- WHY. A ghost given one of the Acro Bike's wheelie actions (0x64..0x73) never reports finished:
-- the watchdog in `ghostIsIdle` freed it at the 60-frame limit over and over, on 0x69, 0x6B and
-- 0x6D. So those poses are not mirrored at all, and a peer's standing wheelie is invisible
-- (agent_docs/unverified.md, 2026-08-20). The standing theory is that the pose depends on state the
-- engine keeps on the PLAYER and a ghost has none of -- which is a guess, and this project's one
-- rule that kept paying is to measure the engine before changing anything.
--
-- THE QUESTION. Does the PLAYER'S OWN object event ever set heldMovementFinished while it is in a
-- wheelie? Two outcomes, and they point at completely different fixes:
--   * it DOES finish  -> the action is completable and something about the ghost differs; the diff
--                        between the two objects' bytes during the pose is then the whole answer.
--   * it NEVER finishes -> the pose is a HOLD the engine ends from outside, and a ghost's release
--                        is ours to issue. Waiting on `finished` would be the bug, not the pose.
--
-- HOW. Drive it: B is the wheelie on the Acro Bike, held. Fixed phases with a countdown, nothing to
-- time by hand. Then log the player's ObjectEvent and its sprite every frame, plus the first 16
-- bytes of gPlayerAvatar -- DUMPED, not read at a guessed offset, so the acro state can be located
-- by watching which byte moves rather than by trusting +0x08.
local GPLAYERAVATAR_ADDR = 0x02037590
local GOBJECTEVENTS_ADDR = 0x02037350
local GSPRITES_ADDR = 0x02020630
local OBJECTEVENT_SIZE = 0x24
local SPRITE_SIZE = 0x44
local GMAIN_CALLBACK2_ADDR = 0x030022c4
local CB2_OVERWORLD_ADDR = 0x08085e5c

local function r8(a) return memory.read_u8(a) end
local function rs16(a) return memory.read_s16_le(a) end

-- A lone backslash inside a Lua pattern is an escape sequence, so the separator class is built
-- rather than written out -- a scripted edit lost one and the load failed on the pattern itself.
local BSLASH = string.char(92)
local logPath = ("%s/wheelie_watch_%s.log"):format(
    (debug.getinfo(1, "S").source:sub(2):match("^(.*)[/" .. BSLASH .. "][^/" .. BSLASH .. "]*$") or "."),
    os.date("%Y%m%d_%H%M%S"))
local logFile = io.open(logPath, "a")
local function say(s)
    console.log("wheelie: " .. s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end
local function line(s)
    if logFile then logFile:write(s .. string.char(10)) logFile:flush() end
end

-- HELD, not tapped -- the user, 2026-08-20: *"you need to hold for the jumping"*. A tap gives a
-- pop-wheelie and nothing else, which is how the first Acro capture caught 0x6A and no hop.
local PHASES = {
    -- NO `keys` AT ALL, deliberately: `joypad.set` replaces the whole pad state, so a probe that
    -- writes an empty table every frame silently cancels another probe's press. The first run of
    -- this one did exactly that to `use_acro`'s SELECT and captured a walk instead of a wheelie.
    -- Phase 1 is therefore hands-off, which is also the window `use_acro` needs to mount the bike.
    { name = "stand still (baseline, pad left alone)", frames = 180, keys = nil },
    { name = "hold B -- standing wheelie",    frames = 300, keys = function() return { B = true } end },
    { name = "release -- end the wheelie",    frames = 180, keys = function() return {} end },
    { name = "hold B + Right -- moving wheelie", frames = 300, keys = function() return { B = true, Right = true } end },
    { name = "release -- settle",             frames = 180, keys = function() return {} end },
    -- EVERY DIRECTION, because the ghost hung on 0x69, 0x6B and 0x6D -- the +1 and +3 members of
    -- their families -- and a player facing south only ever produces the +0 ones. "The action never
    -- finishes" and "that DIRECTION's action never finishes" are different claims and the first run
    -- could not tell them apart.
    { name = "face north",                    frames = 40,  keys = function() return { Up = true } end },
    { name = "hold B facing north",           frames = 240, keys = function() return { B = true } end },
    { name = "release",                       frames = 90,  keys = function() return {} end },
    { name = "face east",                     frames = 40,  keys = function() return { Right = true } end },
    { name = "hold B facing east",            frames = 240, keys = function() return { B = true } end },
    { name = "release",                       frames = 90,  keys = function() return {} end },
    { name = "face west",                     frames = 40,  keys = function() return { Left = true } end },
    { name = "hold B facing west",            frames = 240, keys = function() return { B = true } end },
    { name = "release",                       frames = 90,  keys = function() return {} end },
    -- The user, 2026-08-20, naming the three things the bike does: *"up+B while idle on the bike
    -- and not jumping for a sideway jump"*. A direction pressed WITH B from a standstill is its own
    -- move, not the same as pressing B first.
    { name = "Up+B together from a standstill", frames = 180, keys = function() return { Up = true, B = true } end },
    { name = "release",                       frames = 90,  keys = function() return {} end },
}

local n, said, done, lastAct, waited = 0, {}, false, nil, false

local function tick()
    if done then return end
    local cb = memory.read_u32_le(GMAIN_CALLBACK2_ADDR)
    if (cb ~= CB2_OVERWORLD_ADDR and cb ~= CB2_OVERWORLD_ADDR + 1)
        or r8(GPLAYERAVATAR_ADDR + 0x06) ~= 0
    then
        joypad.set({})
        return
    end

    -- DON'T MEASURE A WALK AND CALL IT A WHEELIE. The first run captured 976 frames of ordinary
    -- walking because the bike was never mounted, and nothing in the log said so. The Acro Bike's
    -- graphicsId is 63 for Brendan and 91 for May (verified.md's graphicsId table), so the probe
    -- can see the bike for itself and simply wait for it.
    local pObjId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if pObjId > 15 then return end
    local gfx = r8(GOBJECTEVENTS_ADDR + pObjId * OBJECTEVENT_SIZE + 0x05)
    if gfx ~= 63 and gfx ~= 91 then
        if not waited then waited = true say("waiting for the Acro Bike (graphicsId " .. gfx .. ")") end
        return
    end
    if waited then waited = false say("on the Acro Bike -- starting") end

    n = n + 1
    local t, i = n, 1
    while i <= #PHASES and t > PHASES[i].frames do t = t - PHASES[i].frames i = i + 1 end
    if i > #PHASES then
        joypad.set({})
        done = true
        say("done -- " .. logPath)
        return
    end
    if not said[i] then
        said[i] = true
        say(string.format("phase %d/%d: %s (%d frames)", i, #PHASES, PHASES[i].name, PHASES[i].frames))
        line(string.format("# phase %d %s", i, PHASES[i].name))
    end
    if PHASES[i].keys then joypad.set(PHASES[i].keys(t)) end

    local objId = r8(GPLAYERAVATAR_ADDR + 0x05)
    if objId > 15 then return end
    local o = GOBJECTEVENTS_ADDR + objId * OBJECTEVENT_SIZE
    local s = GSPRITES_ADDR + r8(o + 0x04) * SPRITE_SIZE
    local b0 = r8(o + 0x00)

    local av = {}
    for k = 0, 15 do av[#av + 1] = string.format("%02X", r8(GPLAYERAVATAR_ADDR + k)) end

    -- One line per frame: the action the engine gave itself, whether it calls it active/finished,
    -- where its step function has got to (sprite data[1]/data[2]), and the animation actually on
    -- screen. `finished` going 1 at any point in a wheelie answers the whole question.
    line(string.format(
        "f=%4d ph=%d act=%02X active=%d finished=%d dir=%02X b1=%02X "
        .. "anim=%d/%d ended=%d data1=%d data2=%d pos2=%d,%d avatar=%s",
        n, i, r8(o + 0x1c), (b0 >> 6) & 1, (b0 >> 7) & 1, r8(o + 0x18), r8(o + 0x01),
        r8(s + 0x2a), r8(s + 0x2b), (r8(s + 0x2c) >> 6) & 1,
        rs16(s + 0x30), rs16(s + 0x32), rs16(s + 0x24), rs16(s + 0x26),
        table.concat(av, " ")))

    if lastAct ~= r8(o + 0x1c) then
        lastAct = r8(o + 0x1c)
        -- The whole ObjectEvent on every change of action: cheaper than a second live run when a
        -- byte nobody thought to print turns out to be the one that differs.
        local d = {}
        for k = 0, OBJECTEVENT_SIZE - 1 do d[#d + 1] = string.format("%02X", r8(o + k)) end
        line(string.format("  OBJ act=%02X | %s", lastAct, table.concat(d, " ")))
        say(string.format("action -> 0x%02X (active=%d finished=%d)",
            lastAct, (b0 >> 6) & 1, (b0 >> 7) & 1))
    end
end

if MESHGHOST_DEV_LOADER then
    MESHGHOST_DEV_TICK = tick
    MESHGHOST_DEV_UNLOAD = function() joypad.set({}) say("unloaded, keys released") end
else
    while true do tick() emu.frameadvance() end
end
