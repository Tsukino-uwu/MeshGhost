-- Removes the six codes bizhawk-cheat-probe.lua added. BizHawk can decode one to a nonsense address and mark it
-- active, and a cheat writing an arbitrary byte every frame gets blamed on the adapter.
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
