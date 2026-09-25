-- Strict live-server simulation for the throwable knife.
--
-- Every earlier spec passed while the live server reported "throw knife not
-- working", because the harness was kinder than ET:Legacy's g_lua.c in three
-- ways that all sit on the throw path:
--
--   * ps.viewheight is NOT in gclient_fields (verified against etlegacy
--     master src/game/g_lua.c) - the stub hands it out, the engine raises
--     "tried to get invalid gentity field \"ps.viewheight\"".
--   * et.MAX_GENTITIES is NOT a registered constant (registerConstants()
--     never adds it) - code must fall back to 1024.
--   * the reserve is built by main.lua's REAL et_SpawnEntitiesFromString();
--     every spec so far reimplemented that loop instead of running it.
--
-- Run: lua tests/live_sim.lua [--verbose]

local HERE = (...) and debug.getinfo(1, "S").source:match("@(.*/)") or "./tests/"
if HERE == "" then HERE = "./tests/" end
local ROOT = HERE .. "../"

local stub = dofile(HERE .. "et_stub.lua")

local VERBOSE = arg and arg[1] == "--verbose"

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

local cache = {}
function wolfa_requireModule(name)
	if cache[name] then return cache[name] end
	local chunk = assert(loadfile(ROOT .. name:gsub("%.", "/") .. ".lua"))
	local result = chunk()
	cache[name] = result or true
	return result
end

-- load ONLY et_SpawnEntitiesFromString out of main.lua (the file as a whole
-- needs the full wolfa module system). The function text is taken verbatim so
-- the sim runs the shipped code, not a copy of it.
local function load_main_reserve_fn()
	local lines = {}
	for line in io.lines(ROOT .. "main.lua") do
		lines[#lines + 1] = line
	end
	local start_at, stop_at
	for i, line in ipairs(lines) do
		if not start_at then
			if line:match("^function et_SpawnEntitiesFromString%s*%(") then
				start_at = i
			end
		elseif line == "end" then
			stop_at = i
			break
		end
	end
	assert(start_at and stop_at, "main.lua has no et_SpawnEntitiesFromString")
	local body = table.concat(lines, "\n", start_at, stop_at)
	local chunk = assert((loadstring or load)(body .. "\nreturn et_SpawnEntitiesFromString", "main.lua"))
	return chunk()
end

-- Engine truth: gclient_fields has no ps.viewheight. The stub models it; wrap
-- the getter so every read fails exactly the way the engine's field lookup
-- fails. Must be installed BEFORE game.gameplay's fields.probe() runs at
-- onGameInit - that probe is what keeps one missing field from poisoning a
-- whole client slot.
local function hide_viewheight()
	local old_get = et.gentity_get
	et.gentity_get = function(num, name, index)
		if name == "ps.viewheight" then
			error("tried to get invalid gentity field \"ps.viewheight\"", 0)
		end
		return old_get(num, name, index)
	end
end

local KNIFE_MAX_LIVE = 12

local function new_server(opts)
	cache = {}
	local engine = stub.new(opts)
	engine.install()

	local events = wolfa_requireModule("util.events")
	events.handle("onClientCommand", stub.wolfadmin_client_command(engine))

	-- engine truth: registerConstants() never registers MAX_GENTITIES
	et.MAX_GENTITIES = nil
	hide_viewheight()

	-- engine order (g_main.c G_InitGame): G_LuaInit, G_SpawnEntitiesFromString
	-- (level.spawning - the only window G_CreateEntity is legal in), then
	-- G_LuaHook_InitGame which loads the modules and fires onGameInit.
	local build_reserve = load_main_reserve_fn()
	build_reserve()
	wolfa_requireModule("game.gameplay")
	events.trigger("onGameInit", 0, 0, false)
	return engine, events
end

local function player(engine, events, num, team, class, origin, viewangles)
	engine.connect(num, team, class)
	engine.spawn(num)
	events.trigger("onPlayerSpawn", num, false)
	engine.place(num, origin or { 0, 0, 0 }, viewangles or { 0, 0, 0 })
	return engine.client(num)
end

local function client_command(engine, events, num, command)
	engine.parse_command(command)
	return events.trigger("onClientCommand", num, command)
end

-- what a player does: pull the knife out (the engine puts it in hand), throw
local function throw(engine, events, num, weapon, levelTime)
	local c = engine.client(num)
	if c and c.ps then
		local ammo = c.ps.ammo[weapon] or 0
		local clip = c.ps.ammoclip[weapon] or 0
		pcall(et.AddWeaponToPlayer, num, weapon, ammo, clip, 1)
	end
	events.trigger("onGameFrame", levelTime)
	local before = #engine.link_log
	local ret = client_command(engine, events, num, "throwknife")
	local linked = #engine.link_log > before
		and engine.link_log[#engine.link_log].number or nil
	return ret, linked
end

-- what a player actually does on a stock client: left-click the knife
-- (et_WeaponFire). Right-click's "weapalt" is consumed by cgame and never
-- reaches the server, so this path is the feature's out-of-the-box trigger.
local function fire_knife(engine, events, num, weapon, levelTime)
	local c = engine.client(num)
	if c and c.ps then
		local ammo = c.ps.ammo[weapon] or 0
		local clip = c.ps.ammoclip[weapon] or 0
		pcall(et.AddWeaponToPlayer, num, weapon, ammo, clip, 1)
	end
	events.trigger("onGameFrame", levelTime)
	local before = #engine.link_log
	local ret = events.trigger("onWeaponFire", num, weapon)
	local linked = #engine.link_log > before
		and engine.link_log[#engine.link_log].number or nil
	return ret, linked
end

local function live_knife(engine, ent)
	local e = ent and engine.ents[ent]
	return e ~= nil and e.inuse == 1 and e.classname == "target_position" and e.r.linked
end

local TEAM_AXIS, TEAM_ALLIES = 1, 2
local PC_SOLDIER = 0
local WP_KNIFE, WP_KNIFE_KABAR = 1, 48
local KNIFE_CLIP_MAX = 5

test("main.lua's own reserve builder produces a usable reserve", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	check(#engine.gent_create_log == KNIFE_MAX_LIVE,
		"et_SpawnEntitiesFromString created " .. KNIFE_MAX_LIVE .. " entities")
	for _, cr in ipairs(engine.gent_create_log) do
		check(type(cr.number) == "number" and cr.number >= 64 and cr.number < 1024,
			"entity number " .. tostring(cr.number) .. " is in g_entities range")
	end
	local parked = 0
	for _, cr in ipairs(engine.gent_create_log) do
		local e = engine.ents[cr.number]
		if e and e.inuse == 1 and e.classname == "target_position" and not e.r.linked then
			parked = parked + 1
		end
	end
	check(parked == KNIFE_MAX_LIVE, "all reserve slots are parked unlinked target_positions")

	player(engine, events, 3, TEAM_ALLIES, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	local ret, ent = throw(engine, events, 3, WP_KNIFE_KABAR, 1000)
	check(ret == 1, "the throwknife command throws with main.lua's real reserve")
	check(ent ~= nil and live_knife(engine, ent), "a parked knife was handed out and linked")
end)

test("the throw survives an engine without ps.viewheight", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	local c = player(engine, events, 3, TEAM_AXIS, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	check(c.ps.ammoclip[WP_KNIFE] == KNIFE_CLIP_MAX,
		"the clip is granted at spawn without ps.viewheight")
	local ret, ent = throw(engine, events, 3, WP_KNIFE, 1000)
	check(ret == 1 and ent ~= nil, "the throw still goes out")
	local e = ent and engine.ents[ent]
	check(e and math.abs(e.r.currentOrigin[1] - 16) < 0.5,
		"the knife starts 16 units out in front of the eyes")
	check(c.ps.ammoclip[WP_KNIFE] == KNIFE_CLIP_MAX - 1, "and spends a throw")
end)

test("both knives work, axis and allies", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	player(engine, events, 2, TEAM_AXIS, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	player(engine, events, 5, TEAM_ALLIES, PC_SOLDIER, { 200, 0, 0 }, { 0, 0, 0 })
	local r1, e1 = throw(engine, events, 2, WP_KNIFE, 1000)
	local r2, e2 = throw(engine, events, 5, WP_KNIFE_KABAR, 1000)
	check(r1 == 1 and e1, "the axis knife (WP_KNIFE) throws")
	check(r2 == 1 and e2, "the allies knife (WP_KNIFE_KABAR) throws")
end)

test("left-click (et_WeaponFire) throws with no client bind at all", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	local c = player(engine, events, 3, TEAM_AXIS, PC_SOLDIER, { 0, 0, 0 }, { 0, 0, 0 })
	local ret, ent = fire_knife(engine, events, 3, WP_KNIFE, 1000)
	check(ret == 1 and ent ~= nil, "the fire hook throws - the stock click reaches the server")
	check(live_knife(engine, ent), "and links a parked knife from main.lua's reserve")
	check(c.ps.ammoclip[WP_KNIFE] == KNIFE_CLIP_MAX - 1, "and spends a throw")
	-- inside the 800 ms cooldown the fire falls through to the melee stab
	local ret2 = fire_knife(engine, events, 3, WP_KNIFE, 1000 + 100)
	check(ret2 == 0, "a refused throw falls through to the engine's melee stab")
end)

print("")
if #failures > 0 then
	print(("%d of %d checks FAILED:"):format(#failures, checks))
	for _, f in ipairs(failures) do print("  - " .. f) end
	os.exit(1)
end
print(("%d checks passed"):format(checks))
os.exit(0)
