-- autoplay BizHawk driver: `goto`, a planned route ridden to a tile, shared by the game modules (DEV TOOL, never shipped).
--
-- Moved out of games/emerald.lua on 2026-09-17 so a second game gets `goto` by supplying hooks, as text.lua did for text
-- and battles. What is in here decides the ROUTE -- what a step, a turn, grass and a trainer's line cost -- and when to
-- hold a direction, turn, let go and plan again; everything a game measured -- where the player stands, whether a step
-- began or was refused, which tiles are open, how a warp is entered, how a bike coasts -- comes from the module through
-- the hooks below, and each module's comments name the measurements. The driver loads this file and hands it to each
-- game module (`lib.route`); a module offers the program as `game.programs["goto"]`, calling `lib.route.go(hooks, p)`.
--
-- HOOKS, per module (`h`):
--   position()           -> map, x, y   the map's name and the player's tile, which moves to the next tile on the frame
--                                       a step BEGINS
--   inOverworld()        -> boolean
--   watch()              -> function    called once per goto; the function it returns is called every frame and returns
--                                       an outcome and its fields to stop with (a trainer seeing the player, a message
--                                       or a menu opening), or nil
--   atRest()             -> boolean     standing still, the last step finished
--   refused()            -> boolean     the step held for was refused (a bump), this frame
--   idle()               -> boolean     held input is doing nothing this frame (counts towards no_response)
--   ride(run)            -> table       read before each plan: `buttons` held with the direction (nil or {} for none; B to
--                                       run), and for a ride that carries on once let go, `coast(tiles)` -> true to let
--                                       go now with that many tiles left on the leg, and `shortLeg`, the longest last leg
--                                       reached by stopping at its corner first
--   routeGrid(fromX, fromY, toX, toY) -> grid, or nil and the reason
--        grid.width, grid.height        the map's own size in tiles
--        grid.where                     appended to a refusal ("at elevation 3"), or nil
--        grid.tile(x, y)                -> open, grass, trainer   for a tile inside the map: nil when a step onto it is
--                                       not planned; `grass` true where wild encounters happen; `trainer` the unbeaten
--                                       trainer that looks at it ({x, y} and `local_id` or `map_object`), or nil. The
--                                       target is asked for too, so a warp is open when it is the target
--   warps()              -> list        the map's warps, each with x and y
--   enterWarp(w)         -> nil, or { press = "up" | "down" | "left" | "right", dx, dy, fromRest }
--                                       nil: a step onto the warp enters it. Otherwise the route goes to the warp's tile
--                                       moved by dx, dy (a door entered from below), and `press` is held there until
--                                       the map changes; `fromRest` true when the last step onto the warp has to begin
--                                       from rest (a held step was refused there)
--   blockedBy(x, y)      -> table       what stands on a tile refused once too often
--   limits               = { rest, idle, press, door, step }   frames: waiting to be at rest; idle frames and frames in
--                                       all before a held direction is `no_response`; the same toward a warp or while
--                                       entering one; a coast or a last step finishing
--   optional:
--   arriving()           -> function    called once per goto; the function it returns is called first every frame and
--                                       returns true while a warp or a map change is still under way, and nothing is
--                                       held then; the map is compared once it returns false, and after `limits.door`
--                                       frames of it the goto ends. Crystal's map id changed 8 frames into a door's
--                                       load, and the game then walked the player off the door by itself (2026-09-17)

local M = {}

local DIRECTIONS = {
	up = { button = "Up", dx = 0, dy = -1 }, down = { button = "Down", dx = 0, dy = 1 },
	left = { button = "Left", dx = -1, dy = 0 }, right = { button = "Right", dx = 1, dy = 0 },
}

-- THE PLAN (2026-09-16, Emerald; the costs from the user's asks, `phase13.md` step 11):
--   * the cost is a tile a step plus TURN_COST a turn, so the route takes straight legs where it can, and GRASS_COST
--     more for a tile of tall grass unless `cross_grass` is true, as with a Repel running (the user: "some paths might
--     require you to go across grass, with no way around" -- a cost, not a wall);
--   * SIGHT_COST more for a tile an unbeaten trainer looks at, so a route enters a trainer's line only where there is no
--     other way; `route_in_sight` names each one the last plan had to cross;
--   * a bump ends the ride at rest, marks the refused tile closed, and plans again (at most REPLANS times).
local TURN_COST, GRASS_COST, SIGHT_COST, REPLANS = 2, 8, 100, 8

-- The legs from one tile to another, or nil and why. `closed` holds tiles refused on this goto, keyed y * width + x.
-- Also returns the tiles in a trainer's line the route crosses, and the width the keys use.
function M.plan(h, fromX, fromY, toX, toY, closed, crossGrass)
	local grid, why = h.routeGrid(fromX, fromY, toX, toY)
	if not grid then return nil, why end
	local mapW, mapH = grid.width, grid.height
	if toX < 0 or toY < 0 or toX >= mapW or toY >= mapH then
		return nil, string.format("(%d,%d) is outside this map's %d by %d", toX, toY, mapW, mapH)
	end
	local where = grid.where and (" " .. grid.where) or ""
	local tile = grid.tile
	-- nil when a tile is closed; otherwise the extra cost of stepping onto it.
	local function open(x, y)
		if x < 0 or y < 0 or x >= mapW or y >= mapH or closed[y * mapW + x] then return nil end
		local ok, grass, trainer = tile(x, y)
		if not ok then return nil end
		return ((grass and not crossGrass) and GRASS_COST or 0) + (trainer and SIGHT_COST or 0)
	end
	if not open(toX, toY) then
		return nil, string.format("(%d,%d) is not an open tile%s", toX, toY, where)
	end
	-- Dijkstra over (tile, facing) with a binary heap.
	local order = { DIRECTIONS.up, DIRECTIONS.down, DIRECTIONS.left, DIRECTIONS.right }
	local dist, prev, heap = {}, {}, {}
	local function push(cost, key)
		heap[#heap + 1] = { cost, key }
		local i = #heap
		while i > 1 do
			local parent = i // 2
			if heap[parent][1] <= heap[i][1] then break end
			heap[parent], heap[i] = heap[i], heap[parent]
			i = parent
		end
	end
	local function pop()
		local top = heap[1]
		local last = table.remove(heap)
		if #heap > 0 then
			heap[1] = last
			local i = 1
			while true do
				local l, r, m = i * 2, i * 2 + 1, i
				if l <= #heap and heap[l][1] < heap[m][1] then m = l end
				if r <= #heap and heap[r][1] < heap[m][1] then m = r end
				if m == i then break end
				heap[m], heap[i] = heap[i], heap[m]
				i = m
			end
		end
		return top
	end
	for di = 1, 4 do
		local key = (fromY * mapW + fromX) * 4 + di - 1
		dist[key] = 0
		push(0, key)
	end
	local goal
	while #heap > 0 do
		local item = pop()
		local cost, key = item[1], item[2]
		if cost == dist[key] then
			local t, di = key // 4, key % 4 + 1
			local x, y = t % mapW, t // mapW
			if x == toX and y == toY then
				goal = key
				break
			end
			for ni = 1, 4 do
				local d = order[ni]
				local nx, ny = x + d.dx, y + d.dy
				local extra = open(nx, ny)
				if extra then
					local nkey = (ny * mapW + nx) * 4 + ni - 1
					local ncost = cost + 1 + extra + ((ni ~= di and cost > 0) and TURN_COST or 0)
					if dist[nkey] == nil or ncost < dist[nkey] then
						dist[nkey], prev[nkey] = ncost, key
						push(ncost, nkey)
					end
				end
			end
		end
	end
	if not goal then return nil, string.format("no open route from (%d,%d) to (%d,%d)%s", fromX, fromY, toX, toY, where) end
	-- Walk back to the start, then fold the steps into legs.
	local steps, key = {}, goal
	while prev[key] do
		table.insert(steps, 1, order[key % 4 + 1])
		key = prev[key]
	end
	local legs, x, y, inSight, named = {}, fromX, fromY, {}, {}
	for _, d in ipairs(steps) do
		x, y = x + d.dx, y + d.dy
		local _, _, t = tile(x, y)
		if t and not named[t] then
			named[t] = true
			inSight[#inSight + 1] = { trainer_local_id = t.local_id, trainer_map_object = t.map_object,
				trainer_at = { x = t.x, y = t.y }, first_tile = { x = x, y = y } }
		end
		local leg = legs[#legs]
		if leg and leg.d == d then
			leg.len, leg.endX, leg.endY = leg.len + 1, x, y
		else
			legs[#legs + 1] = { d = d, len = 1, endX = x, endY = y }
		end
	end
	return legs, inSight, mapW
end

-- goto {x, y, run, cross_grass}: to a tile on this map by a planned route of straight legs, holding each leg's direction
-- and switching to the next as the step into the corner begins -- a held direction turns on arrival, and the Mach Bike
-- kept its speed through a turn (Emerald, bike_probe.lua, 2026-09-16: the first tile after the corner read +0x0B 3).
-- A ride that coasts once let go lets go on the last leg by the module's `coast`, and a last leg of `shortLeg` tiles or
-- fewer is reached by stopping at its corner first (after a turn at speed the Mach Bike's first tile coasted three).
-- It stops for the same reasons `walk` does (the module's `watch`), and a warp or an edge that changes the map ends it
-- too. Returns (program, error, frame limit) like any program.
function M.go(h, p)
	local toX, toY = math.tointeger(p.x), math.tointeger(p.y)
	if not toX or not toY then return nil, "goto needs x and y, a tile on this map" end
	if not h.inOverworld() then return nil, "goto needs the overworld" end
	local L = h.limits
	local run, crossGrass = p.run == true, p.cross_grass == true
	local phase, frames, idle, moved, replans = "rest", 0, 0, 0, 0
	local startMap, lastX, lastY, legs, li, ride, width = nil, 0, 0, nil, 1, nil, 0
	local closed, towardWarp, legsTaken, inSight = {}, false, 0, {}
	local stops = h.watch()
	local arriving, arrivingFor = h.arriving and h.arriving(), 0
	local function finish(outcome, extra)
		local _, x, y = h.position()
		local r = { target = { x = toX, y = toY }, at = { x = x, y = y }, outcome = outcome, moved = moved,
			turns = legsTaken, replans = replans, route_in_sight = #inSight > 0 and inSight or nil }
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end
	local function hold()
		local pad = { [legs[li].d.button] = true }
		for k, v in pairs(ride.buttons or {}) do pad[k] = v end
		return pad
	end
	local function warpAhead(x, y, d)
		for _, w in ipairs(h.warps()) do
			if w.x == x + d.dx and w.y == y + d.dy then return true end
		end
		return false
	end

	-- ENTERING A WARP: the module says how each is entered (`enterWarp`); `entered` names the warp in the answer.
	local enter, warpX, warpY, restBefore = nil, toX, toY, false
	for _, w in ipairs(h.warps()) do
		if w.x == toX and w.y == toY then
			local how = h.enterWarp(w)
			if how then
				toX, toY, enter = toX + (how.dx or 0), toY + (how.dy or 0), DIRECTIONS[how.press]
				if how.fromRest then restBefore = true end
			end
		end
	end

	return function()
		frames = frames + 1
		local map, x, y = h.position()
		startMap = startMap or map
		-- A warp under way, where the module says so: wait for it with nothing held.
		if arriving then
			if arriving() then
				arrivingFor = arrivingFor + 1
				if arrivingFor <= L.door then return nil, false end
				if map ~= startMap then return finish("map_changed", { map = map, settled = false }) end
				return finish("left_overworld")
			end
			arrivingFor = 0
		end
		if map ~= startMap and enter then return finish("map_changed", { map = map, entered = { x = warpX, y = warpY } }) end
		if map ~= startMap then return finish("map_changed", { map = map }) end
		if not h.inOverworld() then return finish("left_overworld") end
		local stop, fields = stops()
		if stop then return finish(stop, fields) end

		if phase == "rest" then
			if not h.atRest() then
				if frames > L.rest then return finish("not_at_rest") end
				return nil, false
			end
			if x == toX and y == toY and not enter then return finish("done") end
			if x == toX and y == toY then
				phase, frames = "enter", 0
				return { [enter.button] = true }, false
			end
			-- A warp stepped onto ends the goto with map_changed; anything else still plans to stand on it.
			ride = h.ride(run)
			local planned, why, w = M.plan(h, x, y, toX, toY, closed, crossGrass)
			if not planned then return finish(replans > 0 and "blocked" or "unreachable", { reason = why }) end
			inSight, width = why, w
			legs, li, phase, frames, idle, lastX, lastY = planned, 1, "hold", 0, 0, x, y
			towardWarp = warpAhead(x, y, legs[1].d)
		end

		if phase == "coasting" then
			if x ~= lastX or y ~= lastY then
				moved = moved + math.abs(x - lastX) + math.abs(y - lastY)
				lastX, lastY, frames = x, y, 0
			end
			if h.atRest() then
				phase, frames = "rest", 0
				return nil, false
			end
			if frames > L.step then return finish("not_at_rest") end
			return nil, false
		end

		if phase == "enter" then
			-- Held into the warp until the map changes (checked above); a door that never opens stops it.
			if frames > L.door then return finish("no_response", { entering = { x = warpX, y = warpY } }) end
			return { [enter.button] = true }, false
		end

		if phase == "refused" then
			if h.atRest() then
				local d = legs[li].d
				closed[(y + d.dy) * width + (x + d.dx)] = "refused"
				replans = replans + 1
				if replans > REPLANS then
					return finish("blocked", { blocked_by = h.blockedBy(x + d.dx, y + d.dy) })
				end
				phase, frames = "rest", 0
			elseif frames > L.rest then
				return finish("not_at_rest")
			end
			return nil, false
		end

		-- hold: follow the legs.
		if x ~= lastX or y ~= lastY then
			moved = moved + math.abs(x - lastX) + math.abs(y - lastY)
			lastX, lastY, frames, idle = x, y, 0, 0
			if x == toX and y == toY then
				phase = "coasting"
				return nil, false
			end
			local turned = false
			if x == legs[li].endX and y == legs[li].endY and li < #legs then
				li, legsTaken, turned = li + 1, legsTaken + 1, true
			end
			local leg = legs[li]
			if restBefore and x + leg.d.dx == warpX and y + leg.d.dy == warpY then
				phase = "coasting"
				return nil, false
			end
			-- Not on a corner tile: letting go there would coast along the leg just finished.
			if ride.coast and not turned then
				local last = li == #legs
				local stopAtCorner = ride.shortLeg ~= nil and li == #legs - 1 and legs[#legs].len <= ride.shortLeg
				if (last or stopAtCorner) and ride.coast(math.abs(leg.endX - x) + math.abs(leg.endY - y)) then
					phase = "coasting"
					return nil, false
				end
			end
			towardWarp = warpAhead(x, y, leg.d)
			return hold(), false
		end
		if h.refused() then
			phase, frames = "refused", 0
			return nil, false
		end
		if h.idle() then idle = idle + 1 end
		if towardWarp then
			if frames > L.door then return finish("no_response") end
		elseif idle > L.idle or frames > L.press then
			return finish("no_response")
		end
		return hold(), false
	end, nil, 7200
end

return M
