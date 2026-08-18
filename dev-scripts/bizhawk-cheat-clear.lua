-- MeshGhost — BizHawk: remove the cheats the probe added (DEVELOPMENT TOOL, never shipped)
--
-- Written 2026-08-18 the moment a screenshot showed why it was needed. bizhawk-cheat-probe.lua
-- added six codes and left them listed so the Cheats dialog could be read. The dialog showed that
-- BizHawk had accepted two of them and decoded them to NONSENSE -- "F89BD08B ED8D449E" became
-- address 0x0000000E, value 0x8B, one byte -- and marked them ACTIVE. Those are not GBA addresses
-- (EWRAM starts at 0x02000000), so this build did not decrypt the codes, it parsed the hex.
--
-- An active cheat writing an arbitrary byte to an arbitrary low address every frame is exactly the
-- kind of thing that later gets blamed on the adapter, so it is removed rather than left.
local CODES = {
	"F89BD08B ED8D449E",
	"7DE5E94F 91EB4C93",
	"D0000020 0004",
	"83000E48 1ED2",
	"74000130 02FB",
	"83000E48 0B45",
}

for _, code in ipairs(CODES) do
	if client.removecheat ~= nil then
		local ok, err = pcall(client.removecheat, code)
		console.log(string.format("remove %-22s -> %s%s", code, tostring(ok),
			(not ok) and (" (" .. tostring(err) .. ")") or ""))
	end
end
console.log("Cheats removed. Check Tools -> Cheats reads '0 cheats 0 active'; if any remain,")
console.log("clear them in that dialog -- removecheat matches on the code string it was given.")
pcall(client.opencheats)

MESHGHOST_DEV_TICK = function() end
