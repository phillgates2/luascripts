-- Regression tests for the two things reported broken on the live server:
--
--   1. "/kill in a fire fight still kills me"      (no_combat_selfkill)
--   2. "throwing the knife does nothing"           (throwable_knife)
--
-- Neither bug was reachable from the older specs, and both were hidden by the
-- test harness rather than by the module:
--
--   * tests/gameplay_spec.lua loaded game/gameplay.lua on its own. On a real
--     server main.lua requires commands.commands (line 138) *before*
--     game.gameplay (line 143), so commands.onClientCommand() is handler #1 on
--     the bus - and it ends in an unconditional `return 0`
--     (commands/commands.lua:349). events.trigger() used to keep the first
--     non-nil answer, so that 0 was what et_ClientCommand() handed back to the
--     engine and Cmd_Kill_f() ran no matter what game/gameplay.lua returned.
--     These tests register the same handler, in the same order.
--
--   * tests/et_stub.lua invented et.G_Spawn(), which does not exist in
--     ET:Legacy's Lua API (g_lua.c's etlib[] table has no such entry), and its
--     et.trap_Trace() answered "hit nothing" to every call. A knife built on
--     G_Spawn() therefore "worked" in the tests and did nothing at all on the
--     server, where the call raised and the pcall swallowed it.
--
-- The stub now models et.G_CreateEntity()/et.G_ModelIndex()/et.G_FreeEntity()
-- and a real sweep trace, so these tests fail on the old module and pass on the
-- fixed one.
--
-- Run with:   lua tests/knife_kill_spec.lua [--verbose]
-- Exit code:  0 when everything passes, 1 otherwise.

local HERE = (...) and debug.getinfo(1, "S").source:match("@(.*/)") or "./tests/"
if HERE == "" then HERE = "./tests/" end
local ROOT = HERE .. "../"

local stub = dofile(HERE .. "et_stub.lua")

local VERBOSE = arg and arg[1] == "--verbose"

-- ------------------------------- harness ---------------------------------

local failures, checks = {}, 0
local current_test

local function check(cond, what)
	checks = checks + 1
	if not cond then
		failures[#failures + 1] = (current_test or "?") .. ": " .. what
		print("  FAIL " .. what)
	elseif VERBOSE then
		print("  ok   " .. what)
	end
end

local function test(name, fn)
	current_test = name
	print("== " .. name)
	fn()
	current_test = nil
end

-- equality with a tolerance, for positions that come out of the trajectory math
local function near(value, want, tol)
	return type(value) == "number" and math.abs(value - want) <= (tol or 0.5)
end

-- load a module of the tree the way main.lua's wolfa_requireModule() does
local cache = {}
function wolfa_requireModule(name)
	if cache[name] then return cache[name] end
	local chunk = assert(loadfile(ROOT .. name:gsub("%.", "/") .. ".lua"))
	local result = chunk()
	cache[name] = result or true
	return result
end

-- A server with WolfAdmin's own command handler registered first, exactly like
-- main.lua does it. commands/commands.lua itself cannot be loaded here (it
-- needs wolfa_requireLib("toml") from the engine's lua lib path, the admin
-- settings files and a sqlite database), so stub.wolfadmin_client_command()
-- stands in for the one behaviour that matters: it answers 0 for every command
-- it does not own, "kill" included.
local function new_server(opts)
	cache = {}
	local engine = stub.new(opts)
	engine.install()
	local events = wolfa_requireModule("util.events")
	events.handle("onClientCommand", stub.wolfadmin_client_command(engine))
	wolfa_requireModule("game.gameplay")
	events.trigger("onGameInit", 0, 0, false)
	return engine, events
end

local function client_command(engine, events, num, command)
	engine.parse_command(command)
	return events.trigger("onClientCommand", num, command)
end

-- centre prints the module sent to one client
local function cp_text(engine, num)
	local out = {}
	for _, c in ipairs(engine.commands) do
		if c.num == num or c.num == -1 then out[#out + 1] = c.cmd end
	end
	return table.concat(out, "\n")
end

local function count_damage(engine, target, damage)
	local n = 0
	for _, d in ipairs(engine.damage) do
		if d.target == target and (damage == nil or d.damage == damage) then n = n + 1 end
	end
	return n
end

-- The entity the module was supposed to create. A regression that creates
-- nothing must still print the whole report, so this hands back an empty table
-- and records the failure rather than indexing nil.
local function gent(engine, num, what)
	local e = num and engine.ents[num]
	if not e then
		check(false, what or "the entity the throw created exists")
		-- shaped like an entity so the assertions below report as failures
		return {
			origin = {}, classname = "", inuse = 0, clipmask = 0,
			s = {
				pos = { trBase = {}, trDelta = {} },
				apos = { trBase = {}, trDelta = {} },
				angles = {},
			},
			r = { currentOrigin = {}, mins = {}, maxs = {} },
		}
	end
	return e
end

-- entities the module created and has not freed again: a thrown knife is the
-- only thing in these tests that uses an entity slot
local function live_knives(engine)
	local n, ents = 0, {}
	for num, e in pairs(engine.ents) do
		if e.inuse == 1 and e.classname == "target_position" then
			n = n + 1
			ents[#ents + 1] = num
		end
	end
	return n, ents
end

local TEAM_AXIS, TEAM_ALLIES = 1, 2
local PC_SOLDIER, PC_MEDIC = 0, 1
local WP_KNIFE, WP_KNIFE_KABAR = 1, 48
local WP_MP40, WP_THOMPSON = 3, 8
local MOD_SYRINGE = 24

-- config values from game/gameplay.lua that the assertions below depend on
local COMBAT_WINDOW_MS   = 5000
local STUCK_GRACE_MS     = 8000
local SIGHT_RANGE        = 2000
local KNIFE_CLIP_MAX     = 5
local THROW_SPEED        = 1400
local THROW_UP           = 40
local THROW_DAMAGE       = 45
local THROW_DAMAGE_HEAD  = 100
local THROW_COOLDOWN_MS  = 800
local KNIFE_LIFETIME_MS  = 30000
local KNIFE_PICKUP_RANGE = 48
local KNIFE_MAX_LIVE     = 12
local KNIFE_SPIN         = 720
-- engine values the Lua API does not expose (q_shared.h / bg_misc.c)
local ET_GENERAL, TR_STATIONARY, TR_LINEAR, TR_GRAVITY = 0, 0, 2, 6
local GRAVITY = 800                 -- DEFAULT_GRAVITY, fixed in BG_EvaluateTrajectory
local MOD_KNIFE, MOD_KNIFE_KABAR = 5, 61

-- connect + spawn a player and put them somewhere in the world
local function player(engine, events, num, team, class, origin, viewangles)
	engine.connect(num, team, class)
	engine.spawn(num)
	events.trigger("onPlayerSpawn", num, false)
	engine.place(num, origin or { 0, 0, 0 }, viewangles or { 0, 0, 0 })
	return engine.client(num)
end

-- run frames, moving the clock the way et_RunFrame() does
local function frames(events, from, to, step)
	step = step or 50
	for t = from, to, step do events.trigger("onGameFrame", t) end
end

-- throw once and return what the engine was asked to create
local function throw(engine, events, num, weapon, levelTime)
	events.trigger("onGameFrame", levelTime)
	local before = #engine.gent_create_log
	local ret = events.trigger("onWeaponFire", num, weapon)
	local created = #engine.gent_create_log > before
		and engine.gent_create_log[#engine.gent_create_log].number or nil
	return ret, created
end

-- --------------------------------- tests ---------------------------------

-- /kill during a fire fight: the combat window opens on damage between enemies
-- and closes COMBAT_WINDOW_MS later. This is the report from the server, and it
-- needs WolfAdmin's own handler on the bus to reproduce at all.
test("/kill is refused while in combat", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	-- far apart, so the "an enemy can see you" rule cannot be what blocks it
	local axis = player(engine, events, 3, TEAM_AXIS, PC_SOLDIER, { 0, 0, 0 })
	player(engine, events, 5, TEAM_ALLIES, PC_SOLDIER, { 5000, 0, 0 })

	events.trigger("onGameFrame", 1000)
	events.trigger("onGameFrame", 2000)

	check(client_command(engine, events, 3, "kill") == 0,
		"/kill outside combat is passed on to the engine")
	check(#engine.commands == 0, "and it is passed on without a centre print")

	-- a hit from an enemy opens the window (onDamage: target, attacker, ...)
	events.trigger("onDamage", 3, 5, 20, 0, 8)

	check(client_command(engine, events, 3, "kill") == 1,
		"/kill during the combat window is intercepted")
	check(cp_text(engine, 3):find("in a fire fight", 1, true) ~= nil,
		"the player is told why")
	check(cp_text(engine, 3):find("wait 5 seconds", 1, true) ~= nil,
		"and how long is left")
	check(axis.ps.stats[0] == 100, "no damage was dealt by the refused /kill")

	-- both players are marked, not just the one that was hit
	check(client_command(engine, events, 5, "kill") == 1,
		"the attacker is in the combat window too")

	-- the window closes again (still_since is only 5s old, so the stuck rule
	-- cannot be what lets this one through)
	frames(events, 3000, 7000, 1000)
	check(client_command(engine, events, 3, "kill") == 0,
		"/kill works again " .. COMBAT_WINDOW_MS .. "ms after the last hit")

	-- "suicide" is the same command under another name
	events.trigger("onDamage", 3, 5, 20, 0, 8)
	check(client_command(engine, events, 3, "suicide") == 1,
		"the suicide alias is intercepted too")
	check(client_command(engine, events, 3, "KILL") == 1,
		"and the command is matched case-insensitively")

	-- a spectator and a dead player are not in a fire fight
	events.trigger("onDamage", 3, 5, 20, 0, 8)
	engine.health(3, 0)
	check(client_command(engine, events, 3, "kill") == 0,
		"a dead player may always /kill")
	engine.health(3, 100)
	engine.connect(9, 3, PC_SOLDIER)          -- TEAM_SPECTATOR
	events.trigger("onClientBegin", 9)
	check(client_command(engine, events, 9, "kill") == 0,
		"a spectator may always /kill")

	-- an unrelated command is never touched
	check(client_command(engine, events, 3, "reload") == 0,
		"other commands are still passed on to the engine")
	check(#engine.gent_create_log == 0, "no entities were created by any of this")
end)

-- The second half of the rule: an enemy who can see you keeps /kill locked even
-- without a recent hit. Sight is range + cone + line of sight, and the line of
-- sight is a real trace now.
test("/kill is refused while an enemy can see you", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	-- the watcher looks down +x at the player who wants to /kill
	player(engine, events, 5, TEAM_ALLIES, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	player(engine, events, 3, TEAM_AXIS, PC_SOLDIER, { 400, 0, 0 }, { 0, 180, 0 })
	events.trigger("onGameFrame", 1000)

	check(client_command(engine, events, 3, "kill") == 1,
		"/kill is refused while an enemy has line of sight")
	check(cp_text(engine, 3):find("while an enemy can see you", 1, true) ~= nil,
		"the player is told an enemy can see them")

	-- a wall between them: same range, same cone, no sight
	stub.add_wall(engine, { 100, -500, -200 }, { 120, 500, 300 })
	engine.commands = {}
	check(client_command(engine, events, 3, "kill") == 0,
		"cover breaks the line of sight and /kill works again")

	-- out of range again (SIGHT_RANGE = 2000)
	engine.world = {}
	engine.place(3, { SIGHT_RANGE + 500, 0, 0 })
	check(client_command(engine, events, 3, "kill") == 0,
		"an enemy beyond the sight range does not lock /kill")

	-- in range but outside the cone: the watcher turns away
	engine.place(3, { 400, 0, 0 })
	engine.place(5, { 0, 0, 0 }, { 0, 180, 0 })
	check(client_command(engine, events, 3, "kill") == 0,
		"an enemy looking the other way does not lock /kill")

	-- a teammate seeing you is not a fire fight
	engine.place(5, { 0, 0, 0 }, { 0, 0, 0 })
	engine.connect(7, TEAM_AXIS, PC_SOLDIER)
	engine.spawn(7)
	events.trigger("onPlayerSpawn", 7, false)
	engine.place(7, { 100, 0, 0 }, { 0, 0, 0 })
	check(client_command(engine, events, 3, "kill") == 0,
		"a teammate watching does not lock /kill")
end)

-- The clock. et.trap_Milliseconds() is Sys_Milliseconds() - wall clock since the
-- server process started (sv_game.c:447) - while level.time is sv.time, which
-- the server carries across map changes and resets to 0 only when
-- sv_serverTimeReset is 1 (sv_init.c:812, default 0). On a server that sets it
-- the two readings are hours apart, and the old code wrote still_since[] from
-- levelTime but compared it against trap_Milliseconds(): is_stuck() then
-- answered "stuck here for ages" for every player who stood still for a frame,
-- and is_stuck() answering true means "let them /kill". Poison was the same bug
-- the other way round - expires/next_tick from trap_Milliseconds(), compared
-- against levelTime in on_game_frame(), so it never ticked and never wore off.
-- The module now keeps one clock, driven by et_RunFrame.
test("the frame clock decides, not the process clock", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	-- the sv_serverTimeReset 1 case: nine minutes of process uptime, and this
	-- map's level.time starts over at 1000
	engine.advance(500000)
	check(et.trap_Milliseconds() > 500000,
		"trap_Milliseconds() is far ahead of the level time the frames report")

	player(engine, events, 3, TEAM_AXIS, PC_MEDIC, { 0, 0, 0 })
	player(engine, events, 5, TEAM_ALLIES, PC_SOLDIER, { 5000, 0, 0 })
	events.trigger("onGameFrame", 1000)
	events.trigger("onGameFrame", 2000)

	events.trigger("onDamage", 3, 5, 20, 0, 8)
	check(client_command(engine, events, 3, "kill") == 1,
		"the combat window is measured in level time")

	-- poison ticks are the same bug class: expires/next_tick come from now_ms()
	-- and are compared against levelTime in onGameFrame
	events.trigger("onDamage", 5, 3, 0, 0, MOD_SYRINGE)
	check(cp_text(engine, 5):find("you have been poisoned", 1, true) ~= nil,
		"the victim is told they were poisoned")
	frames(events, 3000, 11000, 1000)
	check(count_damage(engine, 5, 10) == 9,
		"poison ticks once a second for its whole duration (9 ticks)")
	events.trigger("onGameFrame", 12000)
	check(cp_text(engine, 5):find("the poison wears off", 1, true) ~= nil,
		"and it expires on schedule")
	check(count_damage(engine, 5, 10) == 9, "no ticks after it expired")
end)

-- The escape hatch: a player who has not moved for STUCK_GRACE_MS (stuck in a
-- spawn, on an MG42, behind a door) is allowed to /kill even in the window.
test("a player who has been stuck may /kill", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	player(engine, events, 3, TEAM_AXIS, PC_SOLDIER, { 0, 0, 0 })
	player(engine, events, 5, TEAM_ALLIES, PC_SOLDIER, { 5000, 0, 0 })

	-- moving for the first five seconds: still_since is never set
	for t = 1000, 5000, 500 do
		engine.place(3, { t * 0.1, 0, 0 })
		events.trigger("onGameFrame", t)
	end
	engine.place(3, { 0, 0, 0 })          -- and then they stop moving
	events.trigger("onGameFrame", 5500)   -- the frame that notices the change
	events.trigger("onGameFrame", 6000)   -- still_since = 6000

	events.trigger("onDamage", 3, 5, 20, 0, 8)
	check(client_command(engine, events, 3, "kill") == 1,
		"a recently stopped player is still refused in combat")

	frames(events, 6500, 14000, 500)
	events.trigger("onDamage", 3, 5, 20, 0, 8)     -- fresh hit: window open
	check(client_command(engine, events, 3, "kill") == 0,
		"after " .. STUCK_GRACE_MS .. "ms without moving /kill is allowed again")

	-- moving again re-arms the rule
	for t = 14500, 15500, 500 do
		engine.place(3, { t * 0.1, 0, 0 })
		events.trigger("onGameFrame", t)
	end
	events.trigger("onDamage", 3, 5, 20, 0, 8)
	check(client_command(engine, events, 3, "kill") == 1,
		"moving again closes the escape hatch")
end)

-- The thrown knife, from the throw itself. The old code called et.G_Spawn(),
-- which is not in the API, so nothing was ever created and the melee stab was
-- swallowed anyway.
test("throwing a knife creates a real entity and spends a throw", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	check(et.G_Spawn == nil, "the Lua API has no et.G_Spawn() (g_lua.c etlib[])")
	check(type(et.G_CreateEntity) == "function", "it has et.G_CreateEntity()")

	-- the world models are precached once per map, from itemTable[] in bg_misc.c
	check(engine.model_indexes["models/multiplayer/knife/knife.md3"] ~= nil,
		"the axis knife model is precached at map start")
	check(engine.model_indexes["models/multiplayer/knife_kbar/knife.md3"] ~= nil,
		"the kabar model is precached at map start")

	local c = player(engine, events, 3, TEAM_ALLIES, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	check(c.ps.ammoclip[WP_KNIFE_KABAR] == KNIFE_CLIP_MAX,
		"spawning grants the clip of " .. KNIFE_CLIP_MAX .. " throws")
	check(c.ps.ammo[WP_KNIFE_KABAR] == 1,
		"and it leaves the class load-out's reserve alone (bg_classes.c)")
	check(c.ps.weapon == WP_THOMPSON, "the knife is granted without putting it in hand")

	events.trigger("onGameFrame", 1000)
	local ret, ent = throw(engine, events, 3, WP_KNIFE_KABAR, 1000)

	check(ret == 1, "the throw is intercepted, so the melee stab does not happen")
	check(ent ~= nil, "an entity was created")
	check(c.ps.ammoclip[WP_KNIFE_KABAR] == KNIFE_CLIP_MAX - 1,
		"throwing spends one of the five knives")

	local e = gent(engine, ent)
	check(e.inuse == 1, "the entity is still in use (G_CallSpawn did not free it)")
	check(e.classname == "target_position",
		"created with a classname the engine's spawn table knows")
	local created = engine.gent_create_log[1]
	check(created ~= nil and created.vars:find("classname target_position", 1, true) ~= nil,
		"G_CreateEntity got the spawn vars as a string")
	-- out in front of the eyes: origin + forward*16, z + viewheight (40)
	check(near(e.origin[1], 16) and near(e.origin[2], 0) and near(e.origin[3], 40),
		"it starts at the muzzle point")

	check(e.s.eType == ET_GENERAL,
		"drawn as ET_GENERAL, the only type CG_General() renders from s.modelindex")
	check(e.s.modelindex == engine.model_indexes["models/multiplayer/knife_kbar/knife.md3"],
		"and it carries the kabar's world model")
	check(e.r.ownerNum == 3, "owned by the thrower, so the trace can ignore them")
	check(e.clipmask == stub.MASK_MISSILESHOT, "clipped like a missile")
	check(e.r.mins[1] == -1 and e.r.maxs[1] == 1, "with a small bounding box")

	check(e.s.pos ~= nil and e.s.pos.trType == TR_GRAVITY, "the trajectory is TR_GRAVITY")
	check(e.s.pos ~= nil and e.s.pos.trTime == 1000, "started at this level time")
	check(e.s.pos ~= nil and near(e.s.pos.trBase[3], 40)
		and near(e.s.pos.trDelta[1], THROW_SPEED) and near(e.s.pos.trDelta[3], THROW_UP),
		"base and delta match the throw speed")
	check(e.s.apos ~= nil and e.s.apos.trType == TR_LINEAR and e.s.apos.trDelta[1] == KNIFE_SPIN,
		"it tumbles - CG_CalcEntityLerpPositions() only animates s.apos")
	check(type(e.s.angles) == "table" and near(e.s.angles[2], 0, 0.01),
		"s.angles points along the throw")
	check(e.r.linked == true, "and it was linked into the world")
	check(#engine.gent_free_log == 0, "nothing was freed by the throw itself")
	check(#engine.damage == 0, "a throw on its own damages nobody")
end)

-- The engine will not move an entity Lua created (no think function), so the
-- module has to be the knife's G_RunMissile(): evaluate the trajectory, trace
-- from the last position to the new one, re-link.
test("the knife flies where the trajectory says", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	player(engine, events, 3, TEAM_ALLIES, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	events.trigger("onGameFrame", 1000)
	local _, ent = throw(engine, events, 3, WP_KNIFE_KABAR, 1000)
	local e = gent(engine, ent)

	-- BG_EvaluateTrajectory() for TR_GRAVITY: base + delta*t - 0.5*g*t^2
	local function expect(t)
		local dt = (t - 1000) / 1000
		return 16 + THROW_SPEED * dt, 0, 40 + THROW_UP * dt - 0.5 * GRAVITY * dt * dt
	end

	for _, t in ipairs({ 1050, 1100, 1200, 1400 }) do
		events.trigger("onGameFrame", t)
		local x, y, z = expect(t)
		check(near(e.r.currentOrigin[1], x, 0.01) and near(e.r.currentOrigin[2], y, 0.01)
			and near(e.r.currentOrigin[3], z, 0.01),
			"at " .. t .. "ms the knife is at the trajectory position")
	end

	-- it fell: 400ms after the throw gravity has taken 32 units off the climb
	check(e.r.currentOrigin[3] ~= nil and e.r.currentOrigin[3] < 40,
		"gravity pulls it down")
	check(#engine.gent_free_log == 0, "still flying, nothing freed")
	check(e.inuse == 1, "and still in use")

	local last = engine.trace_log[#engine.trace_log]
	check(last ~= nil and last.passent == 3,
		"each frame traces with the thrower as passent (the muzzle is inside their box)")
	check(last ~= nil and last.mask == stub.MASK_MISSILESHOT,
		"traced against missiles, not just shots")
	check(last ~= nil and last.start ~= nil and near(last.start[1], 16 + THROW_SPEED * 0.2, 0.01),
		"the trace starts where the last frame left the knife")
	check(#engine.link_log >= 4, "and every move re-links the entity")
end)

-- Hitting a player: G_Damage(target, inflictor, attacker, damage, dflags, mod)
-- with the mod of the knife that was thrown, and the entity is freed.
test("a knife that hits an enemy damages them", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	-- an axis knife at an enemy standing on the same level: a body hit
	player(engine, events, 3, TEAM_AXIS, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	player(engine, events, 5, TEAM_ALLIES, PC_SOLDIER, { 300, 0, 0 })
	events.trigger("onGameFrame", 1000)
	local ret, ent = throw(engine, events, 3, WP_KNIFE, 1000)
	check(ret == 1, "the axis throw is intercepted too")

	frames(events, 1050, 2000, 50)
	check(#engine.damage == 1, "one hit was dealt")
	local d = engine.damage[1]
	check(d and d.target == 5 and d.attacker == 3, "the enemy took it, from the thrower")
	check(d and d.damage == THROW_DAMAGE, "a body hit does " .. THROW_DAMAGE .. " damage")
	check(d and d.mod == MOD_KNIFE, "reported as MOD_KNIFE for the axis knife")
	check(gent(engine, ent).inuse == 0, "the knife is freed on impact")
	check(#engine.gent_free_log == 1, "and the entity slot is given back")
	check(engine.client(3).ps.ammoclip[WP_KNIFE] == KNIFE_CLIP_MAX - 1,
		"the throw was still spent")

	-- the same throw at an enemy ten units lower: the hit lands in the engine's
	-- head box (origin + viewheight, mins z -2 -> 38 units above the origin)
	local engine2, events2 = new_server({ sv_maxclients = 16 })
	player(engine2, events2, 4, TEAM_ALLIES, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	player(engine2, events2, 6, TEAM_AXIS, PC_SOLDIER, { 300, 0, -10 })
	events2.trigger("onGameFrame", 1000)
	throw(engine2, events2, 4, WP_KNIFE_KABAR, 1000)
	frames(events2, 1050, 2000, 50)
	check(#engine2.damage == 1, "the lowered enemy was hit as well")
	local h = engine2.damage[1]
	check(h and h.damage == THROW_DAMAGE_HEAD,
		"a hit above the victim's viewheight - 2 is a headshot")
	check(h and h.mod == MOD_KNIFE_KABAR, "reported as MOD_KNIFE_KABAR for the allies")

	-- a teammate is never a target: the knife flies straight through
	local engine3, events3 = new_server({ sv_maxclients = 16 })
	player(engine3, events3, 3, TEAM_AXIS, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	player(engine3, events3, 5, TEAM_AXIS, PC_SOLDIER, { 300, 0, 0 })
	events3.trigger("onGameFrame", 1000)
	throw(engine3, events3, 3, WP_KNIFE, 1000)
	frames(events3, 1050, 2000, 50)
	check(#engine3.damage == 0, "a friendly is not damaged")
	check(live_knives(engine3) == 1, "the knife keeps flying past them")
	local fe = gent(engine3, engine3.gent_create_log[1] and engine3.gent_create_log[1].number)
	check(fe.s.pos.trType == TR_GRAVITY, "it did not stick in the friendly")
	check(fe.r.currentOrigin[1] and fe.r.currentOrigin[1] > 400,
		"and it flew on past them (G_Damage would have refused the hit anyway)")

	-- a corpse is not a target either
	local engine4, events4 = new_server({ sv_maxclients = 16 })
	player(engine4, events4, 3, TEAM_AXIS, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	player(engine4, events4, 5, TEAM_ALLIES, PC_SOLDIER, { 300, 0, 0 })
	engine4.health(5, 0)
	events4.trigger("onGameFrame", 1000)
	throw(engine4, events4, 3, WP_KNIFE, 1000)
	frames(events4, 1050, 2000, 50)
	check(#engine4.damage == 0, "a dead player is not damaged")
end)

-- Landing, sticking, pickup and lifetime. A landed knife is a world entity the
-- module has to keep tidying up, or the entity pool runs out and G_Spawn()
-- calls G_Error() - which takes the server down.
test("a knife sticks in a wall and can be picked up", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	local c = player(engine, events, 3, TEAM_ALLIES, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	stub.add_wall(engine, { 500, -500, -100 }, { 520, 500, 300 })
	events.trigger("onGameFrame", 1000)
	local _, ent = throw(engine, events, 3, WP_KNIFE_KABAR, 1000)
	local e = gent(engine, ent)

	frames(events, 1050, 2000, 50)
	check(e.inuse == 1, "a knife in a wall stays in the world")
	check(e.s.pos.trType == TR_STATIONARY, "and stops moving: TR_STATIONARY")
	check(e.s.apos.trType == TR_STATIONARY, "it stops tumbling too")
	check(near(e.r.currentOrigin[1], 499, 2), "it stuck in the face of the wall")
	check(#engine.damage == 0, "hitting a wall damages nobody")
	check(#engine.gent_free_log == 0, "and it is not freed yet")
	local resting = { e.r.currentOrigin[1], e.r.currentOrigin[2], e.r.currentOrigin[3] }

	-- walking over it gives the throw back
	engine.place(3, { resting[1], resting[2], resting[3] })
	events.trigger("onGameFrame", 2100)
	check(c.ps.ammoclip[WP_KNIFE_KABAR] == KNIFE_CLIP_MAX,
		"picking it up restores the throw")
	check(e.inuse == 0 and #engine.gent_free_log == 1,
		"and frees the entity")
	check(live_knives(engine) == 0, "no knives left in the world")

	-- a full clip cannot take another one: the knife stays where it is. Throw
	-- from the spawn point again, not from next to the wall.
	engine.place(3, { 0, 0, 0 })
	local _, ent2 = throw(engine, events, 3, WP_KNIFE_KABAR, 3000)
	local e2 = gent(engine, ent2)
	frames(events, 3050, 4000, 50)
	check(e2.inuse == 1, "the second knife landed in the wall again")
	check(c.ps.ammoclip[WP_KNIFE_KABAR] == KNIFE_CLIP_MAX - 1, "one throw was spent")
	check(near(e2.r.currentOrigin[1], 499, 2), "in the same place as the first")

	-- top the clip up (et.AddWeaponToPlayer assigns both pools) and walk over it
	et.AddWeaponToPlayer(3, WP_KNIFE_KABAR, c.ps.ammo[WP_KNIFE_KABAR], KNIFE_CLIP_MAX, 0)
	engine.place(3, { resting[1], resting[2], resting[3] })
	events.trigger("onGameFrame", 4100)
	check(c.ps.ammoclip[WP_KNIFE_KABAR] == KNIFE_CLIP_MAX,
		"a player with a full clip cannot pick up another knife")
	check(e2.inuse == 1, "so it stays in the world for somebody else")

	-- left alone, it goes away after its lifetime instead of leaking the slot
	engine.place(3, { 0, 0, 0 })
	events.trigger("onGameFrame", 3000 + KNIFE_LIFETIME_MS + 1000)
	check(e2.inuse == 0, "an unpicked knife is freed after its lifetime")
	check(live_knives(engine) == 0, "and the world is empty again")
end)

-- Rate limiting: one throw per THROW_COOLDOWN_MS, and an empty clip has to fall
-- through to the engine's melee stab (return 0) instead of eating the attack.
test("the throw cooldown and an empty clip", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	local c = player(engine, events, 3, TEAM_ALLIES, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	events.trigger("onGameFrame", 1000)

	local ret1, ent1 = throw(engine, events, 3, WP_KNIFE_KABAR, 1000)
	check(ret1 == 1 and ent1 ~= nil, "the first throw goes off")

	local ret2 = throw(engine, events, 3, WP_KNIFE_KABAR, 1000 + THROW_COOLDOWN_MS - 100)
	check(ret2 == 0, "another throw inside the cooldown is passed to the engine")
	check(c.ps.ammoclip[WP_KNIFE_KABAR] == KNIFE_CLIP_MAX - 1,
		"and spends nothing")
	check(live_knives(engine) == 1, "and creates nothing")

	local ret3, ent3 = throw(engine, events, 3, WP_KNIFE_KABAR, 1000 + THROW_COOLDOWN_MS + 100)
	check(ret3 == 1 and ent3 ~= nil and ent3 ~= ent1,
		"after the cooldown the next throw goes off")
	check(c.ps.ammoclip[WP_KNIFE_KABAR] == KNIFE_CLIP_MAX - 2, "and spends a knife")

	-- the clip runs out: the melee stab must keep working
	for i = 1, KNIFE_CLIP_MAX - 2 do
		throw(engine, events, 3, WP_KNIFE_KABAR, 3000 + i * (THROW_COOLDOWN_MS + 100))
	end
	check(c.ps.ammoclip[WP_KNIFE_KABAR] == 0, "all " .. KNIFE_CLIP_MAX .. " knives are thrown")
	local before = #engine.gent_create_log
	local ret4 = throw(engine, events, 3, WP_KNIFE_KABAR, 20000)
	check(ret4 == 0, "an empty clip lets the engine do the normal melee stab")
	check(#engine.gent_create_log == before, "and creates no entity")

	-- a spectator, a dead player and a player with no knife are passed through
	engine.health(3, 0)
	check(throw(engine, events, 3, WP_KNIFE_KABAR, 21000) == 0, "a dead player cannot throw")
	engine.health(3, 100)
	engine.connect(9, 3, PC_SOLDIER)
	events.trigger("onClientBegin", 9)
	check(throw(engine, events, 9, WP_KNIFE_KABAR, 22000) == 0, "a spectator cannot throw")
	check(throw(engine, events, 3, WP_THOMPSON, 23000) == 0,
		"firing something that is not a knife is left alone")
end)

-- G_Spawn() calls G_Error() - which brings the whole server down - when the
-- entity pool is empty, so the number of knives in the world is capped and the
-- oldest one is freed to make room.
test("the world never holds more than " .. KNIFE_MAX_LIVE .. " knives", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	-- three players far apart, throwing straight up: nothing to hit, so every
	-- knife stays in the world until the cap or its lifetime ends it
	for i, num in ipairs({ 2, 4, 6 }) do
		player(engine, events, num, TEAM_ALLIES, PC_SOLDIER,
			{ (i - 1) * 4000, 0, 0 }, { -90, 0, 0 })
	end
	events.trigger("onGameFrame", 1000)

	local thrown = 0
	for t = 2000, 6000, 1000 do
		for _, num in ipairs({ 2, 4, 6 }) do
			local ret = events.trigger("onWeaponFire", num, WP_KNIFE_KABAR)
			events.trigger("onGameFrame", t)
			if ret == 1 then thrown = thrown + 1 end
		end
	end

	check(thrown == KNIFE_MAX_LIVE + 3, "all fifteen throws were accepted")
	local live = live_knives(engine)
	check(live == KNIFE_MAX_LIVE, "only " .. KNIFE_MAX_LIVE .. " knives are in the world")
	check(#engine.gent_free_log == 3, "the three oldest were freed to make room")
	for _, num in ipairs({ 2, 4, 6 }) do
		check(engine.client(num).ps.ammoclip[WP_KNIFE_KABAR] == 0,
			"client " .. num .. " threw their whole clip")
	end
end)

-- The entity number G_CreateEntity() returns is only a promise: the engine
-- frees the entity again when the classname has no spawn function, and a map
-- script or another mod can free the slot later and put something else in it.
-- Tracking a stale number means the next knife.free() frees somebody else's
-- entity.
test("a knife whose entity slot the engine took back is dropped", function()
	if type(et.G_CreateEntity) ~= "function" then
		-- nothing below can run without the only entity constructor Lua gets
		check(false, "the Lua API has et.G_CreateEntity()")
		return
	end
	local engine, events = new_server({ sv_maxclients = 16 })
	player(engine, events, 3, TEAM_ALLIES, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })

	-- the stub models G_CallSpawn(): an unknown classname comes back freed
	local stale = et.G_CreateEntity('classname thrown_knife origin "0 0 0"')
	check(engine.ents[stale].inuse == 0,
		"an entity with a classname the engine has no spawn function for is freed again")
	check(engine.ents[stale].classname == "freed", "and left as \"freed\"")
	local real = et.G_CreateEntity('classname target_position origin "0 0 0"')
	check(engine.ents[real].inuse == 1 and real == stale,
		"the same slot is handed out again - which is why the number must be checked")
	et.G_FreeEntity(real)

	events.trigger("onGameFrame", 1000)
	local _, ent = throw(engine, events, 3, WP_KNIFE_KABAR, 1000)
	check(engine.ents[ent].inuse == 1, "the thrown knife is a live target_position")

	-- the engine gives the slot up and a map script moves something else in
	et.G_FreeEntity(ent)
	local other = et.G_CreateEntity('classname target_location origin "100 0 0"')
	check(other == ent, "the map script's entity landed in the knife's slot")
	local frees_before = #engine.gent_free_log
	local was = engine.ents[other].r.currentOrigin
	local was_at = { was[1], was[2], was[3] }

	frames(events, 1050, 3000, 50)
	check(engine.ents[other].inuse == 1, "the module did not free an entity it no longer owns")
	check(engine.ents[other].classname == "target_location", "and left it alone")
	local now = engine.ents[other].r.currentOrigin
	check(near(now[1], was_at[1], 0.001) and near(now[2], was_at[2], 0.001)
		and near(now[3], was_at[3], 0.001),
		"it did not carry on flying an entity that is not the knife")
	local freed_by_module = 0
	for i = frees_before + 1, #engine.gent_free_log do
		if engine.gent_free_log[i].number == other then freed_by_module = freed_by_module + 1 end
	end
	check(freed_by_module == 0, "no G_FreeEntity on the slot after it changed hands")
end)

-- -------------------------------- summary --------------------------------

print("")
if #failures > 0 then
	print(("%d of %d checks FAILED:"):format(#failures, checks))
	for _, f in ipairs(failures) do print("  - " .. f) end
	os.exit(1)
end
print(("%d checks passed"):format(checks))
os.exit(0)
