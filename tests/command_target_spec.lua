-- Regression tests for the runtime errors the live server kept reporting on
-- commands that target a player:
--
--   et_ConsoleCommand error running lua script:
--   '.../players/players.lua:43: attempt to index a nil value (field '?')'
--   '.../util/tables.lua:77: bad argument #1 to 'for iterator' (table expected, got nil)'
--   '.../db/sqlite3.lua:468: attempt to concatenate a nil value'
--
-- Every player-targeting command resolves its victim to a *slot number* and
-- then checked `not et.gentity_get(cmdClient, "pers.netname")` to find out
-- whether anybody is in it. That check never fired: G_InitGame() gives every
-- slot below level.maxclients an ent->client (g_main.c) and the gclient_t is
-- memset, so the engine returns "" - which is truthy in Lua - for a slot
-- nobody occupies. The command then walked into players.getGUID()/getIP(),
-- acl.getPlayerLevel() and db.getBan() with data[slot] == nil.
--
-- The same class of hole existed for a valid team value the modules do not
-- track: a bot connects with TEAM_FREE (0) because g_client.c only forces the
-- spectator team for a first-time human, so teams.onconnect() indexed
-- players[0] and balancer's lastJoined[0], both nil.
--
-- These tests load the REAL modules against tests/et_stub.lua and drive those
-- exact inputs. Run with:  lua tests/command_target_spec.lua [--verbose]

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

-- the engine, as tests/gameplay_spec.lua sets it up
local engine = stub.new({ sv_maxclients = 16 })
engine.install()
engine.cvars.fs_game = "legacy"

-- load a module of the tree the way main.lua's wolfa_requireModule() does,
-- with stand-ins for the parts that need a database or the toml parser
local fakes, cache = {}, {}

-- `db.isConnected() = true` but every player row is missing: the modules have
-- to cope with that (and with a missing row being indexed), it is the signal
-- the live server showed whenever data[clientId] was nil
fakes["db.db"] = {
	isConnected = function() return true end,
	getPlayer = function() return nil end,
	getPlayerId = function() return nil end,
	getLastAlias = function() return nil end,
	getBan = function() assert(false, "getBan must not be reached with a nil id") end,
}

fakes["util.settings"] = {
	get = function(name) return engine.cvars[name] or 1 end,
}

fakes["commands.commands"] = {
	addadmin = function() end,
	getadmin = function() return { syntax = "<test syntax>" } end,
}

fakes["admin.history"] = { add = function() end }

-- bans.get() is what baninfo.lua calls with `tonumber(banId)`: make a nil id
-- impossible to miss, exactly like the SQL layer would
fakes["admin.bans"] = {
	get = function(banId)
		assert(type(banId) == "number", "bans.get() called with a non-numeric ban id")
		return nil
	end,
	add = function() end,
	remove = function() end,
}

function wolfa_requireModule(name)
	if fakes[name] then return fakes[name] end
	if cache[name] then return cache[name] end
	local chunk = assert(loadfile(ROOT .. name:gsub("%.", "/") .. ".lua"))
	local result = chunk() or true
	cache[name] = result
	return result
end

-- main.lua defines this global for the module tree
local debugLines = {}
function outputDebug(msg) debugLines[#debugLines + 1] = tostring(msg) end

local players = wolfa_requireModule("players.players")
local tables = wolfa_requireModule("util.tables")
local events = wolfa_requireModule("util.events")

local function call(fn, ...)
	local ok, result = pcall(fn, ...)
	return ok, result
end

-- the console output the commands produced (trap_SendConsoleCommand records
-- into engine.consoles; the driver's messages are the last entries)
local function last_console()
	local c = engine.consoles[#engine.consoles]
	return c and c.cmd or ""
end

-- --------------------------------- tests ---------------------------------

test("players accessors survive a slot that is not connected", function()
	check(players.isConnected(5) == false, "slot 5 is not connected")

	for _, name in ipairs({ "getGUID", "getIP", "getProtocol", "isBot",
	                        "getLastPMSender", "getMuteType", "getMuteIssuedAt",
	                        "getMuteExpiresAt", "isTeamLocked" }) do
		local ok, value = call(players[name], 5)
		check(ok, "players." .. name .. "(5) does not raise")
		check(value == nil, "players." .. name .. "(5) is nil")
	end

	local ok, muted = call(players.isMuted, 5)
	check(ok and muted == false, "players.isMuted(5) is false without raising")

	local ok2 = call(players.setTeamLocked, 5, true)
	check(ok2, "players.setTeamLocked(5, true) does not raise")
	local ok3 = call(players.setMuted, 5, true, players.MUTE_CHAT, 0, 0)
	check(ok3, "players.setMuted() on an unknown slot does not raise")
end)

test("the players lifecycle handlers tolerate an unknown slot", function()
	local ok = call(players.onClientInfoChange, 5)
	check(ok, "onClientInfoChange(5) does not raise")
	local ok2 = call(players.onClientBegin, 5)
	check(ok2, "onClientBegin(5) does not raise")
end)

test("acl.getPlayerLevel() treats an unconnected slot as a guest", function()
	local acl = wolfa_requireModule("auth.acl")

	check(acl.getPlayerLevel(5) == 0, "slot 5 has level 0")
	-- the console pseudo-client (-1337) keeps its bot GUID and therefore works
	local ok, level = call(acl.getPlayerLevel, -1337)
	check(ok and level == 0, "the console client does not raise either")
end)

test("teams tracks a bot that connects with TEAM_FREE", function()
	local teams = wolfa_requireModule("game.teams")
	local constants = wolfa_requireModule("util.constants")

	-- the engine only forces TEAM_SPECTATOR for a first-time human
	local c = engine.ents[3].client
	c.sess.sessionTeam = et.TEAM_FREE

	local ok = call(teams.onconnect, 3, true, true)
	check(ok, "teams.onconnect() with TEAM_FREE does not raise")
	check(teams.count(constants.TEAM_AXIS) == 0, "the bot is not tracked as axis")
	check(teams.count(constants.TEAM_SPECTATORS) == 0, " ... nor as spectator")

	-- the bot picks axis: it enters the tracked list
	teams.onclientteamchange(3, et.TEAM_FREE, constants.TEAM_AXIS)
	check(teams.count(constants.TEAM_AXIS) == 1, "the join puts it on axis")

	-- and may switch teams / disconnect from there (the engine field follows
	-- the team change, which is what the disconnect hook reads back)
	teams.onclientteamchange(3, constants.TEAM_AXIS, constants.TEAM_ALLIES)
	c.sess.sessionTeam = constants.TEAM_ALLIES
	check(teams.count(constants.TEAM_AXIS) == 0 and teams.count(constants.TEAM_ALLIES) == 1,
		"a team change moves it between the two lists")
	check(call(teams.ondisconnect, 3), "teams.ondisconnect() does not raise")
	check(teams.count(constants.TEAM_ALLIES) == 0, "the disconnect drops it again")

	-- an unknown team id is skipped, not indexed
	check(teams.count(99) == 0, "teams.count() on an untracked team is 0")
	check(call(teams.ondisconnect, 4), "ondisconnect() on an untracked team does not raise")
end)

test("the balancer survives a disconnect from an untracked team", function()
	local constants = wolfa_requireModule("util.constants")
	local balancer = wolfa_requireModule("admin.balancer")

	engine.ents[4].client.sess.sessionTeam = et.TEAM_FREE
	check(call(balancer.onclientdisconnect, 4), "balancer.onclientdisconnect() does not raise")

	engine.ents[4].client.sess.sessionTeam = constants.TEAM_AXIS
	check(call(balancer.onclientdisconnect, 4), "and works for a tracked team")
end)

test("!ban rejects a slot number nobody occupies", function()
	wolfa_requireModule("commands.admin.ban")

	check(type(commandBan) == "function", "the real commands/admin/ban.lua was loaded")

	local before = #engine.consoles
	local ok, result = call(commandBan, -1337, "ban", "5", "600", "nit")

	check(ok, "!ban 5 600 nit does not raise")
	check(result == true, "the command reports itself handled")
	check(#engine.consoles > before, "the admin got an answer")
	check(string.find(last_console(), "no connected player", 1, true) ~= nil,
		"the answer is the 'no connected player by that name or slot #' message")
end)

test("!baninfo ignores a non-numeric ban id", function()
	wolfa_requireModule("commands.admin.baninfo")

	local before = #engine.consoles
	local ok, result = call(commandBanInfo, -1337, "baninfo", "Player1")

	check(ok, "!baninfo Player1 does not raise")
	check(result == true, "the command reports itself handled")
	check(string.find(last_console(), "no ban with number", 1, true) ~= nil,
		"the answer is the 'no ban with number' message, the id never reached bans.get()")
end)

test("an ET:Legacy server forced into add-on mode degrades instead of aborting", function()
	-- [main] standalone = 0 in wolfadmin.toml (or `set g_standalone 0`): there
	-- is no shrubbot flag table for fs_game "legacy", and raising here would
	-- abort et_InitGame() on every map load
	local oldGet = fakes["util.settings"].get
	fakes["util.settings"].get = function(name)
		if name == "g_standalone" then return 0 end
		return oldGet(name)
	end

	local auth = wolfa_requireModule("auth.auth")
	local ok = call(auth.onGameInit)
	check(ok, "auth.onGameInit() does not raise without a flag table")
	check(auth.isPlayerAllowed(0, "ban") == false, "no command is accepted")
	check(auth.getPlayerLevel(0) == 0, "the level degrades to guest")

	fakes["util.settings"].get = oldGet
end)

-- -------------------------------- summary --------------------------------

print("")
if #failures == 0 then
	print(string.format("%d checks passed", checks))
else
	print(string.format("%d of %d checks FAILED:", #failures, checks))
	for _, f in ipairs(failures) do print("  - " .. f) end
end

if arg then
	os.exit(#failures == 0 and 0 or 1)
end

return { checks = checks, failures = failures }
