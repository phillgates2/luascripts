-- Tests for game/doublejump.lua, the jaymod style double jump, and for
-- commands/admin/doublejump.lua, the toggle that goes with it.
--
-- What the module cannot do is worth repeating here, because it decides the
-- shape of every test below: ET:Legacy's Lua API has no usercmd access at all
-- (etlib[] in g_lua.c has no trap_GetUsercmd and no button state), and the
-- engine only sets PMF_JUMP_HELD in PM_CheckJump(), which never runs off the
-- ground. A jump press in mid air is invisible to Lua. So the module watches
-- the take-off (PMF_JUMP_HELD rising, or ps.velocity[3] snapping back up to
-- JUMP_VELOCITY for a player who keeps jump held) and applies jaymod's boosted
-- jump itself when the player asks for it with the "djump" client command,
-- ducks in the air, or - in auto mode - the moment they leave the ground.
--
-- The engine stub models the parts that matter: FIELD_VEC3 takes one table,
-- ps.pm_flags/ps.eFlags/ps.pm_type/noclip are read-only, and trap_Trace() is a
-- real sweep against level geometry, so "is this player off the floor?" is
-- answered the same way the engine would answer it.
--
-- Run with:   lua tests/doublejump_spec.lua [--verbose]
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

function wolfa_requireLib(name)
	error("the spec harness has no engine lua lib path (" .. tostring(name) .. ")", 0)
end

local cache = {}
function wolfa_requireModule(name)
	if cache[name] then return cache[name] end
	local chunk = assert(loadfile(ROOT .. name:gsub("%.", "/") .. ".lua"))
	local result = chunk()
	cache[name] = result or true
	return result
end

-- the admin commands this spec loads
local admin

-- engine constants the tests drive by hand
local PMF_DUCKED, PMF_JUMP_HELD, PMF_RESPAWNED = 1, 2, 512
local EF_PRONE = 0x00080000
local PM_NORMAL, PM_SPECTATOR, PM_DEAD = 0, 2, 3
local JUMP_VELOCITY = 270             -- bg_local.h:53
local BOOST = 1.4                     -- jaymod's multiplier
local WINDOW = 850                    -- PM_JUMP_DELAY, bg_pmove.c:72
local CONTENTS_SOLID = stub.CONTENTS_SOLID

local function new_server(opts)
	cache = {}
	admin = {}

	local engine = stub.new(opts)
	engine.install()

	cache["commands.commands"] = {
		addadmin = function(name, fn, permission, description, syntax)
			admin[name] = { fn = fn, permission = permission, syntax = syntax or "" }
		end,
		getadmin = function(name) return admin[name] or {} end,
	}
	cache["auth.auth"] = {
		PERM_CHEATS = "cheats",
		canTarget = function() return true end,
		isTargetProtected = function() return false end,
	}
	cache["util.settings"] = {
		get = function(name) return name == "g_standalone" and 0 or nil end,
		set = function() end,
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
	local doublejump = wolfa_requireModule("game.doublejump")
	wolfa_requireModule("commands.admin.doublejump")

	-- a floor at z = 0 across the whole test area
	stub.add_wall(engine, { -2000, -2000, -64 }, { 2000, 2000, 0 }, CONTENTS_SOLID)

	events.trigger("onGameInit", 1000, 0, false)
	events.trigger("onGameFrame", 1000)

	return {
		engine = engine, events = events, timers = timers,
		doublejump = doublejump, time = 1000,
	}
end

-- a player standing on the floor. ps.origin floats 24 above the soles (the
-- player box's z mins is -24, bg_pmove.c:427), so standing on the z = 0 floor
-- is an origin of z = 24 - the ground tests pin that offset. A spectator gets
-- no load-out, the way the engine gives one only to the two playing teams.
local function player(server, num, team, origin)
	team = team or 1
	server.engine.connect(num, team, 0)

	if team == 1 or team == 2 then
		server.engine.spawn(num)
	else
		server.engine.health(num, 100)
	end

	server.engine.place(num, origin or { 0, 0, 24 }, { 0, 0, 0 })
	return num
end

local function frame(server, t)
	server.time = t
	server.events.trigger("onGameFrame", t)
	return t
end

-- what the engine's own state looks like at the moment PM_Jump() succeeds
local function takeoff(server, num, t)
	local c = server.engine.client(num)
	c.ps.pm_flags = PMF_JUMP_HELD      -- PM_Jump() sets it, on the ground only
	c.ps.velocity = { 0, 0, JUMP_VELOCITY }
	frame(server, t)
	return t
end

-- ... and one frame later, in the air with the button let go again
local function inAir(server, num, t, z, vz, keepHeld)
	local c = server.engine.client(num)
	local o = c.ps.origin
	server.engine.place(num, { o[1], o[2], z })
	c.ps.pm_flags = keepHeld and PMF_JUMP_HELD or 0
	c.ps.velocity = { 0, 0, vz or 200 }
	frame(server, t)
	return t
end

local function vz(server, num)
	local v = server.engine.client(num).ps.velocity
	return v and v[3] or nil
end

-- the client command, exactly as et_ClientCommand() delivers it
local function djump(server, num)
	server.engine.parse_command("djump")
	return server.events.trigger("onClientCommand", num, "djump")
end

local function otherCommand(server, num, text)
	server.engine.parse_command(text)
	return server.events.trigger("onClientCommand", num, text)
end

local function sentTo(server, num)
	local out = {}
	for _, c in ipairs(server.engine.commands) do
		if c.num == num or c.num == -1 then out[#out + 1] = c.cmd end
	end
	return table.concat(out, "\n")
end

local function consoleText(server)
	return server.engine.console_text()
end

-- --------------------------------- tests ---------------------------------

test("the module registers with the engine the way main.lua loads it", function()
	local server = new_server({ sv_maxclients = 8 })

	check(type(server.doublejump.ongameframe) == "function", "it polls on onGameFrame")
	check(type(server.doublejump.onclientcommand) == "function", "it owns the djump command")
	check(admin["doublejump"] ~= nil, "!doublejump registered its handler")
	check(server.doublejump.isEnabled(), "on by default")
	check(server.doublejump.getMode() == "command", "and in command mode")
	check(server.doublejump.getWindow() == WINDOW, "jaymod's 850 ms window")
	check(server.doublejump.getBoost() == BOOST, "jaymod's 1.4 multiplier")
end)

test("a jump in the air within the window is boosted", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	takeoff(server, 1, 1050)
	inAir(server, 1, 1100, 60, 200)

	local ret = djump(server, 1)

	check(ret == 1, "the module answers the command, so the engine sees nothing unknown")
	check(vz(server, 1) == JUMP_VELOCITY * BOOST,
		"ps.velocity[2] is JUMP_VELOCITY * 1.4, as PM_CheckDoubleJump writes it")

	local v = server.engine.client(1).ps.velocity
	check(v[1] == 0 and v[2] == 0, "and the horizontal momentum is left alone")
end)

test("only one extra jump per time in the air", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	takeoff(server, 1, 1050)
	inAir(server, 1, 1100, 60, 200)
	djump(server, 1)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "the first one went off")

	-- still in the air, still inside the window: jaymod's PMF_DOUBLEJUMPING
	server.engine.client(1).ps.velocity = { 0, 0, 300 }
	frame(server, 1150)
	djump(server, 1)
	check(vz(server, 1) == 300, "a second air jump in the same airtime does nothing")

	-- the module's own boost must not re-arm the jump it just spent: 378 is
	-- above JUMP_VELOCITY, which is one of the two take-off signals
	frame(server, 1200)
	djump(server, 1)
	check(vz(server, 1) == 300, "and the boosted velocity is not mistaken for a new take-off")
end)

test("the window closes 850 ms after the take-off", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	takeoff(server, 1, 1050)
	inAir(server, 1, 1050 + WINDOW - 50, 200, 100)
	djump(server, 1)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "just inside the window it still works")

	takeoff(server, 1, 5000)
	inAir(server, 1, 5000 + WINDOW + 50, 200, 100)
	djump(server, 1)
	check(vz(server, 1) == 100, "past the window it is refused")
end)

test("a player on the ground does not get an air jump", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	takeoff(server, 1, 1050)
	-- back on the floor: the ground probe at the soles finds the floor again
	inAir(server, 1, 1100, 24, 0)

	djump(server, 1)
	check(vz(server, 1) == 0, "standing on the floor, djump does nothing")
	check(server.doublejump.isAirborne(1) == false, "the trace says the floor is there")

	server.engine.place(1, { 0, 0, 64 })
	check(server.doublejump.isAirborne(1) == true, "and 64 units up it says airborne")
end)

test("jaymod's other refusals: prone, dead, respawned, spectating", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })
	player(server, 2, 3, { 200, 0, 24 })
	player(server, 3, 2, { 400, 0, 24 })

	local c = server.engine.client(1)

	takeoff(server, 1, 1050)
	inAir(server, 1, 1100, 60, 200)

	c.ps.eFlags = EF_PRONE
	djump(server, 1)
	check(vz(server, 1) == 200, "a prone player is refused, as jaymod refuses EF_PRONE")
	c.ps.eFlags = 0

	c.ps.pm_flags = PMF_RESPAWNED
	djump(server, 1)
	check(vz(server, 1) == 200, "PMF_RESPAWNED is refused until the buttons come up")
	c.ps.pm_flags = 0

	c.ps.pm_type = PM_DEAD
	djump(server, 1)
	check(vz(server, 1) == 200, "PM_DEAD is refused")
	c.ps.pm_type = PM_NORMAL

	server.engine.health(1, 0)
	djump(server, 1)
	check(vz(server, 1) == 200, "a corpse is refused")
	server.engine.health(1, 100)

	-- a spectator on the slot 2 client: no team, no double jump
	takeoff(server, 2, 1050)
	inAir(server, 2, 1100, 60, 200)
	server.engine.client(2).ps.pm_type = PM_SPECTATOR
	djump(server, 2)
	check(vz(server, 2) == 200, "a spectator is refused")

	-- and it does work for the other team
	takeoff(server, 3, 1050)
	inAir(server, 3, 1100, 60, 200)
	djump(server, 3)
	check(vz(server, 3) == JUMP_VELOCITY * BOOST, "an allied player gets the same jump")
end)

test("a bunny hop with the jump key held down still counts as a take-off", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	-- first jump: the flag rises
	takeoff(server, 1, 1050)
	inAir(server, 1, 1100, 60, 200, true)
	djump(server, 1)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "the first air jump works with the key held")

	-- land and jump again without ever letting go: PMF_JUMP_HELD never falls, so
	-- there is no edge to see, but the velocity snaps back to JUMP_VELOCITY
	server.engine.client(1).ps.velocity = { 0, 0, -300 }
	server.engine.place(1, { 0, 0, 24 })
	frame(server, 1600)

	server.engine.client(1).ps.velocity = { 0, 0, JUMP_VELOCITY }
	frame(server, 1650)
	server.engine.place(1, { 0, 0, 60 })
	server.engine.client(1).ps.velocity = { 0, 0, 220 }
	frame(server, 1700)

	djump(server, 1)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "the second take-off re-armed the air jump")
end)

test("crouch mode fires on a duck in mid air", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	et.trap_Cvar_Set("g_doublejump_mode", "crouch")
	check(server.doublejump.getMode() == "crouch", "the mode cvar is read live")

	takeoff(server, 1, 1050)
	inAir(server, 1, 1100, 60, 200)

	local ret = djump(server, 1)
	check(ret == 1, "the command is still owned by the module")
	check(vz(server, 1) == 200, "but it does nothing in crouch mode")

	-- PM_CheckDuck() needs no ground, so PMF_DUCKED rises in mid air
	server.engine.client(1).ps.pm_flags = PMF_DUCKED
	frame(server, 1150)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "ducking in the air fired the double jump")

	-- holding the duck does not fire it twice
	frame(server, 1200)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "one duck, one jump")

	et.trap_Cvar_Set("g_doublejump_mode", "command")
end)

test("auto mode boosts every take-off and refuses the key", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	et.trap_Cvar_Set("g_doublejump_mode", "auto")
	check(server.doublejump.getMode() == "auto", "the mode cvar is read live")

	takeoff(server, 1, 1050)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "the take-off left the ground boosted")

	inAir(server, 1, 1100, 60, 300)
	djump(server, 1)
	check(vz(server, 1) == 300, "no second input does anything")
	check(sentTo(server, 1):find("automatic", 1, true) ~= nil,
		"and the player is told the server does it for them")

	et.trap_Cvar_Set("g_doublejump_mode", "command")
end)

test("g_doublejump 0 turns the whole thing off", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	et.trap_Cvar_Set("g_doublejump", "0")
	check(not server.doublejump.isEnabled(), "the cvar is read live")

	takeoff(server, 1, 1050)
	inAir(server, 1, 1100, 60, 200)

	local ret = djump(server, 1)
	check(vz(server, 1) == 200, "no boost while it is off")
	check(ret == 0, "and the module does not even claim the command")

	et.trap_Cvar_Set("g_doublejump", "1")
	takeoff(server, 1, 2050)
	inAir(server, 1, 2100, 60, 200)
	djump(server, 1)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "back on, it works again")
end)

test("!doublejump toggles, reports and retunes", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 0, 1, { 0, 0, 24 })
	player(server, 1, 1, { 128, 0, 24 })

	admin["doublejump"].fn(0, "doublejump", "off")
	check(et.trap_Cvar_Get("g_doublejump") == "0", "!doublejump off writes the cvar")
	check(consoleText(server):find("turned the double jump off", 1, true) ~= nil,
		"and says so on the console")

	admin["doublejump"].fn(0, "doublejump", "on")
	check(et.trap_Cvar_Get("g_doublejump") == "1", "!doublejump on writes it back")
	check(consoleText(server):find("turned the double jump on", 1, true) ~= nil, "and says so")

	admin["doublejump"].fn(0, "doublejump", "status")
	check(consoleText(server):find("window", 1, true) ~= nil
		and consoleText(server):find("850", 1, true) ~= nil, "status reports the window")
	check(consoleText(server):find("1.4", 1, true) ~= nil, "and the boost")

	admin["doublejump"].fn(0, "doublejump", "mode", "crouch")
	check(et.trap_Cvar_Get("g_doublejump_mode") == "crouch", "!doublejump mode writes the cvar")
	admin["doublejump"].fn(0, "doublejump", "mode", "sideways")
	check(et.trap_Cvar_Get("g_doublejump_mode") == "crouch", "an unknown mode is refused")
	check(consoleText(server):find("no such mode", 1, true) ~= nil, "and explained")
	admin["doublejump"].fn(0, "doublejump", "mode", "command")

	admin["doublejump"].fn(0, "doublejump", "boost", "2")
	check(server.doublejump.getBoost() == 2, "!doublejump boost retunes the jump")
	admin["doublejump"].fn(0, "doublejump", "boost", "-1")
	check(server.doublejump.getBoost() == 2, "a negative boost is refused")
	admin["doublejump"].fn(0, "doublejump", "window", "400")
	check(server.doublejump.getWindow() == 400, "!doublejump window retunes the window")
	admin["doublejump"].fn(0, "doublejump", "window", "99999")
	check(server.doublejump.getWindow() == 400, "an absurd window is refused")

	admin["doublejump"].fn(0, "doublejump")
	check(consoleText(server):find("doublejump:", 1, true) ~= nil, "no argument reports the status")
	admin["doublejump"].fn(0, "doublejump", "sideways")
	check(consoleText(server):find("doublejump usage", 1, true) ~= nil,
		"and an argument that is not an action prints the usage")

	-- and the retuned values are what the jump then uses
	et.trap_Cvar_Set("g_doublejump_boost", "1.4")
	takeoff(server, 1, 3050)
	inAir(server, 1, 3100, 60, 200)
	djump(server, 1)
	check(vz(server, 1) == JUMP_VELOCITY * 1.4, "back to jaymod's numbers")
end)

test("players are told how to bind it, once", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	server.events.trigger("onPlayerSpawn", 1, false)
	check(sentTo(server, 1):find("djump", 1, true) ~= nil, "the first spawn explains the bind")
	check(sentTo(server, 1):find("+moveup;djump", 1, true) ~= nil,
		"including how to keep it on the jump key")
	check(sentTo(server, 1):find("cp \"", 1, true) ~= nil, "as a centre print, seen in play")
	check(sentTo(server, 1):find("cpm \"", 1, true) ~= nil, "and again on the message line")
	check(sentTo(server, 1):find("print ", 1, true) == nil,
		"not as a console print, which scrolls past unseen")

	server.engine.commands = {}
	server.events.trigger("onPlayerSpawn", 1, true)
	check(sentTo(server, 1) == "", "and it is not repeated on every respawn")

	-- a new server that has the announcement switched off stays quiet
	local quiet = new_server({ sv_maxclients = 8 })
	et.trap_Cvar_Set("g_doublejump_announce", "0")
	player(quiet, 2, 1, { 0, 0, 24 })
	quiet.events.trigger("onPlayerSpawn", 2, false)
	check(sentTo(quiet, 2) == "", "g_doublejump_announce 0 keeps quiet")
end)

test("a disconnect and a spawn clear the bookkeeping", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	takeoff(server, 1, 1050)
	inAir(server, 1, 1100, 60, 200)
	djump(server, 1)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "the air jump was spent")

	-- the same slot, a new player: no leftover "already used"
	server.events.trigger("onClientDisconnect", 1)
	server.engine.connect(1, 1, 0)
	server.engine.spawn(1)
	server.engine.place(1, { 0, 0, 24 })
	server.events.trigger("onPlayerSpawn", 1, false)

	takeoff(server, 1, 2050)
	inAir(server, 1, 2100, 60, 200)
	djump(server, 1)
	check(vz(server, 1) == JUMP_VELOCITY * BOOST, "whoever takes the slot next gets their own jump")
end)

test("other client commands are left to the engine", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 1, 1, { 0, 0, 24 })

	check(otherCommand(server, 1, "kill") == 0, "kill is not claimed")
	check(otherCommand(server, 1, "+moveup") == 0, "jump is not claimed")
	check(otherCommand(server, 1, "djumpx") == 0, "and neither is a command that merely starts with it")
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
