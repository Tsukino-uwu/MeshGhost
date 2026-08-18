-- MeshGhost — DEV: drive "use the Super Rod on water", screenshotting every step.
--
-- Menu route, from the screenshots of the first attempt: Start opens a menu whose FIRST entry is
-- BAG (the earlier run pressed Down twice and landed on SAVE, which is how we know). Then the bag
-- opens on ITEMS and KEY ITEMS is the last pocket, and the rod is the third key item because the
-- test kit added Mach Bike, Acro Bike, Super Rod in that order.
--
-- Fishing is a PROCESS with branches (probes.md), so this only drives the SETUP -- getting the rod
-- in hand and cast. What happens after is what we are watching for, not something to script.
local STEPS = {
    -- PREAMBLE: reach a neutral overworld state before assuming anything. A previous run of this
    -- very script left the bag open, and the run after it pressed Start into a menu -- so this is
    -- not hypothetical tidiness. B backs out one level and does nothing in the overworld; ending
    -- on B matters because Start would re-open the menu we just closed.
    { wait = 120, press = "B",     shot = "00a-neutral" },
    { wait = 20,  press = "B",     shot = "00b-neutral" },
    { wait = 20,  press = "B",     shot = "00c-neutral" },
    { wait = 20,  press = "B",     shot = "00d-neutral" },
    { wait = 300, press = nil,     shot = "01-start" },   -- water placed by watertile.lua by now
    { wait = 45,  press = "Start", shot = "02-menu" },
    -- The menu REMEMBERS its cursor between openings: the first attempt pressed A expecting BAG
    -- and got EXIT, because an earlier run had left the cursor at the bottom. Never assume a
    -- menu's starting position -- drive it to a known end (here, the top) and count from there.
    { wait = 25,  press = "Up",    shot = "02a-up" },
    { wait = 20,  press = "Up",    shot = "02b-up" },
    { wait = 20,  press = "Up",    shot = "02c-up" },
    { wait = 20,  press = "Up",    shot = "02d-top" },
    { wait = 45,  press = "A",     shot = "03-bag" },
    { wait = 60,  press = "Right", shot = "04-pocket2" },
    { wait = 45,  press = "Right", shot = "05-pocket3" },
    { wait = 45,  press = "Right", shot = "06-pocket4" },
    { wait = 45,  press = "Right", shot = "07-keyitems" },
    { wait = 45,  press = "Down",  shot = "08-down" },
    { wait = 45,  press = "Down",  shot = "09-onrod" },
    { wait = 45,  press = "A",     shot = "10-submenu" },
    { wait = 60,  press = "A",     shot = "11-used" },
    { wait = 150, press = nil,     shot = "12-after" },
    -- Escape whatever depth of menu we are in, rather than assuming the USE landed. B is Cancel
    -- everywhere in this UI, so pressing it more times than the menu is deep is always safe and
    -- always ends in the overworld. Leaving the game in a menu changes the meaning of every input
    -- that follows and hands the user back a controller that does not do what they expect.
    { wait = 30,  press = "B",     shot = "13-back1" },
    { wait = 30,  press = "B",     shot = "14-back2" },
    { wait = 30,  press = "B",     shot = "15-back3" },
    { wait = 30,  press = "B",     shot = "16-overworld" },
}
local i, frames, held = 1, 0, 0
MESHGHOST_DEV_TICK = function()
    if i > #STEPS then return end
    frames = frames + 1
    local step = STEPS[i]
    if frames < step.wait then return end
    if step.press and held < 5 then
        pcall(function() joypad.set({ [step.press] = true }) end)
        held = held + 1
        return
    end
    if held < 14 then held = held + 1 return end -- release, and let the UI settle
    pcall(function()
        client.screenshot("C:/dev/MeshGhost/dev-scripts/step-" .. step.shot .. ".png")
    end)
    console.log("MeshGhost: step " .. step.shot)
    i, frames, held = i + 1, 0, 0
end
