-- Text and battles as one call, shared by the autoplay game modules (a dev tool, never shipped). This decides when
-- to press; everything a game measured comes from the module through the hooks below.
--
-- Hooks, per module (`h`):
--   signature()        -> string, dialogue   the state to watch for progress, and the message on screen or nil
--   readDialogue()     -> dialogue or nil    { box, state = "printing" | "waiting_for_button" | "finished" }
--   inBattle()         -> boolean
--   battleMenu()       -> asking, menu       "action" | "move" | "target" | nil, and { cursor, columns } for it
--   scriptRunning()    -> boolean            a script still has the controls (a cutscene, a trainer walking over)
--   inOverworld()      -> boolean
--   readMenu()         -> menu or nil        a menu outside a battle, for the caller's `select`
--   actionIndex        = { fight = n, run = n } the action menu's entries, cursor numbered row by row
--   optional:
--   boxKnownWhilePrinting = true             the dialogue's box is the whole box from its first letter (log it then)
--   levelUpPage()      -> page name or nil, and a value that changes when the page turns
--   inputReleased()    -> boolean            the game has seen every button let go
--   tapSeen()          -> boolean            the game has seen the A of a tap (a 2-frame tap can fall between looks)
--   animationPlaying() -> boolean            in a battle, the game is playing an animation by itself
--   effectiveTarget()  -> cursor             the battler to aim at on a double battle's target step
--   readKeyboard()     -> keyboard or nil    an on-screen keyboard (a naming screen): advance_text stops at it
--   readClock()        -> clock or nil       a clock screen (a new game's wall clock): advance_text stops at it
--   battleQuestion()   -> question or nil    a menu that is not the action or move menu: { kind, text, menu = { items,
--                                            cursor }, no = n }. `battle` answers the kinds it knows and stops
--                                            `needs_choice` on the rest, never nudging A on one. Asked in and out of a
--                                            battle's own screen; nil where none is up. A learn-a-move question carries
--                                            `options`, one per move with `name`, `type`, `power`, `accuracy` and
--                                            `same_type`, the move to learn last: kinds `learn_move` (the YES/NO),
--                                            `stop_learning` (the YES/NO after NO) and `forget_move` (the list)
--   scenePlaying()     -> boolean            a scene plays by itself and takes no button but the questions above and a
--                                            message's arrow, and it counts as change for up to SCENE_WAIT_FRAMES
--   strongestMove()    -> slot, label | nil, reason
--   effectiveMove()    -> slot, label, detail | nil, reason   the move weighed by type against the foe, and what each
--                                            move weighed, for the log
--   battleKind()       -> "wild" | "trainer"  the battle under way, for policy "run_wild"
--   endedReport()      -> table              what `battle` adds to `ended`
--   ownHp()            -> hp, max_hp         the player's battler in a battle (for `stop_hp_below`)
--   gameAnswers()      -> boolean            the game answers this battle's menus itself, so `battle` does not stop on
--                                            a menu then

local M = {}

-- The programs press only when a measured state asks: after NUDGE_FRAMES with no change they press A once, a press
-- that changes nothing is let go and tried again later (a message can ignore A through its jingle), and after NUDGES
-- of either without a change they finish `stuck` with what they last saw.
local NUDGE_FRAMES, NUDGES, QUIET_FRAMES, PRESS_FRAMES, LOG_MAX = 180, 3, 90, 30, 200
-- A on a message is a tap, and a message that ends with no arrow waits FINISHED_WAIT first: a held A goes on to
-- answer the menu that comes up as the text ends.
local TAP_FRAMES, FINISHED_WAIT, SCRIPT_WAIT_FRAMES, SCENE_WAIT_FRAMES = 2, 20, 600, 3600
M.QUIET_FRAMES = QUIET_FRAMES

-- A text-and-choices machine shared by both programs. `choose(asking)` returns the target cursor for a
-- battle menu, or nil to stop there; `stopWhen(state)` returns an outcome to finish with, or nil; `answer(question)`,
-- optional, returns the target cursor for a battle question (battleQuestion), or nil and a reason to stop there.
function M.machine(h, choose, stopWhen, answer)
	local log, lastBox, signature, still, nudges = {}, nil, nil, 0, 0
	local finishedBox, finishedFor = nil, 0
	local pressing, held, settle, battleSeen, frames = nil, 0, 0, false, 0
	local releasing, animating, scene = nil, 0, 0
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
		-- A box read off the screen fills letter by letter, so it is logged once printed.
		if d and d.box ~= "" and d.box ~= lastBox and (h.boxKnownWhilePrinting or d.state ~= "printing") then
			lastBox = d.box
			note({ text = d.box })
		end
		local battle = h.inBattle()
		battleSeen = battleSeen or battle
		-- An animation playing is the game's own progress, for as long as a script is waited out: a nudge inside one
		-- changes nothing.
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

		if pressing then
			if pressing.done() then
				pressing, held, settle = nil, 0, 2
				if h.inputReleased then releasing = 0 end
				return nil, false
			end
			held = held + 1
			-- A tap lets go after TAP_FRAMES, and where the module can tell, not before the game has seen it; then
			-- it waits for its answer with nothing held.
			if pressing.tap and held > TAP_FRAMES and held <= PRESS_FRAMES then
				if not h.tapSeen or pressing.seen or h.tapSeen() then
					pressing.seen = true
					return nil, false
				end
			end
			if held > PRESS_FRAMES then
				-- Unanswered: let go and look again later, stuck only after NUDGES of these and NUDGE_FRAMES with
				-- nothing changing, since an answered press can take longer than PRESS_FRAMES to show.
				local what = pressing.what
				pressing, held, nudges, settle = nil, 0, nudges + 1, NUDGE_FRAMES // 2
				if nudges > NUDGES and still >= NUDGE_FRAMES then
					return finish("stuck", { waiting_on = what, signature = sig })
				end
				return nil, false
			end
			return pressing.pad, false
		end

		local asking, menu = nil, nil
		if battle then asking, menu = h.battleMenu() end
		-- A double battle's target step: Right steps the cursor through every battler, the player's own too.
		if asking == "target" then
			local aim = h.effectiveTarget and h.effectiveTarget() or menu.cursor
			if menu.cursor ~= aim then
				local from = menu.cursor
				pressing = { what = "target cursor Right", pad = { Right = true },
					done = function()
						local a, m = h.battleMenu()
						return a ~= "target" or not m or m.cursor ~= from
					end }
				return pressing.pad, false
			end
			note({ chose = "target " .. tostring(aim), from = asking })
			pressing = { what = "confirm target", pad = { A = true }, done = function() return (h.battleMenu()) ~= "target" end }
			return pressing.pad, false
		end
		if asking then
			local target, label, detail = choose(asking)
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
			local entry = { chose = label, from = asking }
			for k, v in pairs(detail or {}) do entry[k] = v end
			note(entry)
			pressing = { what = "confirm " .. label, pad = { A = true },
				done = function() return (h.battleMenu()) ~= asking end }
			return pressing.pad, false
		end

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

		-- A question: answered when `answer` knows its kind, else it stops there, since a nudge would choose.
		local question = h.battleQuestion and h.battleQuestion() or nil
		if question then
			local target, label, detail
			if answer then target, label, detail = answer(question) end
			if target == nil then
				return finish("needs_choice", { question = question, reason = label or "a question this program does not answer" })
			end
			local from = question.menu.cursor
			if from ~= target then
				local dir = (target > from) and "Down" or "Up"
				pressing = { what = "question cursor " .. dir, pad = { [dir] = true },
					done = function()
						local q = h.battleQuestion()
						return not q or q.menu.cursor ~= from
					end }
				return pressing.pad, false
			end
			local entry = { chose = label, question = question.text or question.kind }
			for k, v in pairs(detail or {}) do entry[k] = v end
			note(entry)
			pressing = { what = "answer " .. label, pad = { A = true }, done = function() return h.battleQuestion() == nil end }
			return pressing.pad, false
		end

		-- A scene playing by itself: nothing is pressed but a message's arrow, and it is change for SCENE_WAIT_FRAMES.
		if h.scenePlaying and h.scenePlaying() and not (d and d.state == "waiting_for_button") then
			scene = scene + 1
			if scene <= SCENE_WAIT_FRAMES then
				still = 0
				return nil, false
			end
		else
			scene = 0
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

		-- Nothing asked for: nudge if it stays still, but only in a battle or with a message known to be up. Anywhere
		-- else an A is a choice on a screen nobody read.
		if still >= NUDGE_FRAMES then
			-- A script still running with nothing to read is waited out longer (a character walking off).
			local scriptOn = h.scriptRunning()
			if not battle and not d and scriptOn and still < SCRIPT_WAIT_FRAMES then
				return nil, false
			end
			-- With no script running in the overworld, the program's own quiet count ends it, not a stuck.
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

-- The forget policy "strong_variety": a variety of strong moves of different types. Of the four known moves and the one
-- to learn, the one left out costs least, a set of four being worth, per type, its strongest move's score in full and
-- every other a quarter (score: power x accuracy / 100, x1.5 for the Pokémon's own type). Status moves score 0 and go
-- first; a tie keeps what is known, then leaves out the lower score. Returns the index (1-5) left out, and the weights.
function M.forgetChoice(options)
	local function score(o)
		return (o.power or 0) * (o.accuracy or 0) / 100 * (o.same_type and 1.5 or 1)
	end
	local function worth(without)
		local best, rest = {}, 0
		for i, o in ipairs(options) do
			if i ~= without then
				local s, t = score(o), o.type or "?"
				if not best[t] then
					best[t] = s
				elseif s > best[t] then
					rest, best[t] = rest + best[t] / 4, s
				else
					rest = rest + s / 4
				end
			end
		end
		for _, s in pairs(best) do rest = rest + s end
		return rest
	end
	local out, weighed = #options, {}
	for i, o in ipairs(options) do
		weighed[i] = { move = o.name, type = o.type, power = o.power, accuracy = o.accuracy, same_type = o.same_type or nil,
			score = score(o), kept_worth = worth(i) }
	end
	for i = #options - 1, 1, -1 do
		local w, best = weighed[i].kept_worth, weighed[out].kept_worth
		if w > best or (w == best and out ~= #options and weighed[i].score < weighed[out].score) then out = i end
	end
	return out, weighed
end

-- battle {policy = "strongest" | "effective" | "run" | "run_wild" | "manual", forget, switch, stop_hp_below}: a battle
-- to its end, a trainer's words included. "strongest" and "effective" fight with the module's strongestMove() or
-- effectiveMove(); "run" runs and stops on the move menu; "run_wild" runs from a wild battle and fights a trainer's
-- (which cannot be run from) as "effective"; "manual" stops `needs_choice` at every action or move menu. `forget`
-- "strong_variety" answers a learn-a-move question, else it stops there. `stop_hp_below` (above 0, at most 1) stops at
-- the action menu below that share of HP, so the caller can heal through the BAG and call `battle` again.
function M.battle(h, p)
	local policy = p.policy or "strongest"
	if policy ~= "strongest" and policy ~= "effective" and policy ~= "run" and policy ~= "run_wild" and policy ~= "manual" then
		return nil, 'battle policy is "strongest", "effective", "run", "run_wild" or "manual"'
	end
	if p.switch ~= nil and p.switch ~= "ask" then return nil, 'battle switch is "ask" or absent' end
	if p.forget ~= nil and p.forget ~= "strong_variety" then
		return nil, 'battle forget is "strong_variety" or absent'
	end
	local stopBelow = tonumber(p.stop_hp_below)
	if p.stop_hp_below ~= nil and (not stopBelow or stopBelow <= 0 or stopBelow > 1) then
		return nil, "battle stop_hp_below is a share of HP above 0, at most 1"
	end
	if stopBelow and not h.ownHp then
		return nil, "battle stop_hp_below needs the player's HP, which this game module does not read"
	end
	-- What the last learn-a-move question left out, so "stop learning?" is answered to match.
	local decided = nil
	if policy == "strongest" and not h.strongestMove then
		return nil, 'battle policy "strongest" needs move data this game module has not measured; use "run"'
	end
	if policy == "effective" and not h.effectiveMove then
		return nil, 'battle policy "effective" needs a type chart this game module has not measured; use "strongest" or "run"'
	end
	if policy == "run_wild" and not (h.battleKind and h.effectiveMove) then
		return nil, 'battle policy "run_wild" needs the battle kind and a type chart, which this game module does not read'
	end
	-- A RUN answered by the action menu again, the battle still on, was refused (a trapping ability): `run_wild` then
	-- fights that battle as "effective", and "run" stops.
	local ranOnce, refused = false, false
	local function running() return not refused and (policy == "run" or (policy == "run_wild" and h.battleKind() == "wild")) end
	local outside = 0
	local machine = M.machine(h, function(asking)
		-- "manual": every action menu is the caller's (a ball thrown before the foe's first turn).
		if policy == "manual" then return nil, "policy manual: the caller chooses at " .. asking end
		if asking == "action" then
			if stopBelow then
				local hp, max = h.ownHp()
				if hp and max and max > 0 and hp / max < stopBelow then
					return nil, string.format("HP %d of %d is below stop_hp_below", hp, max)
				end
			end
			if running() and ranOnce then
				refused = true
				if policy == "run" then return nil, "RUN was refused: the action menu came back" end
			end
			if running() then
				ranOnce = true
				return h.actionIndex.run, "RUN"
			end
			if refused then return h.actionIndex.fight, "FIGHT (RUN was refused)" end
			return h.actionIndex.fight, "FIGHT"
		end
		if running() then return nil, "on the move menu with policy " .. policy end
		if policy == "effective" or policy == "run_wild" then return h.effectiveMove() end
		return h.strongestMove()
	end, function(st)
		if st.battle then
			outside = 0
			return nil
		end
		-- A menu outside the battle (a nickname's YES/NO) is the caller's, unless the game is answering it itself.
		local menu = h.readMenu()
		if menu and not (h.gameAnswers and h.gameAnswers()) then return "menu_open", { menu = menu } end
		if menu then
			outside = 0
			return nil
		end
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
	end, function(question)
		-- The Pokémon that is in stays, unless `switch` "ask" hands the free switch after a faint (it costs no turn) to
		-- the caller.
		if question.kind == "switch" and p.switch == "ask" then return nil, "the free switch: the caller chooses" end
		if question.kind == "switch" and question.no then return question.no, "NO" end
		local learning = question.kind == "learn_move" or question.kind == "forget_move" or question.kind == "stop_learning"
		if learning and not p.forget then
			return nil, "a learn-a-move question, and no forget policy was given"
		end
		if (question.kind == "learn_move" or question.kind == "forget_move") and question.options then
			local out, weighed = M.forgetChoice(question.options)
			local learnIt = out ~= #question.options
			decided = question.options[out].name
			local detail = { forget = decided, weighed = weighed }
			if question.kind == "learn_move" then
				if learnIt then return 0, "YES", detail end
				return question.no, "NO", detail
			end
			return out - 1, question.menu.items[out], detail
		end
		-- "Stop learning X?" follows NO, or the list left with the new move itself: YES when that is what was decided.
		if question.kind == "stop_learning" and decided and question.options and decided == question.options[#question.options].name then
			return 0, "YES"
		end
		return nil, "a question this policy does not answer: " .. tostring(question.kind)
	end)
	return machine, nil, 36000
end

-- advance_text: presses through the message on screen, box by box, and stops when it closes and stays
-- closed, when a menu opens (answer it with select), or when a battle begins (hand it to battle).
function M.advanceText(h)
	local closed = 0
	local machine = M.machine(h, function() return nil, "a battle began" end, function(st)
		if st.battle then return "battle_started" end
		-- A keyboard is answered with type_text, never an A.
		local kb = h.readKeyboard and h.readKeyboard()
		if kb then return "keyboard_open", { keyboard = kb } end
		-- A clock is set with set_clock, not waited out as a running script.
		local clock = h.readClock and h.readClock()
		if clock then return "clock_open", { clock = clock } end
		local m = h.readMenu()
		if m then return "menu_open", { menu = m } end
		-- A script still running is not the end (a cutscene walks the player on after its first message).
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
