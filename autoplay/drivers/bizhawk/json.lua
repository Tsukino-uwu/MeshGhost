-- autoplay BizHawk driver: a small JSON encoder/decoder for the driver link (DEV TOOL, never shipped).
-- Enough for the link's lines: objects, arrays, strings with escapes, integers and floats, booleans,
-- null. A table is encoded as an array when its keys are exactly 1..n with n > 0, otherwise as an
-- object; an empty table is an object. Decoded null is json.null, so a present-but-null key is
-- distinguishable from a missing one.

local json = {}
json.null = setmetatable({}, { __tostring = function() return "null" end })

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local encodeValue

local function encodeString(s)
	return '"' .. s:gsub('[%c"\\]', function(c)
		return escapes[c] or string.format("\\u%04x", c:byte())
	end) .. '"'
end

local function isArray(t)
	local n = 0
	for k in pairs(t) do
		if math.type(k) ~= "integer" or k < 1 then return false end
		n = n + 1
	end
	if n == 0 then return false end
	for i = 1, n do
		if t[i] == nil then return false end
	end
	return true
end

encodeValue = function(v, depth)
	if depth > 32 then error("json: nesting deeper than 32") end
	local kind = type(v)
	if v == nil or v == json.null then
		return "null"
	elseif kind == "boolean" then
		return v and "true" or "false"
	elseif kind == "number" then
		if math.type(v) == "integer" then return string.format("%d", v) end
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		return string.format("%.17g", v)
	elseif kind == "string" then
		return encodeString(v)
	elseif kind == "table" then
		local parts = {}
		if isArray(v) then
			for i = 1, #v do parts[i] = encodeValue(v[i], depth + 1) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, item in pairs(v) do
			parts[#parts + 1] = encodeString(tostring(k)) .. ":" .. encodeValue(item, depth + 1)
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("json: cannot encode a " .. kind)
end

function json.encode(v)
	return encodeValue(v, 0)
end

local decodeValue

local function skip(s, i)
	return s:find("[^ \t\r\n]", i) or #s + 1
end

local function decodeString(s, i)
	local out, j = {}, i + 1
	while true do
		local c = s:sub(j, j)
		if c == "" then error("json: unterminated string") end
		if c == '"' then return table.concat(out), j + 1 end
		if c == "\\" then
			local e = s:sub(j + 1, j + 1)
			local simple = ({ ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" })[e]
			if simple then
				out[#out + 1] = simple
				j = j + 2
			elseif e == "u" then
				local hex = s:sub(j + 2, j + 5)
				if not hex:match("^%x%x%x%x$") then error("json: bad \\u escape") end
				out[#out + 1] = utf8.char(tonumber(hex, 16))
				j = j + 6
			else
				error("json: bad escape \\" .. e)
			end
		else
			out[#out + 1] = c
			j = j + 1
		end
	end
end

decodeValue = function(s, i, depth)
	if depth > 32 then error("json: nesting deeper than 32") end
	i = skip(s, i)
	local c = s:sub(i, i)
	if c == "{" then
		local obj = {}
		i = skip(s, i + 1)
		if s:sub(i, i) == "}" then return obj, i + 1 end
		while true do
			if s:sub(i, i) ~= '"' then error("json: expected a key") end
			local key
			key, i = decodeString(s, i)
			i = skip(s, i)
			if s:sub(i, i) ~= ":" then error("json: expected ':'") end
			obj[key], i = decodeValue(s, i + 1, depth + 1)
			i = skip(s, i)
			local sep = s:sub(i, i)
			if sep == "}" then return obj, i + 1 end
			if sep ~= "," then error("json: expected ',' or '}'") end
			i = skip(s, i + 1)
		end
	elseif c == "[" then
		local arr = {}
		i = skip(s, i + 1)
		if s:sub(i, i) == "]" then return arr, i + 1 end
		while true do
			arr[#arr + 1], i = decodeValue(s, i, depth + 1)
			i = skip(s, i)
			local sep = s:sub(i, i)
			if sep == "]" then return arr, i + 1 end
			if sep ~= "," then error("json: expected ',' or ']'") end
			i = i + 1
		end
	elseif c == '"' then
		return decodeString(s, i)
	elseif s:sub(i, i + 3) == "true" then
		return true, i + 4
	elseif s:sub(i, i + 4) == "false" then
		return false, i + 5
	elseif s:sub(i, i + 3) == "null" then
		return json.null, i + 4
	end
	local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
	if not num or num == "" or num == "-" then error("json: unexpected character at " .. i) end
	local n = tonumber(num)
	if not n then error("json: bad number " .. num) end
	return math.tointeger(n) or n, i + #num
end

function json.decode(s)
	local v, i = decodeValue(s, 1, 0)
	if skip(s, i) <= #s then error("json: trailing characters") end
	return v
end

return json
