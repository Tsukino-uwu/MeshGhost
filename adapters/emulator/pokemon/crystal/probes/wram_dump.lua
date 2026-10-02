-- Hex-dumps one flat WRAM range once, unfiltered, to a log named by bridge port: MESHGHOST_DUMP_FROM / _TO (hex or
-- decimal), by default 0x1880-0x19A0, the player-data bank's badge, TM and bag region on every build.
local DOMAIN = "WRAM"
local FROM = tonumber(os.getenv("MESHGHOST_DUMP_FROM") or "") or 0x1880
local TO = tonumber(os.getenv("MESHGHOST_DUMP_TO") or "") or 0x19A0
local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "noport"
local dir = (io.popen("cd"):read("*l") or ".")
local frames, done = 0, false
local function tick()
	frames = frames + 1
	if done or frames < 60 then return end
	done = true
	local f = io.open(string.format("%s/wram_dump_%s_%s.log", dir, os.date("%Y%m%d_%H%M%S"), port), "w")
	local function out(s) console.log(s); if f then f:write(s, "\n") end end
	out(string.format("wram_dump: flat %04X-%04X (%s), frame %d", FROM, TO, DOMAIN, emu.framecount()))
	for base = FROM, TO - 1, 16 do
		local hex, asc = {}, {}
		for i = 0, 15 do
			local a = base + i
			if a < TO then
				local v = memory.read_u8(a, DOMAIN) or 0
				hex[#hex + 1] = string.format("%02X", v)
				asc[#asc + 1] = (v >= 32 and v < 127) and string.char(v) or "."
			end
		end
		out(string.format("%04X: %s  %s", base, table.concat(hex, " "), table.concat(asc)))
	end
	if f then f:close() end
end
MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then while true do tick(); emu.frameadvance() end end
