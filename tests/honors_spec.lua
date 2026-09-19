-- Tests for game/honors.lua (the end-of-map Roll of Honor announced in
-- chat/console). The engine side comes from tests/et_stub.lua, which models
-- the real field table, the WEAPONSTAT read and the session counters.
--
-- Run with:   lua tests/honors_spec.lua [--verbose]
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

-- ----------------------------- module loading ----------------------------

local cache = {}
local fake_players = {
	connected = {},
	guids = {},
	bots = {},
}

function fake_players.isConnected(clientId) return fake_players.connected[clientId] == true end
function fake_players.getName(clientId) return "Player" .. tostring(clientId) end
function fake_players.getGUID(clientId) return fake_players.guids[clientId] end
function fake_players.isBot(clientId) return fake_players.bots[clientId] == true end

function wolfa_requireModule(name)
	if cache[name] then return cache[name] end
	local chunk = assert(loadfile(ROOT .. name:gsub("%.", "/") .. ".lua"))
	local result = chunk()
	cache[name] = result or true
	return result
end

local function new_server(opts)
	cache = {}
	cache["players.players"] = fake_players          -- keep the DB layer out of this
	fake_players.connected, fake_players.guids, fake_players.bots = {}, {}, {}

	local engine = stub.new(opts)
	engine.install()
	local events = wolfa_requireModule("util.events")
	wolfa_requireModule("game.honors")
	events.trigger("onGameInit", 0, 0, false)
	return engine, events
end

local function connect(engine, num, team, opts2)
	opts2 = opts2 or {}
	engine.connect(num, team or 1, 0, opts2)
	fake_players.connected[num] = true
	fake_players.guids[num] = opts2.guid or ("GUID" .. num)
	fake_players.bots[num] = opts2.bot or false
	return engine.client(num)
end

-- what the players see / the server log gets; colour codes are stripped, so
-- the checks read like the line a player sees
local function strip_colors(s) return (tostring(s):gsub("%^%x", "")) end
local function console_text(engine) return strip_colors(engine.console_text()) end
local function has(engine, text) return console_text(engine):find(text, 1, true) ~= nil end

local function end_map(engine, events)
	events.trigger("onGameStateChange", 3)   -- GS_INTERMISSION
end

-- --------------------------------- tests ---------------------------------

test("awards are handed out from the engine's session stats", function()
	local engine, events = new_server({})
	local cv = engine.client

	-- the two leaders of the map
	connect(engine, 0, 1, { guid = "GUID_A" })
	connect(engine, 1, 2, { guid = "GUID_B" })
	engine.set_stats(0, { kills = 34, deaths = 5, gibs = 3, damage_given = 4200,
		time_played = 900000, team_kills = 0, self_kills = 0 })
	engine.set_stats(1, { kills = 12, deaths = 21, gibs = 9, damage_given = 900,
		time_played = 900000, team_kills = 4, self_kills = 2 })
	-- 140 + 90 = 230 XP for slot 0, 40 XP for slot 1
	engine.set_skillpoints(0, 0, 140, 0); engine.set_skillpoints(0, 1, 90, 0)
	engine.set_skillpoints(1, 0, 40, 0)
	-- slot 0 is the knife/headshot/accuracy specialist
	engine.set_weapon_stats(0, 0, { atts = 10, kills = 6 })        -- WS_KNIFE
	engine.set_weapon_stats(0, 22, { atts = 200, hits = 150, kills = 28, headshots = 12 })
	engine.set_weapon_stats(1, 4, { atts = 300, hits = 90, kills = 4, headshots = 2 })   -- WS_MP40

	-- a medic revive for slot 1
	events.trigger("onPlayerRevive", 1, 0)

	end_map(engine, events)

	check(has(engine, "== Roll of Honor =="), "the block is announced")
	check(has(engine, "Deadliest: Player0 (34 kills)"), "most kills")
	check(has(engine, "Headhunter: Player0 (12 headshots)"), "most headshots")
	check(has(engine, "Silent blade: Player0 (6 knife kills)"), "knife kills")
	check(has(engine, "Heavy hitter: Player0 (4200 damage)"), "most damage")
	check(has(engine, "Spray and pray: Player1 (300 shots fired)"), "most shots fired")
	check(has(engine, "Angel of Mercy: Player1 (1 revives)"), "revives are counted per medic")
	check(has(engine, "Most XP earned: Player0 (230 XP)"), "XP is the map XP")
	check(has(engine, "Butcher: Player1 (9 gibs)"), "most gibs")
	check(has(engine, "Cannon fodder: Player1 (21 deaths)"), "most deaths")
	check(has(engine, "Friendly fire: Player1 (4 team kills)"), "team kills")
	check(has(engine, "Suicide king: Player1 (2 self kills)"), "self kills")
	-- 150 hits of 10 knife + 200 rifle shots
	check(has(engine, "Sharp eye: Player0 (71.4% accuracy)"), "accuracy needs a big enough sample")
	check(has(engine, "Iron man: Player0 (15 min played)"), "time played")
	check(has(engine, "Efficient killer: Player0 (6.80 K/D)"), "best K/D among the qualified players")
	check(not has(engine, "Demolitions expert"), "no explosives used, no award")
	check(engine.console_text():find("cchat -1", 1, true) ~= nil, "chat lines are sent to everyone")
	check(not engine.console_text():find("cpm ", 1, true), "no popups in the default mode")
end)

test("weak candidates do not get an award", function()
	local engine, events = new_server({})

	connect(engine, 0, 1)
	engine.set_stats(0, { kills = 2, deaths = 1, time_played = 900000 })
	end_map(engine, events)

	check(not has(engine, "Deadliest"), "2 kills are below the min of the award")
	check(not has(engine, "Cannon fodder"), "1 death is below the min")
	check(not has(engine, "Sharp eye"), "nobody fired enough shots")
	check(has(engine, "Iron man"), "time played has no minimum")
end)

test("a player who leaves keeps his place in the results", function()
	local engine, events = new_server({})

	connect(engine, 0, 1, { guid = "GUID_GONE" })
	connect(engine, 1, 2, { guid = "GUID_STAY" })
	engine.set_stats(0, { kills = 30, deaths = 4, time_played = 400000 })
	engine.set_stats(1, { kills = 8, deaths = 9, time_played = 900000 })

	-- one frame takes a snapshot, then he disconnects
	engine.advance(20000)
	events.trigger("onGameFrame", 100000)
	check(engine.console_count("Roll of Honor") == 0, "nothing is announced mid-map")

	fake_players.connected[0] = false
	engine.ents[0].client = nil
	events.trigger("onClientDisconnect", 0)

	end_map(engine, events)
	check(has(engine, "Deadliest: Player0 (30 kills)"), "the leaver still wins most kills")
end)

test("the running counters survive a slot being reused", function()
	local engine, events = new_server({})

	connect(engine, 3, 1, { guid = "GUID_OLD" })
	engine.set_stats(3, { kills = 40, deaths = 2, time_played = 900000 })
	engine.advance(20000)
	events.trigger("onGameFrame", 100000)
	fake_players.connected[3] = false
	events.trigger("onClientDisconnect", 3)

	-- somebody else joins into slot 3
	connect(engine, 3, 2, { guid = "GUID_NEW" })
	engine.set_stats(3, { kills = 1, deaths = 1, time_played = 30000 })
	engine.advance(20000)
	events.trigger("onGameFrame", 200000)

	end_map(engine, events)
	check(has(engine, "Deadliest: Player3 (40 kills)"),
		"the first player's kills are still ranked, the new player adds his own")
end)

test("counting never goes backwards when a snapshot lags", function()
	local engine, events = new_server({})

	connect(engine, 0, 1)
	engine.set_stats(0, { kills = 20, time_played = 900000 })
	engine.advance(20000)
	events.trigger("onGameFrame", 100000)
	engine.set_stats(0, { kills = 3 })                 -- a read that lags behind
	engine.advance(20000)
	events.trigger("onGameFrame", 200000)
	engine.set_stats(0, { kills = 21 })
	end_map(engine, events)

	check(has(engine, "Deadliest: Player0 (21 kills)"), "the highest value seen wins")
end)

test("kill streaks are tracked from the obituary", function()
	local engine, events = new_server({})

	connect(engine, 0, 1, { guid = "GUID_A" })
	connect(engine, 1, 2, { guid = "GUID_B" })
	engine.set_stats(0, { time_played = 900000 })
	engine.set_stats(1, { time_played = 900000 })

	for i = 1, 7 do
		events.trigger("onPlayerDeath", 1, 0, 5)       -- MOD_KNIFE
	end
	end_map(engine, events)

	check(has(engine, "Killing machine: Player0 (7 kill spree)"), "the streak is announced")
end)

test("bots are left out unless they are asked for", function()
	local engine, events = new_server({})

	connect(engine, 0, 1, { guid = "GUID_BOT", bot = true })
	connect(engine, 1, 2, { guid = "GUID_HUMAN" })
	engine.set_stats(0, { kills = 50, time_played = 900000 })
	engine.set_stats(1, { kills = 5, time_played = 900000 })

	end_map(engine, events)
	check(not has(engine, "Player0"), "a bot does not win by default")
	check(has(engine, "Deadliest: Player1 (5 kills)"), "the human takes the award instead")
end)

test("g_honors_bots 1 lets the bots compete", function()
	local engine, events = new_server({})

	connect(engine, 0, 1, { guid = "GUID_BOT", bot = true })
	connect(engine, 1, 2, { guid = "GUID_HUMAN" })
	engine.set_stats(0, { kills = 50, time_played = 900000 })
	engine.set_stats(1, { kills = 5, time_played = 900000 })
	engine.cvars.g_honors_bots = "1"

	end_map(engine, events)
	check(has(engine, "Deadliest: Player0 (50 kills)"), "the bot takes the award")
end)

test("the announcement mode can be changed", function()
	local engine, events = new_server({})

	connect(engine, 0, 1)
	engine.set_stats(0, { kills = 10, time_played = 900000, self_kills = 3, deaths = 9,
		gibs = 2, damage_given = 500 })
	engine.cvars.g_honors_messages = "2"          -- popups only
	end_map(engine, events)

	check(engine.console_text():find("cpm ", 1, true) ~= nil, "popups are used")
	check(not engine.console_text():find("cchat -1", 1, true), "no chat lines in popup mode")
end)

test("g_honors 0 turns the module off", function()
	local engine, events = new_server({})

	connect(engine, 0, 1)
	engine.set_stats(0, { kills = 99, time_played = 900000 })
	engine.cvars.g_honors = "0"

	end_map(engine, events)
	check(console_text(engine) == "", "nothing is announced")
	check(engine.count("Roll of Honor ready") == 1, "only the startup line is logged")
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
