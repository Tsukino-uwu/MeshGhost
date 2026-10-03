-- `goto`, a planned route ridden to a tile, shared by the autoplay game modules (a dev tool, never shipped). This
-- decides the route and when to hold a direction, turn, let go and plan again; what a game measured comes from the
-- module through the hooks below, except M.solve's bike speeds and its level rules for SURF and a push (Emerald's). A
-- module offers it as `game.programs["goto"]`, calling `lib.route.go`, `reach` or `travel` with its hooks.
--
-- Hooks, per module (`h`):
--   position() -> map, x, y: the map's name and the player's tile, which moves on the frame a step begins
--   inOverworld() -> boolean
--   watch() -> function: called once per goto; what it returns is called every frame and returns an outcome and its
--     fields to stop with (a trainer seeing the player, a message or a menu opening), or nil
--   atRest() -> boolean: standing still, the last step finished
--   refused() -> boolean: the step held for was refused (a bump), this frame
--   idle() -> boolean: held input is doing nothing this frame (counts towards no_response)
--   ride(run) -> table, read before each plan: `buttons` held with the direction (B to run); `mount`, a button pressed
--     once per goto, at rest, before planning (a bike on SELECT); and for a ride that carries on once let go,
--     `coast(tiles)` -> true to let go now with that many tiles left on the leg, and `shortLeg`, the longest last leg
--     reached by stopping at its corner first
--   routeGrid(fromX, fromY, toX, toY) -> grid, or nil and the reason:
--     grid.width, grid.height: the map's own size in tiles; grid.where: appended to a refusal, or nil
--     grid.tile(x, y) -> open, grass, trainer, oneWay, obstacle, timed, for a tile inside the map: nil when a step
--       onto it is not planned; `grass` where wild encounters happen; `trainer` the unbeaten trainer that looks at it,
--       one table per trainer ({x, y} and `local_id` or `map_object`); optional: `oneWay`, a direction, the tile
--       stepped onto only moving that way and left the same way (a ledge hopped); `obstacle`, the action that clears
--       it; `timed`, a turning trainer's line ({trainer, way}). The target is asked for too, so a warp is open when it
--       is the target
--     optional: grid.elevation (the player's level now) and grid.elevationAt(x, y), used with h.elevationStep
--   elevationStep(level, tileLevel, fromTileLevel) -> the level after the step, or nil when it is refused. Given, the
--     plan carries the player's level in its state, and the cross-map flood does too, from h.playerElevation() on the
--     map it starts on (two levels can meet through a third)
--   warps() -> list: the map's warps, each with x and y
--   enterWarp(w) -> nil, or { press = "up" | "down" | "left" | "right", dx, dy, fromRest }: nil when a step onto the
--     warp enters it; otherwise the route goes to the warp's tile moved by dx, dy (a door entered from below) and
--     holds `press` there until the map changes, `fromRest` when the last step onto it must begin from rest
--   blockedBy(x, y) -> table: what stands on a tile refused once too often
--   limits = { rest, idle, press, door, step }, in frames: waiting to be at rest; idle frames and frames in all before
--     a held direction is `no_response`; the same toward a warp or while entering one; a coast or a last step finishing
--   optional:
--   busy() -> boolean: a script holds the player (a floor switch's): nothing is held, and the route is planned again
--     once it lets go; `busy` after BUSY_LIMIT frames of it
--   locked() -> boolean: the controls are held with no script (a landing): a trip and a room's plan wait for it
--   turnFacing(slot) -> direction: the way a turning trainer faces now, for a `timed` line
--   arriving() -> function: called once per goto; what it returns is called first every frame and is true while a
--     warp or a map change is under way, with nothing held; the map is compared once it is false, and after
--     `limits.door` frames of it the goto ends (a map id can change mid-load, and a game may walk the player off the
--     door by itself)
--   for a goto to another map (`M.travel`):
--   mapExits(map) -> nil, or { width, height, exits, warps }: any map by its name, from the game's own tables, `warps`
--     in order. Each exit has a `key` naming it on this map: { kind = "edge", direction, offset, to }, walked off this
--     side onto `to`, a tile at c along the side being c - offset there; { kind = "warp", x, y, to, to_warp,
--     behaviour }, arriving on `to`'s warps[to_warp + 1]; optional { kind = "fall", x, y, to } (a crack, onto the same
--     tile of `to`); { kind = "dive" | "emerge", to } (from any deep-water tile reached, `deepWater`, onto the same
--     tile of `to`); and an "emerge" with `arrive` { x, y }, a fixed landing, tried from a tile `surfaceSpot` accepts
--   mapTile(map, x, y) -> nil, or elevation, oneWay: a tile of any map a step on foot is planned onto, as the game's
--     tables read it (no characters)
--   optional, for M.solve: room(map) -> the room it searches; act(kind, act) -> a program doing one of the plan's
--     actions (surf, smash, push, climb, slide, ride, dive, emerge); deepWater(map, x, y), surfaceSpot(map, x, y)
--   for `M.talk`: characters() -> the other characters on this map, each { local_id, x, y }; facing() -> the way the
--     player faces, or nil where not measured; talkStarted() -> true once an A was taken (a message is up or a script
--     has the controls); optional talkAcross(x, y) -> true where A reaches a character across this tile (a counter)

local M = {}

local DIRECTIONS = {
	up = { button = "Up", dx = 0, dy = -1 }, down = { button = "Down", dx = 0, dy = 1 },
	left = { button = "Left", dx = -1, dy = 0 }, right = { button = "Right", dx = 1, dy = 0 },
}

-- The plan's costs: a tile a step plus TURN_COST a turn, so the route takes straight legs; GRASS_COST more for tall
-- grass unless `cross_grass` (a Repel running), a cost rather than a wall since some paths cross it; SIGHT_COST more
-- for a tile an unbeaten trainer looks at (about 125 tiles of grass: a trainer battle cannot be run from);
-- OBSTACLE_COST more for a tile an action clears, where the walk stops and answers `obstacle`. A bump closes the tile
-- and plans again, REPLANS times.
local TURN_COST, GRASS_COST, SIGHT_COST, REPLANS, OBSTACLE_COST = 2, 8, 1000, 8, 20
-- Turning trainers: a tile only one loaded, turning trainer sees (grid.tile's `timed`) costs TIMED_COST. The legs end
-- on the tile before that line, and `goto` waits there for a fresh turn to a way that sees none of the line's tiles
-- ahead, then crosses; TURN_LIMIT frames without one ends it `turn_wait`.
local TIMED_COST, TURN_LIMIT = 40, 3600

-- A route never stands on one tile many times, but a tile that sends the player back (a slope) does: entering one tile
-- more than ENTRY_LIMIT times ends `no_progress`, the start counting once. Across maps it ends the whole trip.
local ENTRY_LIMIT = 3
local MOUNT_FRAMES = 60

-- The legs from one tile to another, or nil and why. `closed` holds tiles refused on this goto, keyed y * width + x.
-- Also returns each trainer whose line the route crosses, the width the keys use and the obstacle the legs end before.
-- With `crossNow`, a turning trainer's line the route begins in is crossed (the wait for it is over); any other such
-- line ends the legs before it, and `turn` (the fifth return) names the trainer, the tile to wait on and the ways that
-- see the line's tiles ahead.
function M.plan(h, fromX, fromY, toX, toY, closed, crossGrass, crossNow, walls)
	local grid, why = h.routeGrid(fromX, fromY, toX, toY)
	if not grid then return nil, why end
	local mapW, mapH = grid.width, grid.height
	if toX < 0 or toY < 0 or toX >= mapW or toY >= mapH then
		return nil, string.format("(%d,%d) is outside this map's %d by %d", toX, toY, mapW, mapH)
	end
	local where = grid.where and (" " .. grid.where) or ""
	local tile = grid.tile
	-- nil when a tile is closed to a step moving `d` (nil: to stand on); otherwise the extra cost of stepping onto it.
	-- With `walls` (a leg of M.reach's plan, which clears obstacles itself), a tile an action clears is closed.
	local function open(x, y, d)
		if x < 0 or y < 0 or x >= mapW or y >= mapH or closed[y * mapW + x] then return nil end
		local ok, grass, trainer, oneWay, obstacle, timed = tile(x, y)
		if not ok or (oneWay and DIRECTIONS[oneWay] ~= d) or (walls and obstacle) then return nil end
		return ((grass and not crossGrass) and GRASS_COST or 0) + (trainer and (timed and TIMED_COST or SIGHT_COST) or 0)
			+ (obstacle and OBSTACLE_COST or 0)
	end
	if not open(toX, toY) then
		return nil, string.format("(%d,%d) is not an open tile%s", toX, toY, where)
	end
	-- Dijkstra over (tile, facing, level), a binary heap; the level is 0 without h.elevationStep and grid.elevationAt.
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
			-- A one-way tile (a ledge) is left only the way it was entered. An obstacle's cost is paid once, stepping
			-- onto the first of a stretch (water to SURF: each tile of it after the first is a step).
			local _, _, _, oneWay, fromObstacle = tile(x, y)
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
					if fromObstacle and select(5, tile(nx, ny)) then ncost = ncost - OBSTACLE_COST end
					if dist[nkey] == nil or ncost < dist[nkey] then
						dist[nkey], prev[nkey] = ncost, key
						push(ncost, nkey)
					end
				end
			end
		end
	end
	if not goal then return nil, string.format("no open route from (%d,%d) to (%d,%d)%s", fromX, fromY, toX, toY, where) end
	local steps, key = {}, goal
	while prev[key] do
		table.insert(steps, 1, order[(key // 16) % 4 + 1])
		key = prev[key]
	end
	local legs, x, y, inSight, named, obstacle, turn = {}, fromX, fromY, {}, {}, nil, nil
	local allow = crossNow
	for si, d in ipairs(steps) do
		-- An obstacle cleared by an action (a rock to smash): the legs end in front of it; the goto answers `obstacle`.
		local _, _, _, _, what, timed = tile(x + d.dx, y + d.dy)
		if what then
			obstacle = { kind = what, x = x + d.dx, y = y + d.dy, from = { x = x, y = y }, facing = d.button }
			break
		end
		if not timed then allow = false end
		if timed and not allow then
			-- The ways that see this line's tiles ahead, while the route stays in it.
			local ways, tx, ty = {}, x, y
			for sj = si, #steps do
				tx, ty = tx + steps[sj].dx, ty + steps[sj].dy
				local _, _, _, _, _, tm = tile(tx, ty)
				if not tm or tm.trainer ~= timed.trainer then break end
				ways[tm.way] = true
			end
			turn = { trainer = timed.trainer, ways = ways, from = { x = x, y = y } }
			break
		end
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
	return legs, inSight, mapW, obstacle, turn
end

-- goto {x, y, run, cross_grass}: to a tile on this map by a planned route of straight legs, switching direction as the
-- step into the corner begins, so a held direction turns on arrival with no gap. It stops for the module's `watch`
-- reasons, and on a map change.
local BUSY_LIMIT = 900

function M.go(h, p)
	local toX, toY = math.tointeger(p.x), math.tointeger(p.y)
	if not toX or not toY then return nil, "goto needs x and y, a tile on this map" end
	if not h.inOverworld() then return nil, "goto needs the overworld" end
	local L = h.limits
	local run, crossGrass = p.run == true, p.cross_grass == true
	local phase, frames, idle, moved, replans = "rest", 0, 0, 0, 0
	local startMap, lastX, lastY, legs, li, ride, width = nil, 0, 0, nil, 1, nil, 0
	local closed, towardWarp, legsTaken, inSight, entries, stopAt, mounted = {}, false, 0, {}, {}, nil, false
	local stops = h.watch()
	local arriving, arrivingFor = h.arriving and h.arriving(), 0
	local busyFor = 0
	local crossNow, waiting, waitFacing = false, nil, nil
	local function finish(outcome, extra)
		local _, x, y = h.position()
		local r = { target = { x = toX, y = toY }, at = { x = x, y = y }, outcome = outcome, moved = moved,
			turns = legsTaken, replans = replans, route_in_sight = #inSight > 0 and inSight or nil }
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end
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
		if not h.inOverworld() then
			-- A warp that lands on this same map (a warp pad): the overworld left while the player stands on a warp
			-- tile is a warp taken, answered as a map change so `travel` plans again from the landing.
			if warpAhead(x, y, { dx = 0, dy = 0 }) then return finish("map_changed", { map = map, warped = { x = x, y = y } }) end
			return finish("left_overworld")
		end
		local stop, fields = stops()
		if stop then return finish(stop, fields) end
		-- A script holding the player (a floor switch): planned again once it lets go, so a refusal is not a wall.
		if h.busy and h.busy() then
			busyFor = busyFor + 1
			if busyFor > BUSY_LIMIT then return finish("busy") end
			phase, frames = "rest", 0
			return nil, false
		end
		busyFor = 0

		if phase == "rest" then
			if not h.atRest() then
				if frames > L.rest then return finish("not_at_rest") end
				return nil, false
			end
			if x == toX and y == toY and not enter then return finish("done") end
			-- Standing in front of an obstacle the plan ran into: planned again, so it is still there or gone.
			stopAt = nil
			if x == toX and y == toY then
				phase, frames = "enter", 0
				return { [enter.button] = true }, false
			end
			ride = h.ride(run)
			if ride.mount and not mounted then
				mounted, phase, frames = true, "mount", 0
				return { [ride.mount] = true }, false
			end
			local planned, why, w, obstacle, turn = M.plan(h, x, y, toX, toY, closed, crossGrass, crossNow, p.walls)
			crossNow = false
			if not planned then return finish(replans > 0 and "blocked" or "unreachable", { reason = why }) end
			if obstacle and #planned == 0 then return finish("obstacle", { obstacle = obstacle }) end
			-- On the tile before a turning trainer's line: wait there for it to turn away.
			if turn and #planned == 0 and h.turnFacing then
				waiting, waitFacing, phase, frames = turn, h.turnFacing(turn.trainer.slot), "turnwait", 0
				return nil, false
			end
			stopAt = (obstacle and obstacle.from) or (turn and turn.from) or nil
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

		if phase == "turnwait" then
			local f = h.turnFacing(waiting.trainer.slot)
			if f ~= waitFacing and f and not waiting.ways[f] then
				crossNow, waiting, phase, frames = true, nil, "rest", 0
				return nil, false
			end
			waitFacing = f
			if frames > TURN_LIMIT then
				return finish("turn_wait", { trainer_local_id = waiting.trainer.local_id,
					trainer_at = { x = waiting.trainer.x, y = waiting.trainer.y } })
			end
			return nil, false
		end

		if phase == "mount" then
			if frames < MOUNT_FRAMES then return nil, false end
			phase, frames = "rest", 0
			return nil, false
		end

		if phase == "enter" then
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
			if (x == toX and y == toY) or (stopAt and x == stopAt.x and y == stopAt.y) then
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
	end, nil, 14400
end

-- M.solve: one room's way to a tile when the room must be changed first (boulders pushed with STRENGTH, rocks broken,
-- water surfed, currents slid on, a waterfall climbed or come down, ledges hopped, cracks crossed on a bike or fallen
-- through). The state is where every boulder stands, which rocks are broken and whether STRENGTH is in use, so a push
-- that blocks a later one is never planned; exact for a room just entered, since the game puts its boulders and rocks
-- back. A push moves the boulder one tile onto open land of its own level, the player staying put; a current carries
-- the player while the next tile is water; a warp tile, or a crack or hole the module lists as a fall, ends the walk.
-- h.room(map) -> room, with room.start the player's state when `map` is the one stood on:
--   width, height; cell(x, y) -> kind, level, dir, grass: "land" (on foot), "ledge" (hopped moving `dir`), "water",
--   "current" (carries `dir`), "waterfall" (climbed moving up, carried moving down), nil where nothing goes; objects
--   { x, y, kind = "boulder" | "rock" | "solid" }; warp(x, y) -> true; sight(x, y) -> the trainer whose line it is and
--   whether that line is timed, or nil; crack(x, y) -> "crack" | "hole" | nil, and bike, true where a bike can be
--   ridden over them; can { surf, strength, smash, waterfall }; start { x, y, level, surf, strength }.
-- Two levels, as a boulder puzzle is searched: walks, a flood over where the player gets to with the boulders where
-- they stand (breaking a rock only ever opens a tile), and changes, a search over where the boulders stand, each
-- state's walk flooded once. Costs are tiles plus COST per action, nearer states first: a cheap plan, not always the
-- cheapest.
local SOLVE_STATES, SOLVE_SECONDS = 20000, 3
local COST = { strength = 14, push = 2, smash = 16, surf = 12, climb = 12, ride = 10 }
-- Emerald's MACH BIKE: its speed as the k-th step held from rest begins (k = 1, 2, then 3 on), kept through a turn; let
-- go, it coasts that many tiles, one less each tile; a crack holds it at 2 or more.
local BIKE_SPEED, RIDE_TILES = { 0, 1, 3 }, 60

local function heapPush(heap, f, v)
	heap[#heap + 1] = { f, v }
	local i = #heap
	while i > 1 do
		local parent = i // 2
		if heap[parent][1] <= heap[i][1] then break end
		heap[parent], heap[i] = heap[i], heap[parent]
		i = parent
	end
end
local function heapPop(heap)
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
	return top[1], top[2]
end

function M.solve(h, room, start, toX, toY, crossGrass)
	local W, H, cell, can = room.width, room.height, room.cell, room.can or {}
	if toX < 0 or toY < 0 or toX >= W or toY >= H then return nil, "the target is outside the map" end
	local solid, rockAt, rocks, boulders = {}, {}, 0, {}
	for _, o in ipairs(room.objects or {}) do
		local p = o.y * W + o.x
		if o.kind == "boulder" then boulders[#boulders + 1] = p
		elseif o.kind == "rock" then rocks = rocks + 1; rockAt[p] = rocks
		else solid[p] = true end
	end
	table.sort(boulders)
	local order = { DIRECTIONS.up, DIRECTIONS.down, DIRECTIONS.left, DIRECTIONS.right }
	local names = { "up", "down", "left", "right" }
	local function inside(x, y) return x >= 0 and y >= 0 and x < W and y < H end
	local function unpack(s)
		local surf, rest = s % 2, s // 2
		local level, p = rest % 16, rest // 16
		return p % W, p // W, level, surf
	end
	local function pack(x, y, level, surf) return ((y * W + x) * 16 + level) * 2 + surf end

	-- Rides: every tile a bike ride from rest at (sx, sy) stops on, over cracks held at speed, with its legs for `ride`
	-- (each leg's direction and the row or column where it ends) and its tiles, breadth first over (tile, way, steps
	-- held), never back the way it came; onto a crack too slowly, or onto a hole, it ends falling to the floor below.
	local rideCache, runUps = {}, {}
	local function runUp(x, y)
		local key = y * W + x
		if runUps[key] == nil then
			runUps[key] = false
			for di = 1, 4 do
				local d = order[di]
				for i = 1, 4 do
					local nx, ny = x + d.dx * i, y + d.dy * i
					if not inside(nx, ny) or cell(nx, ny) ~= "land" then break end
					if room.crack and room.crack(nx, ny) then
						runUps[key] = i >= 2
						break
					end
				end
				if runUps[key] then break end
			end
		end
		return runUps[key]
	end
	local function rides(sx, sy, level, c)
		local cacheKey = sx .. "," .. sy .. "," .. level
		if rideCache[c] and rideCache[c][cacheKey] then return rideCache[c][cacheKey] end
		local out, seen, queue, qi = {}, {}, {}, 1
		-- The level after entering (x, y) at `speed`, or nil; and "fall" where the player drops through it.
		local function open(x, y, fromLevel, lv, speed)
			if not inside(x, y) then return nil end
			local p = y * W + x
			local r = rockAt[p]
			if c.bs[p] or solid[p] or (r and (c.rock >> (r - 1)) & 1 == 0) then return nil end
			local kind, tl = cell(x, y)
			if kind ~= "land" then return nil end
			local hole = room.crack and room.crack(x, y)
			if hole == "hole" or (hole == "crack" and speed < 2) then return tl, "fall" end
			if not hole and room.warp(x, y) then return nil end
			local nl = tl
			if h.elevationStep then nl = h.elevationStep(lv, tl, fromLevel) end
			return nl
		end
		-- A stop keeps the queue entry of its last held step, whose parents give its legs.
		local function keep(x, y, lv, tiles, entry, fall)
			local key = y * W + x
			if not out[key] or out[key].tiles > tiles then out[key] = { x = x, y = y, level = lv, tiles = tiles, entry = entry, fall = fall } end
		end
		for di = 1, 4 do queue[#queue + 1] = { x = sx, y = sy, di = di, k = 0, lv = level, tiles = 0 } end
		while qi <= #queue do
			local q = queue[qi]
			qi = qi + 1
			local _, hereLevel = cell(q.x, q.y)
			if q.k > 0 then
				-- Let go here: the coast, one tile less fast each tile, stopping short of anything in the way.
				local d, v = order[q.di], BIKE_SPEED[math.min(q.k, 3)]
				local ex, ey, lv, n, fall = q.x, q.y, q.lv, 0, false
				for i = 1, v do
					local _, fl = cell(ex, ey)
					local nl, falls = open(ex + d.dx, ey + d.dy, fl, lv, v - i)
					if not nl then break end
					ex, ey, lv, n = ex + d.dx, ey + d.dy, nl, n + 1
					if falls then
						fall = true
						break
					end
				end
				if fall or not (room.crack and room.crack(ex, ey)) then keep(ex, ey, lv, q.tiles + n, q, fall) end
			end
			if q.tiles < RIDE_TILES then
				for nd = 1, 4 do
					local d = order[nd]
					local back = q.k > 0 and d.dx == -order[q.di].dx and d.dy == -order[q.di].dy
					if (q.k > 0 or nd == q.di) and not back then
						local k = q.k + 1
						local nx, ny = q.x + d.dx, q.y + d.dy
						local nl, falls = open(nx, ny, hereLevel, q.lv, BIKE_SPEED[math.min(k, 3)])
						local key = ((ny * W + nx) * 4 + nd) * 4 + math.min(k, 3)
						local e = { x = nx, y = ny, di = nd, k = k, lv = nl, tiles = q.tiles + 1, parent = q }
						if falls then
							keep(nx, ny, nl, q.tiles + 1, e, true)
						elseif nl and not seen[key] then
							seen[key] = true
							queue[#queue + 1] = e
						end
					end
				end
			end
		end
		local list = {}
		for _, stop in pairs(out) do
			local held, e = {}, stop.entry
			while e.parent do
				table.insert(held, 1, e)
				e = e.parent
			end
			local legs = {}
			for _, step in ipairs(held) do
				local name, to = names[step.di], (order[step.di].dx ~= 0) and step.x or step.y
				if legs[#legs] and legs[#legs].dir == name then legs[#legs].to = to
				else legs[#legs + 1] = { dir = name, to = to } end
			end
			stop.legs, stop.entry = legs, nil
			list[#list + 1] = stop
		end
		rideCache[c] = rideCache[c] or {}
		rideCache[c][cacheKey] = list
		return list
	end

	-- Walks: every walk state from `from` with the room as `c` leaves it ({ bs = boulder set, rock = mask }): the cost
	-- and the step that reached each, and the lowest state reached, which names the area.
	local function walks(from, c)
		local dist, prev, how, heap = { [from] = 0 }, {}, {}, {}
		heapPush(heap, 0, from)
		local lowest = from
		while #heap > 0 do
			local cost, s = heapPop(heap)
			if dist[s] == cost then
				if s < lowest then lowest = s end
				local x, y, level, surf = unpack(s)
				local here, hereLevel, hereDir = cell(x, y)
				if not (s ~= from and room.warp(x, y)) and not (x == toX and y == toY) then
					for di = 1, 4 do
						local d, name = order[di], names[di]
						local tx, ty = x + d.dx, y + d.dy
						local tp = ty * W + tx
						local r = rockAt[tp]
						-- A rock not broken yet is crossed as a smash and a step, on foot.
						local smash = r and (c.rock >> (r - 1)) & 1 == 0
						if inside(tx, ty) and not (here == "ledge" and hereDir ~= name) and not c.bs[tp] and not solid[tp]
							and not (smash and (surf == 1 or not can.smash)) then
							local kind, tl, tdir, grass = cell(tx, ty)
							local seen, timed = nil, nil
							if room.sight then seen, timed = room.sight(tx, ty) end
							local extra = ((grass and not crossGrass) and GRASS_COST or 0) + (seen and (timed and TIMED_COST or SIGHT_COST) or 0)
							local ns, nc, act
							if kind == "land" or (kind == "ledge" and tdir == name) then
								-- Off the water onto any level; on foot by the module's level rule, which may refuse.
								local nl = tl
								if surf == 0 and h.elevationStep then nl = h.elevationStep(level, tl, hereLevel) end
								if nl then ns, nc, act = pack(tx, ty, nl, 0), cost + 1 + extra, "step" end
								if nl and smash then nc, act = nc + COST.smash, "smash" end
							elseif kind == "water" then
								if surf == 1 then
									ns, nc, act = pack(tx, ty, 0, 1), cost + 1 + extra, "step"
								elseif can.surf and (level == 3 or level == 0) then
									ns, nc, act = pack(tx, ty, 0, 1), cost + 1 + COST.surf + extra, "surf"
								end
							elseif kind == "current" and surf == 1 then
								local px, py, len = tx, ty, 0
								while len < 256 do
									local k, _, cd = cell(px, py)
									if k ~= "current" then break end
									local cdir = DIRECTIONS[cd]
									local qx, qy = px + cdir.dx, py + cdir.dy
									local qk = inside(qx, qy) and cell(qx, qy) or nil
									if not (qk == "water" or qk == "current") or solid[qy * W + qx] then break end
									px, py, len = qx, qy, len + 1
								end
								ns, nc, act = pack(px, py, 0, 1), cost + 1 + len // 2, "slide"
							elseif kind == "waterfall" and surf == 1 and name == "down" then
								local px, py = tx, ty
								while py < H - 1 and cell(px, py) == "waterfall" do py = py + 1 end
								local k = cell(px, py)
								if k == "water" or k == "current" then ns, nc, act = pack(px, py, 0, 1), cost + 1 + (py - ty), "slide" end
							elseif kind == "waterfall" and surf == 1 and can.waterfall and name == "up" then
								local px, py = tx, ty
								while py > 0 and cell(px, py) == "waterfall" do py = py - 1 end
								local k = cell(px, py)
								if k == "water" or k == "current" then ns, nc, act = pack(px, py, 0, 1), cost + COST.climb + (ty - py), "climb" end
							end
							if ns and (dist[ns] == nil or nc < dist[ns]) then
								dist[ns], prev[ns], how[ns] = nc, s, { k = act, d = name }
								heapPush(heap, nc, ns)
							end
						end
					end
					-- On a map with cracks where a bike rides: every place a ride from here stops, from where the walk
					-- began and from a run-up, a straight run of land into a crack within four tiles.
					if surf == 0 and room.bike and here == "land" and (s == from or runUp(x, y)) then
						for _, r in pairs(rides(x, y, level, c)) do
							local ns, nc = pack(r.x, r.y, r.level, 0), cost + COST.ride + r.tiles
							if dist[ns] == nil or nc < dist[ns] then
								dist[ns], prev[ns], how[ns] = nc, s, { k = "ride", d = r.legs[1].dir, legs = r.legs, fall = r.fall }
								heapPush(heap, nc, ns)
							end
						end
					end
				end
			end
		end
		return dist, prev, how, lowest
	end
	local function stepsTo(prev, how, from, to, out)
		local list, s = {}, to
		while s ~= from do
			local a = how[s]
			local x, y = unpack(s)
			table.insert(list, 1, { k = a.k == "smash" and "step" or a.k, d = a.d, x = x, y = y, legs = a.legs, fall = a.fall })
			if a.k == "smash" then
				local px, py = unpack(prev[s])
				table.insert(list, 1, { k = "smash", d = a.d, rx = x, ry = y, x = px, y = py })
			end
			s = prev[s]
		end
		for _, a in ipairs(list) do out[#out + 1] = a end
	end

	-- Changes: a room state is { entry (a walk state), bl (boulders, sorted), rock, str, cost, parent, at, act }.
	local function bsetOf(bl)
		local s = {}
		for _, p in ipairs(bl) do s[p] = true end
		return s
	end
	-- The estimate that points the search at the target: tiles to it over every tile anything goes on, with nothing in
	-- the way (a breadth-first flood back from it), so a room state standing nearer is looked at first.
	local near, queue, qi = { [toY * W + toX] = 0 }, { toY * W + toX }, 1
	while qi <= #queue do
		local p = queue[qi]
		qi = qi + 1
		local x, y = p % W, p // W
		for di = 1, 4 do
			local nx, ny = x + order[di].dx, y + order[di].dy
			local np = ny * W + nx
			if inside(nx, ny) and near[np] == nil and cell(nx, ny) and not room.warp(nx, ny) then
				near[np] = near[p] + 1
				queue[#queue + 1] = np
			end
		end
	end
	local states, seen, heap = {}, {}, {}
	local function addState(st)
		states[#states + 1] = st
		local x, y = unpack(st.entry or st.at)
		heapPush(heap, st.cost + (st.goal and 0 or (near[y * W + x] or (math.abs(x - toX) + math.abs(y - toY)))), #states)
	end
	local entry = pack(start.x, start.y, start.level or 0, start.surf and 1 or 0)
	-- With every boulder gone and every rock broken, is the target reached at all? If not, nothing the search could
	-- push would reach it either, and the answer comes at once rather than after every push has been tried.
	do
		local dist = walks(entry, { bs = {}, rock = (1 << rocks) - 1 })
		local any = false
		for s in pairs(dist) do
			local x, y = unpack(s)
			if x == toX and y == toY then any = true end
		end
		if not any then return nil, "not reached even with every boulder and rock out of the way", 0 end
	end
	addState({ entry = entry, bl = boulders, rock = 0, str = start.strength and 1 or 0, cost = 0 })
	local began = os.clock()
	local goal, expanded = nil, 0
	while #heap > 0 do
		local _, i = heapPop(heap)
		local st = states[i]
		if st.goal then
			goal = st
			break
		end
		local sig = st.rock .. "|" .. st.str .. "|" .. table.concat(st.bl, ",")
		local c, dist, prev, lowest = nil, nil, nil, nil
		if not seen[st.entry .. "|" .. sig] then
			seen[st.entry .. "|" .. sig] = true
			c = { bs = bsetOf(st.bl), rock = st.rock }
			dist, prev, _, lowest = walks(st.entry, c)
		end
		local function broken(s)
			local mask = st.rock
			while s ~= st.entry do
				local x, y = unpack(s)
				local r = rockAt[y * W + x]
				if r then mask = mask | (1 << (r - 1)) end
				s = prev[s]
			end
			return mask
		end
		if dist and not seen[lowest .. "|" .. sig .. "|area"] then
			seen[lowest .. "|" .. sig .. "|area"] = true
			expanded = expanded + 1
			if expanded > SOLVE_STATES or os.clock() - began > SOLVE_SECONDS then
				return nil, "gave up after " .. expanded .. " room states", expanded
			end
			for s, cost in pairs(dist) do
				local x, y, _, surf = unpack(s)
				if x == toX and y == toY then
					addState({ goal = true, cost = st.cost + cost, parent = st, at = s })
				elseif surf == 0 and not (s ~= st.entry and room.warp(x, y)) then
					for di = 1, 4 do
						local d, name = order[di], names[di]
						local tx, ty = x + d.dx, y + d.dy
						local tp = ty * W + tx
						if inside(tx, ty) and c.bs[tp] and can.strength then
							local ux, uy = tx + d.dx, ty + d.dy
							local up = uy * W + ux
							local mask = broken(s)
							if inside(ux, uy) and not c.bs[up] and not solid[up] and not (rockAt[up] and (mask >> (rockAt[up] - 1)) & 1 == 0)
								and not room.warp(ux, uy) then
								local k1, l1 = cell(tx, ty)
								local k2, l2 = cell(ux, uy)
								if k2 == "land" and (k1 ~= "land" or l1 == l2 or l1 == 0 or l2 == 0) then
									local nb = {}
									for j, p in ipairs(st.bl) do nb[j] = (p == tp) and up or p end
									table.sort(nb)
									addState({ entry = s, bl = nb, rock = mask, str = 1, parent = st, at = s,
										cost = st.cost + cost + COST.push + (st.str == 0 and COST.strength or 0),
										act = { k = "push", d = name, bx = tx, by = ty, x = x, y = y } })
								end
							end
						end
					end
				end
			end
		end
	end
	if not goal then return nil, "no way even clearing what the party can clear", expanded end
	local chain, st = {}, goal
	while st do
		table.insert(chain, 1, st)
		st = st.parent
	end
	local acts = {}
	for j = 2, #chain do
		local from, to = chain[j - 1], chain[j]
		local _, prev, how = walks(from.entry, { bs = bsetOf(from.bl), rock = from.rock })
		stepsTo(prev, how, from.entry, to.at, acts)
		if to.act then acts[#acts + 1] = to.act end
	end
	return acts, nil, expanded
end

-- reach {x, y, run, cross_grass}: to a tile on this map by M.solve's plan -- each walk between obstacles is M.go's,
-- with the tiles an action clears closed, and each action the module's program (`h.act(kind, act)`). After each walk
-- or action the player must stand where the plan said, or the room is planned again from the game's own state (at
-- most REACH_REPLANS times). Where the plan needs no action it is one M.go, the same as `goto`; where the search finds
-- nothing, M.go is asked anyway, so its answer names why.
local REACH_REPLANS = 16

function M.reach(h, p)
	local toX, toY = math.tointeger(p.x), math.tointeger(p.y)
	if not toX or not toY then return nil, "goto needs x and y, a tile on this map" end
	if not h.room then return M.go(h, p) end
	local phase, frames, acts, ai, inner, replans, nodes = "plan", 0, nil, 0, nil, 0, 0
	local moved, turns, done, planSeconds, planMap = 0, 0, {}, 0, nil
	local function finish(outcome, extra)
		local _, x, y = h.position()
		local r = { target = { x = toX, y = toY }, at = { x = x, y = y }, outcome = outcome, moved = moved, turns = turns,
			replans = replans, actions = #done > 0 and done or nil, room_states = nodes,
			plan_ms = math.floor(planSeconds * 1000 + 0.5) }
		for k, v in pairs(extra or {}) do
			if r[k] == nil then r[k] = v end
		end
		return nil, true, r
	end
	local function start(a)
		if a.k == "go" then
			-- The last walk is the target itself, entered as `goto` enters a warp and planned as `goto` plans.
			local last = ai == #acts
			return M.go(h, { x = a.x, y = a.y, run = p.run and not a.foot, cross_grass = p.cross_grass, walls = not last or nil })
		end
		return h.act(a.k, a)
	end
	return function()
		frames = frames + 1
		if phase == "plan" then
			if not (h.inOverworld() and h.atRest()) or (h.busy and h.busy()) or (h.locked and h.locked()) then
				if frames > h.limits.rest + 600 then return finish("not_at_rest") end
				return nil, false
			end
			local map, x, y = h.position()
			planMap = map
			local room = h.room(map)
			local path, why, n = nil, "no room", 0
			local t0 = os.clock()
			if room then path, why, n = M.solve(h, room, room.start, toX, toY, p.cross_grass == true) end
			planSeconds, nodes = planSeconds + os.clock() - t0, nodes + (n or 0)
			local needs = false
			for _, a in ipairs(path or {}) do
				if a.k ~= "step" then needs = true end
			end
			if not needs then
				local why2
				inner, why2 = M.go(h, p)
				if not inner then return finish("unreachable", { reason = why2 or why }) end
				phase = "last"
				return nil, false
			end
			-- Steps fold into walks; a walk before a push or a smash is on foot (a boulder is not pushed from a bike).
			acts = {}
			for _, a in ipairs(path) do
				local prev = acts[#acts]
				if a.k == "step" then
					if prev and prev.k == "go" then prev.x, prev.y = a.x, a.y
					else acts[#acts + 1] = { k = "go", x = a.x, y = a.y } end
				else
					if (a.k == "push" or a.k == "smash") and prev and prev.k == "go" then prev.foot = true end
					acts[#acts + 1] = a
				end
			end
			ai, phase, inner = 1, "act", nil
			return nil, false
		end
		if phase == "last" then
			local pad, fin, r = inner()
			if not fin then return pad, false end
			moved, turns = moved + (r.moved or 0), turns + (r.turns or 0)
			return finish(r.outcome, r)
		end
		-- phase "act"
		if not inner then
			local a = acts[ai]
			local why
			inner, why = start(a)
			if not inner then return finish("stuck", { reason = a.k .. ": " .. tostring(why), action = a }) end
		end
		local pad, fin, r, err = inner()
		if not fin then return pad, false end
		inner = nil
		local a = acts[ai]
		-- A battle the action started (a wild one from a broken rock) is answered as a walk's is.
		if err and not h.inOverworld() then return finish("left_overworld", { reason = a.k .. ": " .. tostring(err) }) end
		if err then return finish("stuck", { reason = a.k .. ": " .. tostring(err), action = a }) end
		r = r or {}
		moved, turns = moved + (r.moved or 0), turns + (r.turns or 0)
		if a.k == "go" and r.outcome ~= "done" then
			if r.outcome == "blocked" or r.outcome == "unreachable" or r.outcome == "no_progress" or r.outcome == "no_response" then
				replans = replans + 1
				if replans > REACH_REPLANS then return finish(r.outcome, r) end
				phase, frames = "plan", 0
				return nil, false
			end
			return finish(r.outcome, r)
		end
		if a.k ~= "go" then done[#done + 1] = { kind = a.k, facing = a.d, x = a.bx or a.rx or a.x, y = a.by or a.ry or a.y } end
		local map, x, y = h.position()
		-- A fall through a crack (a ride's end) lands on the floor below: the trip plans again from there.
		if map ~= planMap then return finish("map_changed", { map = map }) end
		if x ~= a.x or y ~= a.y then
			replans = replans + 1
			if replans > REACH_REPLANS then return finish("off_plan", { expected = { x = a.x, y = a.y }, action = a.k }) end
			phase, frames = "plan", 0
			return nil, false
		end
		ai = ai + 1
		if ai > #acts then return finish("done", { map = map }) end
		return nil, false
	end, nil, 72000
end

-- M.travel, goto across maps: breadth-first, fewest maps first, over the parts of each map a walk covers from the tile
-- it is entered on (a flood over `mapTile`), so an exit counts only where that part reaches it, not by the map's exit
-- list alone (a strip cut off by water). On each map the route to the exit is `M.reach`'s; an edge is left from the
-- nearest side tile that leads on, holding the direction until the map changes. After every map change it plans again
-- from where it landed. An exit that cannot be reached or crossed is set aside and the maps planned again, MAP_REPLANS
-- times.
local MAP_REPLANS, SETTLE_FRAMES, EDGE_CANDIDATES, SEARCH_PARTS, STEADY_FRAMES = 12, 600, 12, 400, 30

function M.travel(h, p)
	local toMap, toX, toY = p.map, math.tointeger(p.x), math.tointeger(p.y)
	if type(toMap) ~= "string" or toMap == "" then return nil, "goto across maps needs map" end
	if not toX or not toY then return nil, "goto needs x and y, a tile on its map" end
	if not h.mapExits(toMap) then return nil, "no map " .. toMap end
	if not h.inOverworld() then return nil, "goto needs the overworld" end
	local L = h.limits
	local sub = { run = p.run, cross_grass = p.cross_grass }
	local failed, maps, moved, turns, replans, setAside, setAsideKeys = {}, {}, 0, 0, 0, 0, {}
	local phase, frames, inner, step, crossing, crossFrom, steady = "settle", 0, nil, nil, nil, nil, 0

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
	-- The steps from (map, x, y) to the target, fewest maps first, or nil: each { exit, key, sides, spot }, `sides` the
	-- edge's side tiles that lead on, `spot` the tile a dive or surfacing starts from.
	local function route(fromMap, fx, fy)
		local startInfo = h.mapExits(fromMap)
		local parts = { { map = fromMap, info = startInfo, sx = fx, sy = fy, reached = flood(fromMap, startInfo, fx, fy,
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
				elseif there and e.kind == "fall" then
					if s.reached[e.y * w + e.x] then seeds[1] = { x = e.x, y = e.y } end
				elseif there and e.arrive and h.surfaceSpot then
					local best
					for key in pairs(s.reached) do
						local x, y = key % w, key // w
						local d = math.abs(x - s.sx) + math.abs(y - s.sy)
						if h.surfaceSpot(s.map, x, y) and (not best or d < best.d) then best = { x = x, y = y, d = d } end
					end
					if best then seeds[1] = { x = e.arrive.x, y = e.arrive.y, spot = { x = best.x, y = best.y } } end
				elseif there and (e.kind == "dive" or e.kind == "emerge") and h.deepWater then
					-- Dive: from deep water reached here onto the same tile below, where it is open; surfacing from a
					-- tile reached below onto deep water above.
					for key in pairs(s.reached) do
						local x, y = key % w, key // w
						local ok
						if e.kind == "dive" then ok = h.deepWater(s.map, x, y) and h.mapTile(e.to, x, y) ~= nil
						else ok = h.deepWater(e.to, x, y) end
						if ok then seeds[#seeds + 1] = { x = x, y = y, spot = { x = x, y = y }, dist = math.abs(x - s.sx) + math.abs(y - s.sy) } end
					end
					table.sort(seeds, function(a, b) return a.dist < b.dist end)
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
						parts[#parts + 1] = { map = e.to, info = there, reached = reached, prev = s, exit = e, key = key, sides = lead,
							spot = seed.spot, sx = seed.x, sy = seed.y }
					end
				end
			end
		end
		return nil
	end
	-- The side tile to leave from: of those leading on, the nearest whose route on the live grid crosses no trainer's
	-- line, else the nearest a route reaches at all.
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
		failed[step.key], setAside, phase, frames, steady = true, setAside + 1, "settle", 0, 0
		setAsideKeys[#setAsideKeys + 1] = step.key .. (why and (": " .. why) or "")
		if setAside > MAP_REPLANS then return finish("unreachable", { reason = "set aside " .. setAside .. " exits" }) end
		return nil, false
	end

	return function()
		frames = frames + 1
		local map, x, y = h.position()

		if phase == "settle" then
			if not (h.inOverworld() and h.atRest()) or (h.busy and h.busy()) or (h.locked and h.locked()) then
				steady = 0
				if frames > SETTLE_FRAMES then return finish("left_overworld") end
				return nil, false
			end
			-- STEADY_FRAMES at rest in a row first: after a fall through a crack the player reads at rest while the
			-- landing still plays, and a held direction does nothing.
			steady = steady + 1
			if steady < STEADY_FRAMES then return nil, false end
			if maps[#maps] ~= map then maps[#maps + 1] = map end
			local why
			-- On the target map, straight there only where a walk from here reaches it; a part of the map behind a warp
			-- that lands on this same map (warp pads) is planned as any other map is.
			local here = h.mapExits(map)
			if map == toMap and flood(map, here, x, y, h.playerElevation and h.playerElevation() or nil)[toY * here.width + toX] then
				inner, why = M.reach(h, { x = toX, y = toY, run = sub.run, cross_grass = sub.cross_grass })
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
			if e.kind == "warp" or e.kind == "fall" then
				tx, ty = e.x, e.y
			elseif e.kind == "dive" or e.kind == "emerge" then
				tx, ty = step.spot.x, step.spot.y
			else
				tx, ty = edgeTile(x, y)
				if not tx then return setAsideStep("no side tile a route reaches") end
			end
			inner = M.reach(h, { x = tx, y = ty, run = sub.run, cross_grass = sub.cross_grass })
			if not inner then return setAsideStep() end
			phase, frames = e.kind, 0
			return nil, false
		end

		if phase == "cross" then
			if map ~= crossFrom then
				phase, frames, steady = "settle", 0, 0
				return nil, false
			end
			if h.refused() or frames > L.door then return setAsideStep() end
			return { [crossing.button] = true }, false
		end

		-- The module's action at a dive spot, then planned again from where it lands.
		if phase == "act" then
			local pad, done, _, err = inner()
			if not done then return pad, false end
			if err then return setAsideStep(err) end
			phase, frames, steady = "settle", 0, 0
			return nil, false
		end

		local pad, done, r = inner()
		if not done then return pad, false end
		moved, turns, replans = moved + (r.moved or 0), turns + (r.turns or 0), replans + (r.replans or 0)
		if phase == "last" then return finish(r.outcome, r) end
		if (phase == "dive" or phase == "emerge") and r.outcome == "done" then
			local why
			inner, why = h.act(phase, {})
			if not inner then return setAsideStep(why) end
			phase, frames = "act", 0
			return nil, false
		end
		if r.outcome == "map_changed" then
			phase, frames, steady = "settle", 0, 0
			return nil, false
		end
		if phase == "edge" and r.outcome == "done" then
			phase, frames, crossing, crossFrom = "cross", 0, DIRECTIONS[step.exit.direction], map
			return nil, false
		end
		if r.outcome == "unreachable" or r.outcome == "blocked" or r.outcome == "no_response" or r.outcome == "done"
			or r.outcome == "off_plan" then
			return setAsideStep(r.outcome .. (r.reason and (", " .. r.reason) or ""))
		end
		return finish(r.outcome, r)
	end, nil, 36000
end

-- M.talk: to a tile beside a character by `M.go`'s route, facing it, a tapped A, then the module's text program
-- (`advance`) to its end. A character that walks about may have moved on arrival, so the route is planned again up to
-- TALK_TRIES times. The A is a tap (a held one goes on to answer the menu under it), again after TALK_WAIT frames.
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
			-- Beside it, or two tiles off with a tile A reaches across between (a counter).
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
			-- `unreachable` too: the tile beside a pacing character can close while walking.
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

-- M.search: a way to a tile found by trying steps in the game itself, for a map the plan cannot model (rotating gates,
-- whose rules live in the game's code). Breadth first over the player's tile and the module's optional `puzzleKey()`:
-- from each state kept with memorysavestate, each direction is held until the tile changes or the step is refused, then
-- the state is rewound. Found, the start is loaded again and the moves walked from it as ordinary input. Every rewind
-- shows on screen as a jump back. Not proven: try it before trusting it.
local SEARCH_NODES, SEARCH_STEP_FRAMES = 4000, 48
function M.search(h, p)
	local toX, toY = math.tointeger(p.x), math.tointeger(p.y)
	if not toX or not toY then return nil, "search needs x and y" end
	if not memorysavestate then return nil, "search needs memorysavestate" end
	local key = function(x, y) return x .. "," .. y .. "|" .. (h.puzzleKey and h.puzzleKey() or "") end
	local _, sx, sy = h.position()
	local root = memorysavestate.savecorestate()
	local seen, queue, qi, nodes = { [key(sx, sy)] = true }, { { id = root, x = sx, y = sy, path = {} } }, 1, 1
	local order = { "up", "down", "left", "right" }
	local node, di, frames, phase, found, replay, ri, total = nil, 0, 0, "next", nil, nil, 0, 0
	local function finish(outcome, extra)
		for i = qi, #queue do if queue[i].id ~= root then pcall(memorysavestate.removestate, queue[i].id) end end
		if node and node.id ~= root then pcall(memorysavestate.removestate, node.id) end
		pcall(memorysavestate.removestate, root)
		local r = { outcome = outcome, nodes = nodes, frames = total }
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end
	return function()
		total = total + 1
		if phase == "replay" then
			local _, x, y = h.position()
			if not h.inOverworld() then return finish("left_overworld", { path = found, walked = ri }) end
			if replay and (x ~= replay.x or y ~= replay.y) and h.atRest() then replay = nil end
			if not replay then
				ri = ri + 1
				if ri > #found then return finish("done", { path = found }) end
				replay = { x = x, y = y, frames = 0 }
			end
			replay.frames = replay.frames + 1
			if replay.frames > SEARCH_STEP_FRAMES * 2 then return finish("blocked", { path = found, walked = ri - 1 }) end
			return { [DIRECTIONS[found[ri]].button] = true }, false
		end
		if phase == "next" then
			if di == 0 or di >= #order then
				if node and node.id ~= root then memorysavestate.removestate(node.id) end
				node = queue[qi]
				if not node then return finish("unreachable", { reason = "every state reachable was tried" }) end
				qi, di = qi + 1, 0
				if nodes > SEARCH_NODES then return finish("unreachable", { reason = "more than " .. SEARCH_NODES .. " states" }) end
			end
			di = di + 1
			memorysavestate.loadcorestate(node.id)
			phase, frames = "step", 0
			return nil, false
		end
		-- phase "step"
		frames = frames + 1
		local _, x, y = h.position()
		local moved = (x ~= node.x or y ~= node.y)
		if (moved and h.atRest()) or frames > SEARCH_STEP_FRAMES or (not moved and frames > 8 and h.refused()) then
			phase = "next"
			if moved and h.inOverworld() then
				local k = key(x, y)
				if not seen[k] then
					seen[k], nodes = true, nodes + 1
					local path = {}
					for i, d in ipairs(node.path) do path[i] = d end
					path[#path + 1] = order[di]
					if x == toX and y == toY then
						found = path
						memorysavestate.loadcorestate(root)
						phase, ri, replay = "replay", 0, nil
						return nil, false
					end
					queue[#queue + 1] = { id = memorysavestate.savecorestate(), x = x, y = y, path = path }
				end
			end
			return nil, false
		end
		return { [DIRECTIONS[order[di]].button] = true }, false
	end, nil, 400000
end

return M
