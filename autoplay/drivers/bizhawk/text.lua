-- autoplay BizHawk driver: text and battles as one call, shared by the game modules (DEV TOOL, never shipped).
--
-- Moved out of games/emerald.lua on 2026-09-17 so a second game gets `advance_text` and `battle` without a copy
-- (the user: "do this now while this is the only active chat"). What is in here decides WHEN to press; everything a
-- game measured -- what the message on screen is, whether a battle menu waits, where its cursor is, whether a
-- script still runs -- comes from the module through the hooks below, and each module's comments name the
-- measurements. The driver loads this file and hands it to each game module (`local lib = ...`).
--
-- HOOKS, per module (`h`):
--   signature()        -> string, dialogue   the state to watch for progress, and the message on screen or nil
--   readDialogue()     -> dialogue or nil    { box, state = "printing" | "waiting_for_button" | "finished" }
--   inBattle()         -> boolean
--   battleMenu()       -> asking, menu       "action" | "move" | nil, and { cursor, columns } for it
--   scriptRunning()    -> boolean            a script still has the controls (a cutscene, a trainer walking over)
--   inOverworld()      -> boolean
--   readMenu()         -> menu or nil        a menu outside a battle, for the caller's `select`
--   actionIndex        = { fight = n, run = n } the action menu's entries, cursor numbered row by row
--   optional:
--   boxKnownWhilePrinting = true             the dialogue's box is the whole box from its first letter (log it then)
--   levelUpPage()      -> page name or nil, and a value that changes when the page turns (Emerald's level-up box)
--   inputReleased()    -> boolean            the game has seen every button let go (Crystal's menus look every few
--                                            frames, and a short release between presses was never seen)
--   tapSeen()          -> boolean            the game has seen the A of a tap (a 2-frame tap can fall between looks)
--   animationPlaying() -> boolean            in a battle, the game is playing an animation by itself (Emerald's STRING
--                                            SHOT ran 228 frames with nothing else changing)
--   readKeyboard()     -> keyboard or nil    an on-screen keyboard (a naming screen): advance_text stops at it
--   strongestMove()    -> slot, label | nil, reason
--   endedReport()      -> table              what `battle` adds to `ended`

local M = {}

-- TEXT AND BATTLES AS ONE CALL (2026-09-16, Emerald). A loop driven from outside took several round trips a
-- step, waited fixed times and ran out its budget in silence when it met a state it did not handle (the
-- user: "so i don't sit around waiting for several minutes"). These run in the driver a frame at a time,
-- press only when a measured state asks for it, keep a `log` of every message and choice, and stop
-- within seconds once nothing changes: after NUDGE_FRAMES with no change they press A once (a message
-- in a printer state not yet measured, like the 1 a trainer's last words read), a press that changes
-- nothing is let go and tried again later (the nurse's "for a few seconds" ignored A through its jingle),
-- and after NUDGES of either without a change they finish `stuck` with what they last saw.
local NUDGE_FRAMES, NUDGES, QUIET_FRAMES, PRESS_FRAMES, LOG_MAX = 180, 3, 90, 30, 200
-- A on a message is a TAP, and a message that ends with no arrow waits FINISHED_WAIT frames first: an A held
-- until the message changed went on to answer the menu that came up as the text ended -- Birch's "Are you a
-- boy? Or are you a girl?" and "So it's A?" were both answered with their first entry (2026-09-17).
local TAP_FRAMES, FINISHED_WAIT, SCRIPT_WAIT_FRAMES = 2, 20, 600
M.QUIET_FRAMES = QUIET_FRAMES

-- A text-and-choices machine shared by both programs. `choose(asking)` returns the target cursor for a
-- battle menu, or nil to stop there; `stopWhen(state)` returns an outcome to finish with, or nil.
function M.machine(h, choose, stopWhen)
	local log, lastBox, signature, still, nudges = {}, nil, nil, 0, 0
	local finishedBox, finishedFor = nil, 0
	local pressing, held, settle, battleSeen, frames = nil, 0, 0, false, 0
	local releasing, animating = nil, 0
	local function note(entry)
		if #log < LOG_MAX then log[#log + 1] = entry end
	end
	local function finish(outcome, extra)
		local r = { outcome = outcome, log = log, frames = frames }
		for k, v in pairs(extra or {}) do r[k] = v end
		return nil, true, r
	end
	return function()
		frames = frames + 1
		local sig, d = h.signature()
		if sig ~= signature then
			signature, still, nudges = sig, 0, 0
		else
			still = still + 1
		end
		-- A module reading the screen sees a box fill letter by letter; it is logged once printed. Emerald knows each
		-- whole box from the moment it starts (boxKnownWhilePrinting).
		if d and d.box ~= "" and d.box ~= lastBox and (h.boxKnownWhilePrinting or d.state ~= "printing") then
			lastBox = d.box
			note({ text = d.box })
		end
		local battle = h.inBattle()
		battleSeen = battleSeen or battle
		-- A battle animation the module says is playing is the game's own progress, for as long as a script is waited
		-- out: after "Foe WURMPLE used STRING SHOT!" its animation ran 228 frames with nothing in the signature changing,
		-- every nudge landed inside it and changed nothing, and the next message came when it ended; a nudge held back
		-- only until it ended fired on the frame after (2026-09-17).
		if battle and h.animationPlaying and h.animationPlaying() then
			animating = animating + 1
			if animating <= SCRIPT_WAIT_FRAMES then still = 0 end
		else
			animating = 0
		end

		local stop, extra = stopWhen({ battle = battle, battleSeen = battleSeen, dialogue = d })
		if stop then return finish(stop, extra) end

		-- After a press, a game that says so has to see the release before the next one counts.
		if releasing then
			releasing = releasing + 1
			if not h.inputReleased() and releasing <= PRESS_FRAMES then return nil, false end
			releasing = nil
		end
		if settle > 0 then
			settle = settle - 1
			return nil, false
		end

		-- A press under way: hold it until the thing it was for changes.
		if pressing then
			if pressing.done() then
				pressing, held, settle = nil, 0, 2
				if h.inputReleased then releasing = 0 end
				return nil, false
			end
			held = held + 1
			-- A tap lets go after TAP_FRAMES -- or, where the module can tell, once the game has seen it -- and
			-- waits for its answer with nothing held.
			if pressing.tap and held > TAP_FRAMES and held <= PRESS_FRAMES then
				if not h.tapSeen or pressing.seen or h.tapSeen() then
					pressing.seen = true
					return nil, false
				end
			end
			if held > PRESS_FRAMES then
				-- Unanswered (a message that waits out a jingle ignores A): let go, look again later, and
				-- call it stuck only after NUDGES of these AND NUDGE_FRAMES with nothing changing -- an
				-- answered press can take longer than PRESS_FRAMES to show (the level-up box's last A: the
				-- next message printed 156 frames later).
				local what = pressing.what
				pressing, held, nudges, settle = nil, 0, nudges + 1, NUDGE_FRAMES // 2
				if nudges > NUDGES and still >= NUDGE_FRAMES then
					return finish("stuck", { waiting_on = what, signature = sig })
				end
				return nil, false
			end
			return pressing.pad, false
		end

		-- A battle menu waiting: move its cursor to the choice, then confirm.
		local asking, menu = nil, nil
		if battle then asking, menu = h.battleMenu() end
		if asking then
			local target, label = choose(asking)
			if target == nil then return finish("needs_choice", { asking = asking, reason = label }) end
			local cursor, cols = menu.cursor, menu.columns or 1
			if cursor ~= target then
				-- A grid is numbered row by row: reach the column first, then the row.
				local dir
				if cols > 1 and target % cols ~= cursor % cols then
					dir = (target % cols > cursor % cols) and "Right" or "Left"
				else
					dir = (target > cursor) and "Down" or "Up"
				end
				local from = cursor
				pressing = { what = asking .. " cursor " .. dir, pad = { [dir] = true },
					done = function()
						local a, m = h.battleMenu()
						return a ~= asking or not m or m.cursor ~= from
					end }
				return pressing.pad, false
			end
			note({ chose = label, from = asking })
			pressing = { what = "confirm " .. label, pad = { A = true },
				done = function() return (h.battleMenu()) ~= asking end }
			return pressing.pad, false
		end

		-- The level-up box waiting on one of its pages.
		local page, at = nil, nil
		if battle and h.levelUpPage then page, at = h.levelUpPage() end
		if page then
			note({ level_up_box = page })
			pressing = { what = "the level-up box, " .. page, pad = { A = true }, tap = true,
				done = function()
					local _, now = h.levelUpPage()
					return now ~= at
				end }
			return pressing.pad, false
		end

		-- A message waiting for a button. In a battle only the arrow counts: a battle message window reads
		-- "finished" while animations play.
		if d and not battle and d.state == "finished" then
			if finishedBox ~= d.box then finishedBox, finishedFor = d.box, 0 end
			finishedFor = finishedFor + 1
		else
			finishedBox, finishedFor = nil, 0
		end
		if d then
			local waiting = d.state == "waiting_for_button" or (not battle and d.state == "finished" and finishedFor > FINISHED_WAIT)
			if waiting then
				local box, state = d.box, d.state
				pressing = { what = "a message: " .. box, pad = { A = true }, tap = true,
					done = function()
						local now = h.readDialogue()
						return not now or now.box ~= box or now.state ~= state
					end }
				return pressing.pad, false
			end
		end

		-- Nothing asked for: let the game run, nudging if it stays still -- but only in a battle or with a message
		-- known to be up. Anywhere else an A is a choice on a screen nobody read: on 2026-09-17 nudges picked the
		-- starter on Birch's bag screen, answered YES to a nickname, and typed "AA" on the naming keyboard.
		if still >= NUDGE_FRAMES then
			-- A script still running with nothing to read is waited out longer: MAY walked off after her last words
			-- for more than NUDGE_FRAMES with nothing here changing, and the script then ended by itself.
			local scriptOn = h.scriptRunning()
			if not battle and not d and scriptOn and still < SCRIPT_WAIT_FRAMES then
				return nil, false
			end
			-- With no script running in the overworld, the program's own quiet count ends it: MAY's script went off
			-- 1044 frames after the battle, and a stuck answered here 31 frames later had pre-empted `ended`.
			if not battle and not d and not scriptOn and h.inOverworld() then
				return nil, false
			end
			if not battle and not d then
				return finish("stuck", { waiting_on = "nothing changed and no message or menu is known to be up (a screen observe does not read?)",
					signature = sig })
			end
			if nudges >= NUDGES then
				return finish("stuck", { waiting_on = "no change after " .. nudges .. " A presses", signature = sig,
					dialogue = d })
			end
			nudges, still = nudges + 1, 0
			note({ nudged = sig })
			local before = sig
			pressing = { what = "a nudge", pad = { A = true }, tap = true, done = function() return (h.signature()) ~= before end }
			return pressing.pad, false
		end
		return nil, false
	end
end

-- battle {policy = "strongest" | "run"}: plays a battle to its end, a trainer's words before and after
-- included. "strongest" chooses FIGHT and the move the module's strongestMove() names; "run" chooses RUN and,
-- on the move menu, stops. Returns (program, error, frame limit) like any program.
function M.battle(h, p)
	local policy = p.policy or "strongest"
	if policy ~= "strongest" and policy ~= "run" then return nil, 'battle policy is "strongest" or "run"' end
	if policy == "strongest" and not h.strongestMove then
		return nil, 'battle policy "strongest" needs move data this game module has not measured; use "run"'
	end
	local outside = 0
	local machine = M.machine(h, function(asking)
		if asking == "action" then
			if policy == "run" then return h.actionIndex.run, "RUN" end
			return h.actionIndex.fight, "FIGHT"
		end
		if policy == "run" then return nil, "on the move menu with policy run" end
		return h.strongestMove()
	end, function(st)
		if st.battle then
			outside = 0
			return nil
		end
		-- A menu outside the battle is the caller's to answer (Birch's nickname YES/NO after the rescue battle).
		local menu = h.readMenu()
		if menu then return "menu_open", { menu = menu } end
		-- A script still running (a trainer walking over before its words, its words after) is not the end.
		if st.dialogue ~= nil or h.scriptRunning() then
			outside = 0
			return nil
		end
		outside = outside + 1
		if outside >= QUIET_FRAMES and h.inOverworld() then
			if st.battleSeen then return "ended", h.endedReport and h.endedReport() or nil end
			return "no_battle"
		end
		return nil
	end)
	return machine, nil, 36000
end

-- advance_text: presses through the message on screen, box by box, and stops when it closes and stays
-- closed, when a menu opens (answer it with select), or when a battle begins (hand it to battle).
function M.advanceText(h)
	local closed = 0
	local machine = M.machine(h, function() return nil, "a battle began" end, function(st)
		if st.battle then return "battle_started" end
		-- A keyboard is answered with type_text, never an A: a nudge once typed "AA" on Emerald's (2026-09-17).
		local kb = h.readKeyboard and h.readKeyboard()
		if kb then return "keyboard_open", { keyboard = kb } end
		local m = h.readMenu()
		if m then return "menu_open", { menu = m } end
		-- A script still running is not the end: Route 101's cutscene walked the player on after its first
		-- message, and advance_text had called it closed (2026-09-17).
		if st.dialogue or h.scriptRunning() then
			closed = 0
			return nil
		end
		closed = closed + 1
		if closed >= QUIET_FRAMES then return "closed" end
		return nil
	end)
	return machine, nil, 7200
end

return M
