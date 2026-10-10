-- Regression tests for the error reported from the live server (Lua 5.4 API):
--
--   Lua 5.4 API: et_ConsoleCommand error running lua script:
--   '[string "luascripts/wolfadmin/main.lua"]:171: attempt to index a nil value
--   (upvalue 'events')'
--
-- (and, from an earlier 2.77 server, the et_ShutdownGame form of the same
-- error, etlegacy/etlegacy#1426: "proper checks must be done to prevent the lua
-- error if [the hook] was called before et_InitGame").
--
-- The engine creates the Lua VM in G_LuaInit() - in the middle of G_InitGame()
-- - but only calls et_InitGame() from G_LuaHook_InitGame(), at the end of it.
-- `lua_init`, `lua_restart` and `gLoadLua` do neither: they run the script
-- through G_LuaRunIsolated()/G_LuaInit() on a server that is already running a
-- map, so every callback is registered while `events`, `game`, `commands` and
-- the rest of the module tree are still nil. The engine then keeps calling
-- those callbacks (console/rcon commands via Cmd_ExecuteString() ->
-- SV_GameCommand() -> G_LuaHook_ConsoleCommand(), G_Printf() via
-- G_LuaHook_Print(), G_RunFrame() via G_LuaHook_RunFrame()).
--
-- These tests load the REAL main.lua against tests/et_stub.lua - the same way
-- tests/live_sim.lua drives the real et_SpawnEntitiesFromString() - and then
-- call every engine callback in that order, which is what failed before:
-- with the guard in place the callbacks answer the engine's "not handled"
-- value (0 / nil) instead of indexing a nil upvalue.
--
-- Run with:   lua tests/init_guard_spec.lua [--verbose]
-- Exit code:  0 when everything passes, 1 otherwise.
-- See CONSOLE-COMMAND-FIX.md for the diagnosis.

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

-- main.lua exactly as the engine hands it to luaL_loadbuffer(): vm->file_name
-- is the chunk name (g_lua.c, G_LuaStartVM()), *without* the "@" prefix that
-- loadfile() adds. That matters: et_InitGame() derives luamodspath from
-- debug.getinfo(1).source by cutting the last 9 characters ("/main.lua"), which
-- only gives "luascripts/wolfadmin" - and not "@tests/../" - for this chunk
-- name. Loading the file any other way would test a module path the server
-- never uses.
local function read_main()
	local f = assert(io.open(ROOT .. "main.lua", "rb"))
	local source = f:read("a")
	f:close()
	return source
end

-- The engine's LUA_PATH (G_LuaStartVM()) is
-- "<homepath>/<fs_game>/?.lua;<homepath>/<fs_game>/lualibs/?.lua", so
-- wolfa_requireModule("util.events") asks for "luascripts/wolfadmin/util/events"
-- and finds luascripts/wolfadmin/util/events.lua under the game directory.
-- util/events.lua is loaded for real - it is pure Lua and it is the module the
-- callbacks have to reach. The rest of the tree cannot be loaded here (db needs
-- ET:Legacy's sqlite/mysql lua lib, commands needs the toml parser, the admin
-- config files and a database, ...), so those become recording stand-ins:
-- these tests are about main.lua's guards, not about their output.
local function new_server(opts)
	opts = opts or {}

	local engine = stub.new(opts)
	engine.install()

	local cache = {}
	local modules = {}
	local calls = {}
	local failed_modules = opts.fail and { [opts.fail] = true } or {}

	local function record(short, key, ...)
		local log = calls[short]
		log[#log + 1] = { key = key, args = { ... } }
	end

	-- a module stand-in whose every function call is recorded; tests override
	-- the methods they care about (game.getState() below, for instance)
	local function fake_module(short)
		local log = {}
		calls[short] = log

		local fake = { calls = log }
		return setmetatable(fake, {
			__index = function(_, key)
				return function(...)
					record(short, key, ...)
					return 0
				end
			end,
		})
	end

	-- game.getState() is the one module method a callback uses directly
	-- (et_RunFrame()), and the tests have to look at it before et_InitGame()
	-- has required anything, so its stand-in exists from the start - with the
	-- same table the require cache below will hand out
	local game_module = fake_module("game/game")
	game_module.getState = function()
		record("game/game", "getState")
		return 0
	end
	cache["game/game"] = game_module
	modules["game/game"] = game_module

	_G.require = function(name)
		local short = name:gsub("^luascripts/wolfadmin/", "")

		if cache[short] then
			return cache[short]
		end

		if failed_modules[short] then
			-- the trigger for the second half of the bug report: a module tree
			-- that fails to load leaves et_InitGame() unfinished
			error("simulated module failure: " .. short, 0)
		end

		if short == "util/events" then
			cache[short] = assert(loadfile(ROOT .. short .. ".lua"))()
			modules[short] = cache[short]
			return cache[short]
		end

		local fake = fake_module(short)
		-- the real util/debug.lua defines this as a global, et_InitGame() and
		-- every module call it directly (util/debug.lua:39)
		if short == "util/debug" then
			_G.outputDebug = function(msg, severity)
				record(short, "outputDebug", msg, severity)
				-- the real one prints through et.G_Print() (util/debug.lua:41)
				et.G_Print("[WolfAdmin] " .. tostring(msg) .. "\n")
			end
		end

		cache[short] = fake
		modules[short] = fake
		return fake
	end

	-- load the real event bus up front: a test registers its handlers on it
	-- before et_InitGame() runs, and main.lua gets the very same table back
	-- from this cache when et_InitGame() requires it - which is also how the
	-- engine's own require cache behaves
	modules["util/events"] = assert(require("luascripts/wolfadmin/util/events"))

	assert(load(read_main(), "luascripts/wolfadmin/main.lua"))()

	-- modules are named the way they are required: "game/game" is game/game.lua
	return {
		engine = engine,
		et = et,
		modules = modules,
		calls = calls,
		module_calls = function(short) return calls[short] or {} end,
	}
end

local function count_calls(harness)
	local n = 0
	for _, log in pairs(harness.calls) do
		n = n + #log
	end
	return n
end

-- --------------------------------- tests ---------------------------------

-- The reported symptom: the engine's console-command hook on a module that has
-- been loaded but never initialized. Before the guard this raised at main.lua's
-- `return events.trigger("onServerCommand", cmdText)`.
test("the reported error: a console command before et_InitGame()", function()
	local h = new_server()

	local ok, result = pcall(et_ConsoleCommand, "status")

	check(ok, "et_ConsoleCommand('status') does not raise" ..
		(ok and "" or ": " .. tostring(result)))
	check(result == 0, "and answers 0 - the engine runs 'status' itself")
	check(h.engine.count("attempt to index a nil value") == 0,
		"no 'attempt to index a nil value (upvalue ...)' in the console log")
	check(h.engine.count("[WolfAdmin] warning: et_ConsoleCommand()") == 1,
		"the dormant module reports itself once")

	-- a command storm must not turn into a warning storm (or, before the fix,
	-- into a traceback storm - hence the pcall: the spec reports every
	-- callback below even when an early one raises)
	pcall(et_ConsoleCommand, "time")
	pcall(et_ConsoleCommand, "say hello")
	check(h.engine.count("[WolfAdmin] warning:") == 1, "the warning is not repeated")
end)

-- Every other callback the engine can hit in that window, with the answer the
-- engine expects for "not handled": only the integer 1 intercepts a command,
-- a damage or a weapon fire, only a string rejects a connecting client
-- (G_LuaHook_ClientConnect()/ClientCommand()/Damage()/WeaponFire()/ConsoleCommand()).
test("every engine callback survives the pre-init window", function()
	local h = new_server()

	-- every call is pcalled so a regression is reported for all of them, not
	-- just for the first one that raises (this is how the old code failed)
	local pre_init_calls = {
		{ "et_ConsoleCommand", 0, "status" },
		{ "et_ClientCommand", 0, 3, "kill" },
		{ "et_Damage", 0, 3, 5, 100, 0, 0 },
		{ "et_WeaponFire", 0, 3, 1 },
		{ "et_ClientConnect", nil, 3, true, false },
		{ "et_Obituary", nil, 3, 5, 1 },
		{ "et_ClientSpawn", nil, 3, false },
		{ "et_ClientBegin", nil, 3 },
		{ "et_ClientDisconnect", nil, 3 },
		{ "et_ClientUserinfoChanged", nil, 3 },
		{ "et_RunFrame", nil, 1000 },
		{ "et_ShutdownGame", nil, true },
		-- the vote line et_Print() normally translates
		{ "et_Print", nil, "Vote Passed: [poll] restart\n" },
	}

	for _, spec in ipairs(pre_init_calls) do
		local name, expected = spec[1], spec[2]
		local args, n = {}, #spec - 2
		for i = 1, n do args[i] = spec[i + 2] end

		local ok, result = pcall(_G[name], table.unpack(args, 1, n))

		check(ok, name .. "() does not raise" .. (ok and "" or ": " .. tostring(result)))
		check(ok and result == expected,
			name .. "() answers " .. tostring(expected) .. ", got " .. tostring(result))
	end

	local _, deny = pcall(et_ClientConnect, 3, true, false)
	check(type(deny) ~= "string", "et_ClientConnect() returns no rejection string")

	-- nothing in the tree may be touched while it is not loaded - including
	-- game.getState(), which et_RunFrame() used to index before any guard
	check(count_calls(h) == 0, "no module function was called")
	check(#h.module_calls("game/game") == 0, "game.getState() was never called")

	-- et_SpawnEntitiesFromString() is the one callback that is *meant* to run
	-- before et_InitGame() (the knife reserve, CRASH-REPORT.md); the guard must
	-- not have neutered it
	et_SpawnEntitiesFromString()
	check(type(wolfa_knife_reserve) == "table" and #wolfa_knife_reserve > 0,
		"et_SpawnEntitiesFromString() still builds the knife reserve")
end)

-- And once the engine does call et_InitGame(), the guards disappear: every
-- callback has to behave exactly as it did before (the modules register
-- everything through the real util/events.lua).
test("after et_InitGame() the callbacks reach the module tree", function()
	local h = new_server()
	local events = h.modules["util/events"]
	local seen = {}

	events.handle("onGameInit", function(levelTime, randomSeed, restart)
		seen.init = { levelTime, randomSeed, restart }
	end)
	events.handle("onGameShutdown", function(restart) seen.shutdown = restart end)
	events.handle("onGameFrame", function(levelTime) seen.frame = levelTime end)
	events.handle("onServerCommand", function(cmdText)
		return cmdText == "status" and 1 or 0
	end)
	events.handle("onClientCommand", function() return 1 end)
	events.handle("onClientConnectAttempt", function() return "you are banned" end)
	events.handle("onDamage", function() return 1 end)
	events.handle("onWeaponFire", function() return 1 end)
	events.handle("onPollFinish", function(passed, poll) seen.poll = { passed, poll } end)
	events.handle("onPlayerSpawn", function(clientId) seen.spawn = clientId end)

	et_InitGame(4242, 1337, false)

	check(wolfa_getLuaModsPath() == "luascripts/wolfadmin",
		"the module path comes from the engine's chunk name")
	check(seen.init ~= nil and seen.init[1] == 4242 and seen.init[2] == 1337 and seen.init[3] == false,
		"onGameInit() got (4242, 1337, false)")
	check(h.engine.modname == "WolfAdmin " .. wolfa_getVersion(),
		"et.RegisterModname() registered the module")
	check(#h.engine.consoles == 1 and h.engine.consoles[1].cmd == "sets mod_wolfadmin " .. wolfa_getVersion() .. ";",
		"the mod_wolfadmin cvar is set")
	check(h.engine.consoles[1].exec == h.et.EXEC_APPEND, "as an EXEC_APPEND console command")
	check(h.engine.count("loaded successfully") == 1, "the module announces itself")
	check(h.engine.count("[WolfAdmin] warning:") == 0, "and nothing warns about being uninitialized")

	-- the engine-facing contracts, now with the real event bus in between
	check(et_ConsoleCommand("status") == 1, "a handled console command is intercepted")
	check(et_ConsoleCommand("time") == 0, "an unhandled one is passed to the engine")
	check(et_ClientCommand(3, "kill") == 1, "a handled client command is intercepted")
	check(et_ClientConnect(3, true, false) == "you are banned", "the rejection string reaches the engine")
	check(et_Damage(3, 5, 100, 0, 0) == 1, "damage is intercepted")
	check(et_WeaponFire(3, 1) == 1, "weapon fire is intercepted")

	et_RunFrame(1000)
	check(seen.frame == 1000, "onGameFrame() got the level time")
	check(#h.module_calls("game/game") == 1, "game.getState() is used again")

	et_Print("Vote Passed: [poll] restart\n")
	check(seen.poll ~= nil and seen.poll[1] == true and seen.poll[2] == "restart",
		"et_Print() translates the vote line")

	et_ClientSpawn(7, true)
	check(seen.spawn == 7, "et_ClientSpawn() fires onPlayerSpawn()")

	et_ShutdownGame(false)
	check(seen.shutdown == false, "et_ShutdownGame() fires onGameShutdown()")
end)

-- The other half of the report: when et_InitGame() itself fails (a syntax
-- error, a missing lua library, a bad database setting - the engine prints that
-- once, from G_LuaCall()), the callbacks must not turn every later command and
-- frame into another traceback. They stay inert, and the admin is told why.
test("a failed et_InitGame() leaves the callbacks inert, not broken", function()
	local h = new_server({ fail = "players/stats" })

	local ok, err = pcall(et_InitGame, 1, 2, false)
	check(not ok, "et_InitGame() propagates the module failure")
	check(tostring(err):find("simulated module failure: players/stats", 1, true) ~= nil,
		"with the real cause in the message: " .. tostring(err))

	local okConsole, result = pcall(et_ConsoleCommand, "status")
	check(okConsole and result == 0, "console commands are passed through afterwards")
	check(h.engine.count("[WolfAdmin] warning:") == 1, "the admin is told the module is dormant")
	check(h.engine.count("did not finish loading") == 1, "and that et_InitGame() did not finish")

	check(pcall(et_RunFrame, 1000) == true, "frames are still safe")
	check(pcall(et_ClientCommand, 3, "kill") == true, "client commands are still safe")
	check(count_calls(h) == 0, "and nothing reached the half-loaded tree")
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
