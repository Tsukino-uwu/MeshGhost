-- ui_signals_probe.lua -- READ-ONLY: which bytes tell a TEXT BOX over the overworld apart from a
-- FULL-SCREEN menu? Logs, on every change (and every 5s regardless), the signals the drawn tier's
-- positive gate and its neighbours read: wSpriteUpdatesEnabled (the "sprites-off" gate),
-- wMapStatus / wBattleMode, how many OAM entries are live and what the player's four (OAM 0-3)
-- hold, and the LCD registers (LCDC, WY, WX, SCX/SCY). Vanilla-family addresses (V1.0/V1.1/
-- Speedchoice, hash-verified `.sym`s); refuses AP. Written 2026-09-09 after the user saw a fishing
-- window paint no ghosts: the fishing script clears wSpriteUpdatesEnabled exactly as the party
-- menu does, while the overworld (and every NPC, frozen) stays on screen. Dump everything, filter
-- when reading. Dev-loader contract.
local W, SB = "WRAM", "System Bus"
local function flat(cpu) return cpu < 0xD000 and cpu - 0xC000 or 0x1000 + (cpu - 0xD000) end
local W_SPR_ON, W_MAPSTATUS, W_BATTLE = flat(0xC2CE), flat(0xD432), flat(0xD22D)
local function r(a, d) return memory.read_u8(a, d) or -1 end
local t = {}
for i = 0, 2 do t[#t + 1] = string.char(memory.read_u8(0x134 + i, "ROM") or 0) end
local refuse = table.concat(t) == "AP_"
local port = os.getenv("MESHGHOST_BRIDGE_PORT") or "noport"
local f = io.open(string.format("%s/ui_signals_%s_%s.log", (io.popen("cd"):read("*l") or "."), os.date("%Y%m%d_%H%M%S"), port), "w")
local function log(s) console.log(s); if f then f:write(os.date("%H:%M:%S "), s, "\n"); f:flush() end end
if refuse then log("ui_signals_probe: refusing on an Archipelago ROM (its wSpriteUpdatesEnabled is unmeasured)") end
local last, frames = nil, 0
local function tick()
	frames = frames + 1
	if refuse or frames % 6 ~= 0 then return end
	local live, player = 0, {}
	for i = 0, 39 do
		local y, x, tile, attr = r(i * 4, "OAM"), r(i * 4 + 1, "OAM"), r(i * 4 + 2, "OAM"), r(i * 4 + 3, "OAM")
		if y > 0 and y < 160 then live = live + 1 end
		if i < 12 then player[#player + 1] = string.format("%d,%d/%02X/%02X", x, y, tile, attr) end
	end
	-- the adapter's own text-box tell: BG tilemap row 12, column 0 (corner tile 121 = a box top-left)
	local lcdc = r(0xFF40, SB)
	local map = ((lcdc & 0x08) ~= 0) and 0x1C00 or 0x1800
	local corner = memory.read_u8(map + 12 * 32, "VRAM") or -1
	-- CGB BG attributes live in VRAM bank 1 (BizHawk's VRAM domain: bank 1 at +0x2000). Bit 7 is
	-- BG-over-OBJ priority: set on the text box's tiles means the game COVERS a sprite under it.
	local attr12 = memory.read_u8(0x2000 + map + 12 * 32 + 5, "VRAM") or -1
	local attr14 = memory.read_u8(0x2000 + map + 14 * 32 + 5, "VRAM") or -1
	local attr6 = memory.read_u8(0x2000 + map + 6 * 32 + 5, "VRAM") or -1
	local line = string.format("sprOn=%d mapstatus=%d battle=%d live=%d oam0-11=[%s] LCDC=%02X WY=%d WX=%d SCX=%d SCY=%d row12col0=%d attr(row12,14,6 col5)=%02X,%02X,%02X",
		r(W_SPR_ON, W), r(W_MAPSTATUS, W), r(W_BATTLE, W), live, table.concat(player, " "),
		lcdc, r(0xFF4A, SB), r(0xFF4B, SB), r(0xFF43, SB), r(0xFF42, SB), corner, attr12, attr14, attr6)
	if line ~= last or frames % 300 == 0 then log(line); last = line end
end
MESHGHOST_DEV_TICK = tick
if not MESHGHOST_DEV_LOADER then while true do tick(); emu.frameadvance() end end
