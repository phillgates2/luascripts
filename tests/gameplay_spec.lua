-- Regression tests for the [wolfadmin:gameplay] log spam reported from the
-- live server:
--
--   [wolfadmin:gameplay] warning: client slot 3 has no client fields
--   (tried to get invalid gentity field "ps.weapons") - skipping it for this map
--
-- Root cause: ET:Legacy's Lua field table has no ps.weapons. Every read of it
-- raised, and the module then marked that player's slot as "no client data",
-- which silently turned every gameplay tweak off for them.
--
-- Run with:   lua tests/gameplay_spec.lua [--verbose]
-- Exit code:  0 when everything passes, 1 otherwise.
--
-- tests/et_stub.lua models the g_lua.c field lookup rules, the weapon/ammo
-- pools (bg_misc.c) and SetWolfSpawnWeapons() (g_client.c), so these tests fail
-- on the old code and pass on the fixed one.

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

-- load a module of the tree the way main.lua's wolfa_requireModule() does
local cache = {}
function wolfa_requireModule(name)
	if cache[name] then return cache[name] end
	local chunk = assert(loadfile(ROOT .. name:gsub("%.", "/") .. ".lua"))
	local result = chunk()
	cache[name] = result or true
	return result
end

local function new_server(opts)
	cache = {}
	local engine = stub.new(opts)
	engine.install()
	local events = wolfa_requireModule("util.events")
	wolfa_requireModule("game.gameplay")
	events.trigger("onGameInit", 0, 0, false)
	return engine, events
end

local function client_command(engine, events, num, command)
	engine.parse_command(command)
	return events.trigger("onClientCommand", num, command)
end

-- --------------------------------- tests ---------------------------------

-- The reported symptom: with an ET:Legacy-like field table (no ps.weapons) the
-- module must not report client slots, and the tweaks that need to know what a
-- player carries must keep working.
test("ET:Legacy field table (no ps.weapons)", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	local cv = engine.client

	check(engine.count("tried to get invalid gentity field") == 0,
		"no field errors during init")
	check(engine.count("ps.weapons is not exposed") == 1,
		"one notice about the missing ps.weapons field")
	check(engine.count("has no client data") == 0,
		"no empty-slot reports during init")

	-- four players spawn in the same frame, like a round restart
	engine.connect(3, 2, 0)                                  -- allied soldier
	engine.connect(5, 2, 2)                                  -- allied engineer
	engine.connect(11, 1, 1)                                 -- axis medic
	engine.connect(13, 1, 2)                                 -- axis engineer
	for _, num in ipairs({ 3, 5, 11, 13 }) do
		engine.spawn(num)
		events.trigger("onPlayerSpawn", num, false)
	end
	events.trigger("onGameFrame", 1000)

	check(engine.count("has no client data") == 0,
		"spawning four clients logs no empty-slot lines")
	check(engine.count("tried to get invalid gentity field") == 0,
		"spawning four clients logs no field errors")

	-- throwable knife: the clip is only granted when the knife is detected
	check(cv(3).ps.ammoclip[48] == 5, "allied soldier got the 5-throw kabar clip")
	check(cv(13).ps.ammoclip[1] == 5, "axis engineer got the 5-throw knife clip")

	-- poison needle: medics keep their own needle, everyone else gets one
	check(cv(11).ps.ammoclip[11] == 1, "medic keeps the class syringe")
	check(engine.has_weapon(13, 11), "engineer was given the poison needle")
	check(cv(13).ps.ammoclip[11] == 9,
		"engineer needle adds to the adrenaline pool (1 + 8)")

	-- slot 7 (landmine <-> adrenaline) for an engineer
	check(cv(13).ps.weapon == 3, "engineer starts with the MP40 in hand")
	check(client_command(engine, events, 13, "togglemine") == 1,
		"slot-7 toggle is accepted")
	check(cv(13).ps.weapon == 26, "slot-7 toggle pulled the landmine")
	check(client_command(engine, events, 13, "togglemine") == 1,
		"slot-7 toggle is accepted again")
	check(cv(13).ps.weapon == 44, "slot-7 toggle switched to the adrenaline shot")

	-- slot 5 (needle <-> pliers) for the same engineer
	check(client_command(engine, events, 13, "poisonneedle") == 1,
		"slot-5 toggle is accepted")
	check(cv(13).ps.weapon == 11, "slot-5 toggle switched to the needle")
	check(client_command(engine, events, 13, "poisonneedle") == 1,
		"slot-5 toggle is accepted again")
	check(cv(13).ps.weapon == 21, "slot-5 toggle switched to the pliers")

	-- slot 2 for a soldier whose SMG is the secondary weapon (light weapons
	-- skill); the module used to only look at sess.playerWeapon
	engine.connect(2, 1, 0, { primary = { 23, 20, 10 }, secondary = { 3, 60, 30 } })
	engine.spawn(2)
	events.trigger("onPlayerSpawn", 2, false)
	check(cv(2).sess.playerWeapon == 23 and cv(2).sess.playerWeapon2 == 3,
		"soldier carries a rifle as primary and the SMG as secondary")
	check(client_command(engine, events, 2, "weaponbank 2") == 1,
		"slot-2 command for the SMG secondary is accepted")
	check(cv(2).ps.weapon == 3, "slot-2 command pulled the SMG from the load-out")
	check(cv(2).ps.ammoclip[3] == 30 and cv(2).ps.ammo[3] == 60,
		"slot-2 command left the SMG's clip and reserve alone")

	-- a player who disconnects and comes back into the same slot works again
	events.trigger("onClientDisconnect", 13)
	engine.connect(13, 1, 0)
	engine.spawn(13)
	events.trigger("onPlayerSpawn", 13, false)
	check(client_command(engine, events, 13, "togglemine") == 1,
		"reconnected slot is used again")
	check(engine.count("tried to get invalid gentity field") == 0,
		"no field errors on the second round of spawns")
end)

-- An engine that *does* expose the weapon bitmask must keep using it; the
-- ammo/load-out fallback is only a fallback.
test("engine with ps.weapons bitmask", function()
	local engine, events = new_server({ sv_maxclients = 16, expose_weapon_mask = true })
	local cv = engine.client

	check(engine.count("ps.weapons is not exposed") == 0,
		"no fallback notice when the engine has the field")

	engine.connect(4, 1, 2)                                  -- axis engineer
	engine.spawn(4)
	events.trigger("onPlayerSpawn", 4, false)
	check(engine.has_weapon(4, 26), "engineer owns the landmine (bitmask)")

	-- remove the landmine but leave its ammo pool filled: the bitmask wins
	local c = cv(4)
	c.ps.ammoclip[26] = 1
	et.RemoveWeaponFromPlayer(4, 26)
	check(not engine.has_weapon(4, 26), "bitmask engine: landmine removed")
	check(client_command(engine, events, 4, "togglemine") == 1,
		"slot-7 toggle still accepted")
	check(c.ps.weapon == 44,
		"slot-7 toggle offers only the adrenaline (landmine is gone)")
	check(engine.has_weapon(4, 11), "the needle from the spawn is still detected")
	check(engine.count("has no client data") == 0, "no empty-slot reports")
end)

-- Slots without a gclient_t (reserved slots above g_maxclients, or a mod that
-- keeps g_entities for something else) must be skipped quietly: one line per
-- slot per map, no per-frame spam, and the other players keep working.
test("slots without client data", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	local cv = engine.client

	engine.connect(1, 1, 2)                                  -- axis engineer
	engine.spawn(1)
	events.trigger("onPlayerSpawn", 1, false)

	-- a slot that is inuse but has no gclient_t at all
	engine.ents[9] = { inuse = 1, classname = "not_a_client" }

	for i = 1, 10 do
		events.trigger("onGameFrame", 1000 + i * 50)
	end
	check(engine.count("has no client data") == 1,
		"the empty slot is reported exactly once, not once per frame")
	check(cv(1) ~= nil, "the real client kept its data")

	check(client_command(engine, events, 1, "togglemine") == 1,
		"the real client's slot-7 toggle is unaffected")
	check(cv(1).ps.weapon == 26, "the real client pulled its landmine")
	check(client_command(engine, events, 1, "togglemine") == 1,
		"the real client's second toggle is unaffected")
	check(cv(1).ps.weapon == 44, "the real client reached the adrenaline shot")
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
