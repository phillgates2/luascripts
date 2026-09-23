-- Regression tests for the two engine-API mistakes the audit of the admin
-- commands turned up (GAMEPLAY-FIX.md section 9):
--
--   1. Timestamps written from et.trap_Milliseconds() into fields the engine
--      reads back against level.time - !burn and !firegod. trap_Milliseconds()
--      is Sys_Milliseconds(), the process clock; level.time is the server's own
--      clock and restarts with the map whenever sv_serverTimeReset is set
--      (sv_init.c:656) or after the 0x70000000 wrap. Stamping s.onFireEnd from
--      the process clock then drops the victim into the engine's flamethrower
--      burn loop (g_active.c:196-206) for as long as the server has been up,
--      instead of for the six seconds the command means.
--
--   2. FIELD_VEC3 values written one component at a time - !freeze, !throw,
--      !fling, !launch, !throwa, !launcha. The engine's setter indexes its
--      argument with the keys 1..3 (_etH_gentity_setvec3 in g_lua.c), so
--      et.gentity_set(n, "ps.velocity", 2, 900) raises "attempt to index a
--      number value" and the command silently does nothing at all.
--
-- Both were invisible to the old tests: the stub accepted any argument form for
-- a vector field, and no spec ever moved the two clocks apart. It now models
-- _etH_gentity_setvec3() and these tests move the process clock an hour ahead
-- of the level clock, the way sv_serverTimeReset 1 does on a real server.
--
-- The command modules pull in commands.commands (TOML plus a sqlite database),
-- auth.auth and players.players, none of which can load in a spec, so the
-- harness injects stand-ins for exactly the calls these commands make.
-- util.timers, util.constants, util.events and the engine stub are the real
-- thing.
--
-- Run with:   lua tests/audit_fix_spec.lua [--verbose]
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

-- main.lua resolves engine lua libraries from its own lualibs path; a spec has
-- no such path, so say so instead of calling a nil global
function wolfa_requireLib(name)
	error("the spec harness has no engine lua lib path (" .. tostring(name) .. ")", 0)
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

-- The admin commands under test. commands.commands is replaced by a recorder,
-- so the handlers registered with commands.addadmin() can be called directly.
local admin

local function new_server(opts)
	cache = {}
	admin = {}

	local engine = stub.new(opts)
	engine.install()

	cache["commands.commands"] = {
		addadmin = function(name, fn, permission, description, syntax, _, condition)
			admin[name] = { fn = fn, permission = permission, syntax = syntax or "" }
			return condition
		end,
		getadmin = function(name) return admin[name] or {} end,
	}
	cache["auth.auth"] = {
		PERM_BURN = "burn", PERM_CHEATS = "cheats", PERM_THROW = "throw",
		PERM_THROWALL = "throwall", PERM_FREEZE = "freeze",
		canTarget = function() return true end,
		isTargetProtected = function() return false end,
	}
	-- util/settings.lua loads its TOML parser through main.lua's
	-- wolfa_requireLib(), which points into the engine's lualibs path, and
	-- settings.load() then reads wolfadmin.toml and wolfadmin.cfg. A spec has
	-- none of that, and these commands only ever ask it for a value.
	cache["util.settings"] = {
		get = function(name)
			local values = {
				g_standalone = 0,
				g_restrictedVotes = "",
				g_voteNextMapTimeout = 0,
				omnibot_maxbots = 10,
				fs_game = "legacy",
			}
			return values[name]
		end,
		set = function() end,
		load = function() end,
	}
	cache["players.players"] = {
		isConnected = function(num)
			return et.gentity_get(num, "pers.connected") == 2
		end,
		isBot = function() return false end,
		getName = function(num)
			return tostring(et.gentity_get(num, "pers.netname") or "")
		end,
	}

	local events = wolfa_requireModule("util.events")
	local timers = wolfa_requireModule("util.timers")

	wolfa_requireModule("commands.admin.burn")
	wolfa_requireModule("commands.admin.firegod")
	wolfa_requireModule("commands.admin.freeze")
	wolfa_requireModule("commands.admin.throw")
	wolfa_requireModule("commands.admin.throwall")
	wolfa_requireModule("commands.admin.gib")
	wolfa_requireModule("commands.admin.giba")
	wolfa_requireModule("commands.admin.lol")
	wolfa_requireModule("commands.admin.nade")
	wolfa_requireModule("commands.admin.poison")

	return engine, events, timers
end

-- connect + spawn a player somewhere in the world
local function player(engine, num, team, class, origin)
	engine.connect(num, team or 1, class or 0)
	engine.spawn(num)
	engine.place(num, origin or { 0, 0, 0 }, { 0, 0, 0 })
	return num
end

-- A server whose two clocks have come apart, which is what sv_serverTimeReset 1
-- does at every map change: level.time starts again, Sys_Milliseconds() keeps
-- counting from the moment the process was started.
local function diverged(server, levelTime, processTime)
	local engine, events, timers = server.engine, server.events, server.timers

	-- the stub walks the process clock 50 ms on every trap_Milliseconds() read,
	-- the way a server frame does, so only the level clock - which moves when
	-- the engine runs a frame - can be compared exactly
	engine.advance(processTime - engine.time)
	events.trigger("onGameInit", levelTime, 0, false)
	events.trigger("onGameFrame", levelTime)

	assert(timers.getLevelTime() == levelTime, "level clock")
	return engine, events, timers
end

local function damageCount(engine, target, damage)
	local n = 0
	for _, d in ipairs(engine.damage) do
		if d.target == target and (damage == nil or d.damage == damage) then n = n + 1 end
	end
	return n
end

local function console(engine, pattern)
	return engine.console_count(pattern)
end

local PROCESS_AHEAD = 3600000   -- an hour of uptime, the way a long match sees it
local LEVEL_TIME = 45000        -- 45 s into the map

local function setup()
	local engine, events, timers = new_server({ sv_maxclients = 8 })
	local server = { engine = engine, events = events, timers = timers }
	player(engine, 0, 1, 0, { 0, 0, 0 })     -- the admin
	player(engine, 1, 1, 0, { 128, 0, 0 })   -- the victim
	player(engine, 2, 2, 0, { 256, 0, 0 })   -- a second victim, other team
	diverged(server, LEVEL_TIME, PROCESS_AHEAD)
	return server
end

-- --------------------------------- tests ---------------------------------

test("the two clocks are a scenario the engine can actually produce", function()
	local server = setup()
	local engine, timers = server.engine, server.timers

	check(et.trap_Milliseconds() > PROCESS_AHEAD - 1000, "trap_Milliseconds is the process clock")
	check(timers.getLevelTime() == LEVEL_TIME, "timers.getLevelTime is the level clock")
	check(et.trap_Milliseconds() - timers.getLevelTime() > 3000000,
		"the level clock is an hour behind the process clock")

	-- onGameInit seeds the clock, so a command that runs before the first frame
	-- still stamps from the level time and not from zero
	local _, seededEvents, seededTimers = new_server({ sv_maxclients = 8 })
	seededEvents.trigger("onGameInit", 1234, 0, false)
	check(seededTimers.getLevelTime() == 1234, "onGameInit seeds the level clock")
	seededEvents.trigger("onGameFrame", 2345)
	check(seededTimers.getLevelTime() == 2345, "onGameFrame refreshes it")

	-- and it only moves when the engine runs a frame: reading the process clock
	-- over and over must not drag it along, which is what makes it safe to stamp
	-- a field the engine compares against level.time from it
	for _ = 1, 5 do et.trap_Milliseconds() end
	check(seededTimers.getLevelTime() == 2345, "trap_Milliseconds() does not move it")
	check(engine.time ~= nil, "the audited server is up")
end)

test("!burn stamps the burning window on the level clock", function()
	local server = setup()
	local engine, events, timers = server.engine, server.events, server.timers

	admin["burn"].fn(0, "burn", "1")

	local start = et.gentity_get(1, "s.onFireStart")
	local finish = et.gentity_get(1, "s.onFireEnd")

	check(start == LEVEL_TIME, "s.onFireStart is the level time, not the process time")
	check(finish == LEVEL_TIME + 6000, "s.onFireEnd is six seconds of level time later")
	check(start < PROCESS_AHEAD - 1000, "it is nowhere near the process clock")
	check(finish - timers.getLevelTime() == 6000,
		"g_active.c:206 keeps burning the victim for exactly the intended window")

	-- walk the level clock through the window: burning just before it closes,
	-- out just after. Under the old stamp both readings sat an hour ahead of
	-- level.time and the victim burned for the rest of the server's uptime.
	events.trigger("onGameFrame", LEVEL_TIME + 5900)
	check((et.gentity_get(1, "s.onFireEnd") or 0) > timers.getLevelTime(),
		"still burning 5.9 s in")
	events.trigger("onGameFrame", LEVEL_TIME + 6100)
	check((et.gentity_get(1, "s.onFireEnd") or 0) <= timers.getLevelTime(),
		"the fire is out after 6.1 s")

	-- WolfAdmin's own five ticks of damage are unaffected: they are timed off
	-- the process clock by util.timers, which only ever measures durations
	for i = 1, 6 do
		engine.advance(1000)
		events.trigger("onGameFrame", LEVEL_TIME + i * 1000)
	end
	check(damageCount(engine, 1, 25) == 5, "five ticks of 25 damage from the command itself")

	local attacker = engine.damage[#engine.damage] and engine.damage[#engine.damage].attacker
	check(attacker == 1023, "and every tick names ENTITYNUM_NONE, not one past the array")
end)

test("!firegod stamps the burning window on the level clock", function()
	local server = setup()
	local events, timers = server.events, server.timers

	admin["firegod"].fn(0, "firegod", "1")

	check(et.gentity_get(1, "takedamage") == 0, "a firegod takes no damage")
	check(et.gentity_get(1, "s.onFireStart") == LEVEL_TIME, "s.onFireStart is the level time")
	check(et.gentity_get(1, "s.onFireEnd") == LEVEL_TIME + 1800000,
		"s.onFireEnd is thirty minutes of level time later")
	check(et.gentity_get(1, "s.onFireEnd") < PROCESS_AHEAD,
		"it is not the process clock plus thirty minutes")

	-- the burn loop's own test, an hour into the match: still burning, and only
	-- for the thirty minutes the command means
	check((et.gentity_get(1, "s.onFireEnd") or 0) > timers.getLevelTime(), "burning now")
	events.trigger("onGameFrame", LEVEL_TIME + 1800001)
	check((et.gentity_get(1, "s.onFireEnd") or 0) <= timers.getLevelTime(),
		"the firegod stops burning after thirty minutes of level time")

	-- toggling it off extinguishes on the level clock as well
	events.trigger("onGameFrame", LEVEL_TIME + 2000000)
	admin["firegod"].fn(0, "firegod", "1")
	check(et.gentity_get(1, "takedamage") == 1, "mortal again")
	check(et.gentity_get(1, "s.onFireEnd") == LEVEL_TIME + 2000000,
		"extinguished by pulling s.onFireEnd back to the level time")
end)

test("!firegod reports an engine that will not write client.noclip", function()
	local server = setup()
	local engine = server.engine

	-- ET:Legacy exposes noclip with FIELD_FLAG_READONLY (g_lua.c:1221), so the
	-- write raises and the command has to say so instead of failing quietly
	local ok = pcall(et.gentity_set, 1, "noclip", 1)
	check(not ok, "the stub models noclip as read-only, like the engine")

	admin["firegod"].fn(0, "firegod", "2", "noclip")

	check(et.gentity_get(2, "takedamage") == 0, "the firegod was still made")
	check(console(engine, "noclip is not supported by this engine") == 1,
		"and the admin is told the engine refused noclip")
end)

test("a FIELD_VEC3 field takes one table, as _etH_gentity_setvec3 reads it", function()
	local server = setup()

	local ok, err = pcall(et.gentity_set, 1, "ps.velocity", 0, 100)
	check(not ok, "a component index raises, exactly like the engine")
	check(type(err) == "string" and err:find("attempt to index", 1, true) ~= nil,
		"with the engine's own message: " .. tostring(err))

	et.gentity_set(1, "ps.velocity", { 10, 20, 30 })
	local v = et.gentity_get(1, "ps.velocity")
	check(v[1] == 10 and v[2] == 20 and v[3] == 30, "the table form lands in all three components")
end)

test("!launch and !throw move the player", function()
	local server = setup()

	admin["throw"].fn(0, "launch", "1")
	local v = et.gentity_get(1, "ps.velocity")
	check(v[3] == 1200, "launch sends the player up at 1200")
	check(v[1] == 0 and v[2] == 0, "and straight up, with no sideways component")

	admin["throw"].fn(0, "fling", "2")
	local w = et.gentity_get(2, "ps.velocity")
	check(w[3] == 700, "fling sends the player up at 700")
	check(type(w[1]) == "number" and type(w[2]) == "number", "with a sideways component")

	-- throwall.lua registers as !throwa, !flinga and !launcha
	admin["launcha"].fn(0, "launcha")
	check(et.gentity_get(1, "ps.velocity")[3] == 1200, "launcha reached the first player")
	check(et.gentity_get(2, "ps.velocity")[3] == 1200, "launcha reached the second player")
	check(et.gentity_get(0, "ps.velocity")[3] == 1200, "and the admin who called it")
end)

test("!freeze holds a player still and !unfreeze lets them go", function()
	local server = setup()
	local engine, events = server.engine, server.events

	-- give the victim some momentum first, the way a throw or knockback would
	et.gentity_set(1, "ps.velocity", { 300, -200, 900 })

	admin["freeze"].fn(0, "freeze", "1")
	check(et.gentity_get(1, "freezed") == 1,
		"client.freezed is set, which ClientThink turns into PM_FREEZE (g_active.c:1380)")

	-- the tick runs every 100 ms off util.timers
	engine.advance(150)
	events.trigger("onGameFrame", LEVEL_TIME + 150)

	local v = et.gentity_get(1, "ps.velocity")
	check(v[1] == 0 and v[2] == 0 and v[3] == 0, "the tick cancelled the momentum they had")

	admin["freeze"].fn(0, "unfreeze", "1")
	check(et.gentity_get(1, "freezed") == 0, "unfreeze clears the flag")

	-- a frozen player who leaves must not hand a frozen slot to the next client:
	-- ClientSpawn() never clears client.freezed
	admin["freeze"].fn(0, "freeze", "2")
	check(et.gentity_get(2, "freezed") == 1, "the second player is frozen")
	engine.ents[2].client.pers.connected = 0
	engine.advance(150)
	events.trigger("onGameFrame", LEVEL_TIME + 300)
	check(et.gentity_get(2, "freezed") == 0, "the tick cleared the flag when they disconnected")

	admin["freeze"].fn(0, "freeze", "1")
	events.trigger("onClientDisconnect", 1)
	check(et.gentity_get(1, "freezed") == 0, "and so did the disconnect handler")
end)

test("the damage commands keep their entity numbers inside g_entities", function()
	local server = setup()
	local engine, events = server.engine, server.events

	-- _et_G_Damage() does "g_entities + n" for the target, the inflictor and the
	-- attacker and checks none of them, so 1024 - what six of these commands sent
	-- for "nobody" - is one gentity_t past the end of the array, and G_Damage()
	-- reads whatever the linker put there as the attacker. The stub raises where
	-- the engine would not.
	check(not pcall(et.G_Damage, 1, 0, 1024, 10, 0, 0), "1024 is outside g_entities")
	check(pcall(et.G_Damage, 1, 0, 1023, 10, 0, 0), "ENTITYNUM_NONE, the last slot, is inside it")
	check(not pcall(et.G_Damage, 1024, 0, 0, 10, 0, 0), "and the same goes for the target")

	engine.damage = {}
	admin["gib"].fn(0, "gib", "1")
	check(#engine.damage == 1 and engine.damage[1].attacker == 1023,
		"!gib damages with ENTITYNUM_NONE as the attacker")

	engine.damage = {}
	admin["giba"].fn(0, "giba")
	check(#engine.damage >= 2, "!giba reached both players")
	local allValid = true
	for _, d in ipairs(engine.damage) do
		if d.attacker ~= 1023 then allValid = false end
	end
	check(allValid, "and named a valid attacker for each of them")

	-- !lol, !nade and !poison schedule their damage through util.timers, so the
	-- clock has to run for it to land
	for _, name in ipairs({ "lol", "nade", "poison" }) do
		engine.damage = {}
		admin[name].fn(0, name, "1", "1")

		for i = 1, 12 do
			engine.advance(1000)
			events.trigger("onGameFrame", LEVEL_TIME + 10000 + i * 1000)
		end

		check(#engine.damage > 0, "!" .. name .. " damaged the player")

		allValid = true
		for _, d in ipairs(engine.damage) do
			if d.attacker ~= 1023 then allValid = false end
		end
		check(allValid, "!" .. name .. " named a valid attacker every time")
	end
end)

test("the modules are registered the way main.lua loads them", function()
	local server = setup()

	for _, name in ipairs({ "burn", "firegod", "freeze", "unfreeze", "throw", "fling",
		"launch", "throwa", "flinga", "launcha", "gib", "giba", "lol", "nade",
		"poison" }) do
		check(admin[name] ~= nil and type(admin[name].fn) == "function",
			"!" .. name .. " registered its handler")
	end
	check(type(server.timers.getLevelTime) == "function",
		"and util.timers carries the level clock they stamp from")
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
