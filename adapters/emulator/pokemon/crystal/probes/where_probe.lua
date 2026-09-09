-- where_probe.lua -- WHERE IS THIS WINDOW'S PLAYER, on any of the five recognised builds.
--
-- Question (2026-09-09, the five-build rig): five clients on one map do not all see each other.
-- The adapter culls a peer more than GHOST_RANGE_TILES (8) from the player, silently, and the
-- logs carry no player position -- so nothing recorded says whether a missing ghost was out of
-- range or genuinely lost. This prints the one line that settles it, once a second, per window:
-- map group/number and the player's map tile, read straight off WRAM with the same per-build
-- addresses the adapter uses (vanilla V1.0/V1.1, Speedchoice v8.1 at +1, Archipelago's measured
-- block). Read-only: no writes, no input, nothing spawned. Attach it beside the adapter by adding
-- its path as a second line of the window's dev-loader target file.
--
-- It reports its own coverage: the build it decided on and the raw header bytes it decided from,
-- so a wrong table shows up as a wrong label rather than a plausible number.

local ROM, WRAM = "ROM", "WRAM"
local function r(addr, dom) local ok, v = pcall(memory.read_u8, addr, dom); return ok and v or nil end
local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end

local t = {}
for i = 0, 9 do t[#t + 1] = string.char(r(0x134 + i, ROM) or 0) end
local title = table.concat(t)
local ver, ck1, ck2 = r(0x14C, ROM) or 0, r(0x14E, ROM) or 0, r(0x14F, ROM) or 0
local build, A
if title:sub(1, 3) == "AP_" then
	build = string.format("archipelago (V1.%d base)", ver)
	A = { group = 0x1CBC, number = 0x1CBD, structs = 0x14DC, status = 0x1439, battle = 0x1234 }
elseif title == "PM_CRYSTAL" and ver == 6 then
	build = "speedchoice"
	A = { group = flat(0xDCB6), number = flat(0xDCB7), structs = flat(0xD4D6), status = flat(0xD432), battle = flat(0xD22D) }
else
	build = string.format("vanilla (ver %d, checksum %02X%02X)", ver, ck1, ck2)
	A = { group = flat(0xDCB5), number = flat(0xDCB6), structs = flat(0xD4D6), status = flat(0xD432), battle = flat(0xD22D) }
end
-- wPlayerStandingMapX/Y sit 0x10/0x11 into the player's object struct on every build
-- (crystal-speedchoice.sym and pokecrystal11.sym agree; the AP table's struct is at 0x14DC).
local F_X, F_Y = 0x10, 0x11

-- Named by bridge port rather than checksum: two Archipelago seeds share one checksum and wrote
-- into the same file on 2026-09-09. The port is unique per window on the dev rig.
local logfile = io.open(string.format("%s/where_%s_%s.log",
	(io.popen("cd"):read("*l") or "."), os.date("%Y%m%d_%H%M%S"),
	os.getenv("MESHGHOST_BRIDGE_PORT") or string.format("%02X%02X", r(0x14E, ROM) or 0, r(0x14F, ROM) or 0)), "a")
local function log(s)
	console.log(s)
	if logfile then logfile:write(os.date("%H:%M:%S "), s, "\n"); logfile:flush() end
end
log(string.format("where_probe: title %q ver %d checksum %02X%02X -> %s; group@%04X number@%04X structs@%04X",
	title, ver, ck1, ck2, build, A.group, A.number, A.structs))

local frames, last = 0, nil
local function tick()
	frames = frames + 1
	if frames % 60 ~= 0 then return end
	local g, n = r(A.group, WRAM), r(A.number, WRAM)
	local x, y = r(A.structs + F_X, WRAM), r(A.structs + F_Y, WRAM)
	local st, bt = r(A.status, WRAM), r(A.battle, WRAM)
	local line = string.format("%s map %s/%s player tile %s,%s mapstatus %s battle %s", build, tostring(g), tostring(n), tostring(x), tostring(y), tostring(st), tostring(bt))
	if line ~= last or frames % 600 == 0 then log(line); last = line end
end

MESHGHOST_DEV_TICK = tick
MESHGHOST_DEV_UNLOAD = function() log("where_probe: unloaded"); if logfile then logfile:close() end end
if not MESHGHOST_DEV_LOADER then
	while true do
		tick()
		emu.frameadvance()
	end
end
