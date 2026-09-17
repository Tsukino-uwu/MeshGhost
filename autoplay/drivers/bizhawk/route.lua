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
--        grid.tile(x, y)                -> open, grass, trainer, oneWay   for a tile inside the map: nil when a step
--                                       onto it is not planned; `grass` true where wild encounters happen; `trainer` the
--                                       unbeaten trainer that looks at it ({x, y} and `local_id` or `map_object`), or nil;
--                                       `oneWay`, optional, a direction ("down"): the tile is stepped onto only moving that
--                                       way and left the same way, never stood on (a ledge hopped). The target is asked for
--                                       too, so a warp is open when it is the target
--        optional: grid.elevation (the player's level now) and grid.elevationAt(x, y) (a tile's), used with h.elevationStep
--   elevationStep(level, tileLevel, fromTileLevel) -> the level after the step, or nil when it is refused. Given, the plan
--                                       carries the player's level in its state, and the cross-map flood does too, from
--                                       h.playerElevation() on the map it starts on (Emerald: Route 110's ground at 3
--                                       and at 1 meets through tiles of 0, 2026-09-17)
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
--   for a goto to another map (`M.travel`):
--   mapExits(map)        -> nil, or { width, height, exits }   any map by its name, read from the game's own tables:
--                                       each exit { kind = "edge", direction, offset, to } -- walked off this map's
--                                       side that way onto `to`, a tile along the side at c being c - offset there --,
--                                       or { kind = "warp", x, y, to, to_warp, behaviour } -- arriving on `to`'s
--                                       warps[to_warp + 1] --; each with a `key` naming it on this map; and `warps`, the
--                                       map's warps in order
--   mapTile(map, x, y)   -> nil, or elevation, oneWay   a tile of any map a step on foot is planned onto, as the
--                                       game's tables read (no characters): its elevation, and a direction for a
--                                       one-way tile
--   for `M.talk`:
--   characters()         -> list        the other characters on this map, each { local_id, x, y }
--   facing()             -> direction   the way the player faces, or nil where not measured
--   talkStarted()        -> boolean     an A was taken: a message is up or a script has the controls
--   optional: talkAcross(x, y) -> boolean   A reaches a character across this tile (a counter)

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
--     other way; `route_in_sight` names each one the last plan had to cross. 100 until 2026-09-17, then 1000, about 125
--     tiles of grass (the user: skip trainers as much as possible -- a trainer battle cannot be run from and is several
--     Pokémon in a row, a wild one can be);
--   * a bump ends the ride at rest, marks the refused tile closed, and plans again (at most REPLANS times).
local TURN_COST, GRASS_COST, SIGHT_COST, REPLANS = 2, 8, 1000, 8

-- NO PROGRESS (2026-09-17, Emerald): a route never needs to stand on one tile many times, but a tile that sends the player
-- back does exactly that -- two unattended sessions' trips walked up 0.26's mud slope and slid back onto (17,38) for minutes,
-- until `goto` ran out of frames or was stopped. A goto that enters one tile more than ENTRY_LIMIT times ends `no_progress`,
-- naming the tile and its entries; the start tile counts as entered once. Across maps it ends the whole trip.
local ENTRY_LIMIT = 3

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
	-- nil when a tile is closed to a step moving `d` (nil: to stand on); otherwise the extra cost of stepping onto it.
	local function open(x, y, d)
		if x < 0 or y < 0 or x >= mapW or y >= mapH or closed[y * mapW + x] then return nil end
		local ok, grass, trainer, oneWay = tile(x, y)
		if not ok or (oneWay and DIRECTIONS[oneWay] ~= d) then return nil end
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
	-- With levels (h.elevationStep and grid.elevationAt), a state is (tile, facing, level); without, the level stays 0.
	local step, levelAt = h.elevationStep, grid.elevationAt
	if not (step and levelAt) then step = nil end
	local startLevel = step and (grid.elevation or 0) or 0
	for di = 1, 4 do
		local key = ((fromY * mapW + fromX) * 4 + di - 1) * 16 + startLevel
		dist[key] = 0
		push(0, key)
	end
	local goal
	while #heap > 0 do
		local item = pop()
		local cost, key = item[1], item[2]
		if cost == dist[key] then
			local level, rest = key % 16, key // 16
			local t, di = rest // 4, rest % 4 + 1
			local x, y = t % mapW, t // mapW
			if x == toX and y == toY then
				goal = key
				break
			end
			-- A one-way tile (a ledge) is left only the way it was entered.
			local _, _, _, oneWay = tile(x, y)
			for ni = 1, 4 do
				local d = order[ni]
				local nx, ny = x + d.dx, y + d.dy
				local extra = (not oneWay or DIRECTIONS[oneWay] == d) and open(nx, ny, d) or nil
				local nlevel = level
				if extra and step then
					nlevel = step(level, levelAt(nx, ny), levelAt(x, y))
					if not nlevel then extra = nil end
				end
				if extra then
					local nkey = ((ny * mapW + nx) * 4 + ni - 1) * 16 + nlevel
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
		table.insert(steps, 1, order[(key // 16) % 4 + 1])
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
	local closed, towardWarp, legsTaken, inSight, entries = {}, false, 0, {}, {}
	local stops = h.watch()
	local arriving, arrivingFor = h.arriving and h.arriving(), 0
	local function finish(outcome, extra)
		local _, x, y = h.position()
		local r = { target = { x = toX, y = toY }, at = { x = x, y = y }, outcome = outcome, moved = moved,
			turns = legsTaken, replans = replans, route_in_sight = #inSight > 0 and inSight or nil }
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end
	-- Counts an entry onto (x, y); true once it is more than ENTRY_LIMIT (NO PROGRESS).
	local function looping(x, y)
		local key = x .. "," .. y
		entries[key] = (entries[key] or 0) + 1
		return entries[key] > ENTRY_LIMIT
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
		if not startMap then looping(x, y) end
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
				if looping(x, y) then return finish("no_progress", { tile = { x = x, y = y }, entries = entries[x .. "," .. y] }) end
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
			if looping(x, y) then return finish("no_progress", { tile = { x = x, y = y }, entries = entries[x .. "," .. y] }) end
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

-- GOTO ACROSS MAPS (2026-09-17, Emerald). The maps between are planned breadth-first, fewest maps first, over the parts
-- of each map a walk can cover: from the tile it is entered on, a flood over `mapTile` (a step to a tile of the same
-- elevation, or to or from elevation 0, a one-way tile only its way), so an exit counts only where that part reaches it
-- -- a warp by its tile or the tile it is entered from (`enterWarp`), an edge by a side tile whose neighbour tile is
-- open. The first plan only went by each map's exit list: from 0.18's east strip, cut off by water, it crossed back and
-- round into a trainer's sight (2026-09-17). On each map the tile route to the exit is `M.go`'s, and it is ridden the
-- same way. A warp is gone to as any goto to a warp goes in; an edge is left from the nearest of the side tiles that
-- plan says lead on, holding the direction off the side until the map changes. After every map change the
-- program waits for the overworld at rest, then plans again from the map it is on, so a warp that lands somewhere
-- else is followed from there. An exit that cannot be reached or crossed is set aside for this goto and the maps
-- planned again, at most MAP_REPLANS times.
local MAP_REPLANS, SETTLE_FRAMES, EDGE_CANDIDATES, SEARCH_PARTS = 12, 600, 12, 400

function M.travel(h, p)
	local toMap, toX, toY = p.map, math.tointeger(p.x), math.tointeger(p.y)
	if type(toMap) ~= "string" or toMap == "" then return nil, "goto across maps needs map" end
	if not toX or not toY then return nil, "goto needs x and y, a tile on its map" end
	if not h.mapExits(toMap) then return nil, "no map " .. toMap end
	if not h.inOverworld() then return nil, "goto needs the overworld" end
	local L = h.limits
	local sub = { run = p.run, cross_grass = p.cross_grass }
	local failed, maps, moved, turns, replans, setAside, setAsideKeys = {}, {}, 0, 0, 0, 0, {}
	local phase, frames, inner, step, crossing, crossFrom = "settle", 0, nil, nil, nil, nil

	local function finish(outcome, extra)
		local map, x, y = h.position()
		local r = { target = { map = toMap, x = toX, y = toY }, map = map, at = { x = x, y = y }, outcome = outcome,
			maps = maps, moved = moved, turns = turns, replans = replans, exits_set_aside = #setAsideKeys > 0 and setAsideKeys or nil }
		for k, v in pairs(extra or {}) do
			if r[k] == nil then r[k] = v end
		end
		return nil, true, r
	end
	-- The tiles a walk covers on `map` from (sx, sy), keyed y * width + x.
	-- With h.elevationStep the flood carries the player's level (`level`, else the start tile's), as the plan does.
	local function flood(map, info, sx, sy, level)
		local w, hgt = info.width, info.height
		local step = h.elevationStep
		local start = step and (level or h.mapTile(map, sx, sy) or 0) or 0
		local reached, seen = { [sy * w + sx] = true }, { [(sy * w + sx) * 16 + start] = true }
		local queue, qi = { sx, sy, start }, 1
		while qi < #queue do
			local x, y, lv = queue[qi], queue[qi + 1], queue[qi + 2]
			qi = qi + 3
			local e0, way = h.mapTile(map, x, y)
			for _, d in pairs(DIRECTIONS) do
				local nx, ny = x + d.dx, y + d.dy
				if (not way or DIRECTIONS[way] == d) and nx >= 0 and ny >= 0 and nx < w and ny < hgt then
					local e1, way1 = h.mapTile(map, nx, ny)
					local nlv
					if e1 and (not way1 or DIRECTIONS[way1] == d) then
						if step then
							nlv = step(lv, e1, e0 or 0)
						elseif e0 == nil or e1 == e0 or e0 == 0 or e1 == 0 then
							nlv = 0
						end
					end
					if nlv and not seen[(ny * w + nx) * 16 + nlv] then
						seen[(ny * w + nx) * 16 + nlv] = true
						reached[ny * w + nx] = true
						queue[#queue + 1], queue[#queue + 2], queue[#queue + 3] = nx, ny, nlv
					end
				end
			end
		end
		return reached
	end
	-- The side tiles of an edge exit, each with its neighbour tile across.
	local function sides(here, there, e)
		local d, out = DIRECTIONS[e.direction], {}
		for c = 0, ((d.dx == 0) and here.width or here.height) - 1 do
			local t
			if e.direction == "up" then t = { x = c, y = 0, nx = c - e.offset, ny = there.height - 1 }
			elseif e.direction == "down" then t = { x = c, y = here.height - 1, nx = c - e.offset, ny = 0 }
			elseif e.direction == "left" then t = { x = 0, y = c, nx = there.width - 1, ny = c - e.offset }
			else t = { x = here.width - 1, y = c, nx = 0, ny = c - e.offset } end
			out[#out + 1] = t
		end
		return out
	end
	-- The steps from (map, x, y) to the target, fewest maps first, or nil: each { exit, key, sides }, `sides` the edge's
	-- side tiles that lead on.
	local function route(fromMap, fx, fy)
		local startInfo = h.mapExits(fromMap)
		local parts = { { map = fromMap, info = startInfo, reached = flood(fromMap, startInfo, fx, fy,
			h.playerElevation and h.playerElevation() or nil) } }
		local byMap = { [fromMap] = { parts[1].reached } }
		local i = 1
		while i <= #parts and #parts <= SEARCH_PARTS do
			local s = parts[i]
			i = i + 1
			local w = s.info.width
			if s.map == toMap and s.reached[toY * w + toX] then
				local path = {}
				while s.prev do
					table.insert(path, 1, s)
					s = s.prev
				end
				return path
			end
			for _, e in ipairs(s.info.exits) do
				local key = s.map .. " " .. e.key
				local there = not failed[key] and h.mapExits(e.to) or nil
				local seeds = {}
				if there and e.kind == "warp" then
					local how = h.enterWarp(e)
					local rx, ry = e.x + (how and how.dx or 0), e.y + (how and how.dy or 0)
					local arrive = there.warps[e.to_warp + 1]
					if arrive and rx >= 0 and ry >= 0 and s.reached[ry * w + rx] then seeds[1] = { x = arrive.x, y = arrive.y } end
				elseif there then
					for _, t in ipairs(sides(s.info, there, e)) do
						local _, way = h.mapTile(s.map, t.x, t.y)
						if s.reached[t.y * w + t.x] and not way and h.mapTile(e.to, t.nx, t.ny) then
							seeds[#seeds + 1] = { x = t.nx, y = t.ny, side = t }
						end
					end
				end
				for _, seed in ipairs(seeds) do
					local known = false
					for _, r in ipairs(byMap[e.to] or {}) do
						if r[seed.y * there.width + seed.x] then known = true end
					end
					if not known then
						local reached = flood(e.to, there, seed.x, seed.y)
						byMap[e.to] = byMap[e.to] or {}
						table.insert(byMap[e.to], reached)
						local lead = {}
						for _, other in ipairs(seeds) do
							if other.side and reached[other.y * there.width + other.x] then lead[#lead + 1] = other.side end
						end
						parts[#parts + 1] = { map = e.to, info = there, reached = reached, prev = s, exit = e, key = key, sides = lead }
					end
				end
			end
		end
		return nil
	end
	-- The side tile to leave from: of those leading on, the nearest whose route on the live grid crosses no trainer's line,
	-- else the nearest a route reaches at all (the user: routes out of a trainer's sight are preferred whenever possible).
	local function edgeTile(x, y)
		local cands, fallback = {}, nil
		for _, t in ipairs(step.sides) do
			cands[#cands + 1] = { x = t.x, y = t.y, dist = math.abs(t.x - x) + math.abs(t.y - y) }
		end
		table.sort(cands, function(a, b) return a.dist < b.dist end)
		for i = 1, math.min(#cands, EDGE_CANDIDATES) do
			local legs, inSight = M.plan(h, x, y, cands[i].x, cands[i].y, {}, p.cross_grass == true)
			if legs and #inSight == 0 then return cands[i].x, cands[i].y end
			if legs and not fallback then fallback = cands[i] end
		end
		if fallback then return fallback.x, fallback.y end
		return nil
	end
	local function setAsideStep(why)
		failed[step.key], setAside, phase, frames = true, setAside + 1, "settle", 0
		setAsideKeys[#setAsideKeys + 1] = step.key .. (why and (": " .. why) or "")
		if setAside > MAP_REPLANS then return finish("unreachable", { reason = "set aside " .. setAside .. " exits" }) end
		return nil, false
	end

	return function()
		frames = frames + 1
		local map, x, y = h.position()

		if phase == "settle" then
			if not (h.inOverworld() and h.atRest()) then
				if frames > SETTLE_FRAMES then return finish("left_overworld") end
				return nil, false
			end
			if maps[#maps] ~= map then maps[#maps + 1] = map end
			local why
			if map == toMap then
				inner, why = M.go(h, { x = toX, y = toY, run = sub.run, cross_grass = sub.cross_grass })
				if not inner then return finish("unreachable", { reason = why }) end
				phase = "last"
				return nil, false
			end
			local path = route(map, x, y)
			if not path then
				return finish("unreachable", { reason = "no way on foot known from " .. map .. " (" .. x .. "," .. y .. ") to " ..
					toMap .. " (" .. toX .. "," .. toY .. ")" })
			end
			step = path[1]
			local e, tx, ty = step.exit, nil, nil
			if e.kind == "warp" then
				tx, ty = e.x, e.y
			else
				tx, ty = edgeTile(x, y)
				if not tx then return setAsideStep("no side tile a route reaches") end
			end
			inner = M.go(h, { x = tx, y = ty, run = sub.run, cross_grass = sub.cross_grass })
			if not inner then return setAsideStep() end
			phase, frames = e.kind, 0
			return nil, false
		end

		if phase == "cross" then
			if map ~= crossFrom then
				phase, frames = "settle", 0
				return nil, false
			end
			if h.refused() or frames > L.door then return setAsideStep() end
			return { [crossing.button] = true }, false
		end

		local pad, done, r = inner()
		if not done then return pad, false end
		moved, turns, replans = moved + (r.moved or 0), turns + (r.turns or 0), replans + (r.replans or 0)
		if phase == "last" then return finish(r.outcome, r) end
		if r.outcome == "map_changed" then
			phase, frames = "settle", 0
			return nil, false
		end
		if phase == "edge" and r.outcome == "done" then
			phase, frames, crossing, crossFrom = "cross", 0, DIRECTIONS[step.exit.direction], map
			return nil, false
		end
		if r.outcome == "unreachable" or r.outcome == "blocked" or r.outcome == "no_response" or r.outcome == "done" then
			return setAsideStep(r.outcome .. (r.reason and (", " .. r.reason) or ""))
		end
		return finish(r.outcome, r)
	end, nil, 36000
end

-- TALK (2026-09-17, Emerald): to a tile beside a character by `M.go`'s route, facing it, a tapped A, and then the
-- module's own text program (`advance`, advance_text's) to its end. The character's tile is read again on arrival, since
-- one that walks about may have moved: the route is planned again up to TALK_TRIES times. The A is a tap, as the text
-- machine's are (a held A went on to answer the menu under it), tried again after TALK_WAIT frames without an answer.
-- TALK_TRIES was 3 until MR. BRINEY, pacing his cottage (17.0), answered "kept moving away" six calls of six (2026-09-17).
local TALK_TRIES, TALK_TAPS, TALK_WAIT, TALK_FACE_FRAMES = 10, 3, 40, 60

function M.talk(h, p, advance)
	if not h.inOverworld() then return nil, "talk needs the overworld" end
	local want = p.local_id ~= nil and math.tointeger(p.local_id) or nil
	local function find()
		local _, px, py = h.position()
		local best, bestDist
		for _, c in ipairs(h.characters()) do
			local d = math.abs(c.x - px) + math.abs(c.y - py)
			if (want == nil or c.local_id == want) and (best == nil or d < bestDist) then best, bestDist = c, d end
		end
		return best, bestDist
	end
	local who = find()
	if not who then
		return nil, want and ("no character with local_id " .. want .. " on this map") or "no character on this map"
	end
	local phase, frames, tries, taps, inner, face = "plan", 0, 0, 0, nil, nil
	local function finish(outcome, extra)
		local _, x, y = h.position()
		local r = { outcome = outcome, talked_to = { local_id = who.local_id, x = who.x, y = who.y }, at = { x = x, y = y } }
		for k, v in pairs(extra or {}) do
			if r[k] == nil then r[k] = v end
		end
		return nil, true, r
	end

	return function()
		frames = frames + 1
		if phase == "plan" then
			if not h.atRest() then
				if frames > h.limits.rest then return finish("not_at_rest") end
				return nil, false
			end
			local c = find()
			if not c then return finish("unreachable", { reason = "the character left the map" }) end
			who = c
			local _, px, py = h.position()
			-- Beside it, or two tiles off with a tile A reaches across between (a Center's counter, 2026-09-17).
			for name, d in pairs(DIRECTIONS) do
				if (px + d.dx == c.x and py + d.dy == c.y) or (px + 2 * d.dx == c.x and py + 2 * d.dy == c.y and h.talkAcross
					and h.talkAcross(px + d.dx, py + d.dy)) then
					face = name
				end
			end
			if face then
				phase, frames = "face", 0
				return nil, false
			end
			tries = tries + 1
			if tries > TALK_TRIES then return finish("unreachable", { reason = "the character kept moving away" }) end
			-- The tiles beside it, nearest first, to the first a route plans to.
			local spots = {}
			for _, d in pairs(DIRECTIONS) do
				local x, y = c.x - d.dx, c.y - d.dy
				spots[#spots + 1] = { x = x, y = y, dist = math.abs(x - px) + math.abs(y - py) }
				if h.talkAcross and h.talkAcross(x, y) then
					spots[#spots + 1] = { x = x - d.dx, y = y - d.dy, dist = math.abs(x - d.dx - px) + math.abs(y - d.dy - py) }
				end
			end
			table.sort(spots, function(a, b) return a.dist < b.dist end)
			-- The nearest spot a route reaches out of every trainer's sight, else the nearest a route reaches.
			local chosen
			for _, spot in ipairs(spots) do
				local legs, inSight = M.plan(h, px, py, spot.x, spot.y, {}, false)
				if legs and #inSight == 0 then
					chosen = spot
					break
				end
				if legs and not chosen then chosen = spot end
			end
			if chosen then inner = M.go(h, { x = chosen.x, y = chosen.y }) end
			if not inner then return finish("unreachable", { reason = "no route to a tile beside local_id " .. tostring(c.local_id) }) end
			phase, frames = "walk", 0
			return nil, false
		end

		if phase == "walk" then
			local pad, done, r = inner()
			if not done then return pad, false end
			inner = nil
			-- `unreachable` too: the tile beside him closed while walking (MR. BRINEY stepped next to it, 2026-09-17).
			if r.outcome ~= "done" and r.outcome ~= "blocked" and r.outcome ~= "unreachable" then return finish(r.outcome, r) end
			phase, frames = "plan", 0
			return nil, false
		end

		if phase == "face" then
			if h.facing() == face and h.atRest() then
				phase, frames = "tap", 0
				return nil, false
			end
			if frames > TALK_FACE_FRAMES then return finish("no_response", { facing = h.facing(), wanted = face }) end
			-- Held until the player faces it; a held direction into a character turns, then bumps.
			if h.facing() == face then return nil, false end
			return { [DIRECTIONS[face].button] = true }, false
		end

		if phase == "tap" then
			if h.talkStarted() then
				local why
				inner, why = advance()
				if not inner then return finish("stuck", { reason = why }) end
				phase = "text"
				return nil, false
			end
			if frames == 1 then
				taps = taps + 1
				if taps > TALK_TAPS then return finish("no_response", { reason = "A was pressed " .. TALK_TAPS .. " times and nothing answered" }) end
			end
			if frames > TALK_WAIT then frames = 0 end
			if frames <= 2 then return { A = true }, false end
			return nil, false
		end

		local pad, done, r = inner()
		if not done then return pad, false end
		return finish(r.outcome, r)
	end, nil, 36000
end

return M
