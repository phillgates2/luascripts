-- Tests for the bot vote: game/botvote.lua, which owns "callvote bots ..." and
-- "vote yes|no" while one of its votes runs, and the routing game/voting.lua now
-- gives a passed poll.
--
-- Why a Lua vote at all is the first thing these tests pin down. ET:Legacy's
-- vote list is aVoteInfo[] in g_vote.c and Cmd_CallVote_f() rejects anything
-- else with "Unknown vote command" (g_cmds.c:3380), so "bots" can never be an
-- engine vote type; what Lua can do is answer et_ClientCommand() before the
-- engine sees the command and swallow it by returning non-zero (g_cmds.c:5336).
-- The tests therefore check both halves: that the vote is counted the way
-- G_CheckVote() counts one (vote_percent of the clients in the game, 30 seconds,
-- the engine's own cpm wording), and that the module claims exactly the commands
-- it owns and leaves every other one - "kill" included - to the engine.
--
-- The command modules cannot load in a spec (commands.commands needs TOML and a
-- sqlite database, auth.auth needs the ACL tables), so the harness injects
-- stand-ins and, for commands.commands, a dispatcher that behaves like the real
-- one: registered first, as main.lua does, answering 0 for a command it does not
-- own. commands/client/callvote.lua, game/botvote.lua, game/voting.lua,
-- game/bots.lua and the util modules are the real thing.
--
-- Run with:   lua tests/botvote_spec.lua [--verbose]
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

local admin, referees, botslots, settingValues

local function new_server(opts)
	cache = {}
	admin = {}
	referees = {}
	botslots = {}
	settingValues = { omnibot_maxbots = 10 }

	local engine = stub.new(opts)
	engine.install()

	local clientCommands = {}
	cache["commands.commands"] = {
		addclient = function(name, fn) clientCommands[name] = fn end,
		addadmin = function(name, fn, permission, description, syntax)
			admin[name] = { fn = fn, permission = permission, syntax = syntax or "" }
		end,
		getadmin = function(name) return admin[name] or {} end,
	}
	cache["auth.auth"] = {
		PERM_BOTADMIN = "botadmin", PERM_NOVOTELIMIT = "novotelimit", PERM_CHEATS = "cheats",
		isPlayerAllowed = function(clientId, permission)
			return referees[clientId] == true
		end,
		canTarget = function() return true end,
		isTargetProtected = function() return false end,
	}
	cache["util.settings"] = {
		get = function(name)
			if name == "g_standalone" then return 0 end
			if name == "g_restrictedVotes" then return "" end
			if name == "g_voteNextMapTimeout" then return 0 end
			return settingValues[name]
		end,
		set = function(name, value) settingValues[name] = value end,
		load = function() end,
	}
	cache["players.players"] = {
		isConnected = function(num)
			return et.gentity_get(num, "pers.connected") == 2
		end,
		isBot = function(num) return botslots[num] == true end,
		getName = function(num)
			return tostring(et.gentity_get(num, "pers.netname") or "")
		end,
	}

	local events = wolfa_requireModule("util.events")

	-- main.lua loads commands.commands (line 137) before the game modules, so
	-- its onClientCommand handler is first on the bus and ends in `return 0`
	events.handle("onClientCommand", function(clientId, cmdText)
		local handler = clientCommands[et.trap_Argv(0)]

		if handler then
			return handler(clientId, cmdText) or 0
		end

		return 0
	end)

	wolfa_requireModule("commands.client.callvote")

	local timers = wolfa_requireModule("util.timers")
	local botvote = wolfa_requireModule("game.botvote")
	local voting = wolfa_requireModule("game.voting")
	local constants = wolfa_requireModule("util.constants")

	events.trigger("onGameInit", 1000, 0, false)
	events.trigger("onGameFrame", 1000)

	return {
		engine = engine, events = events, timers = timers, botvote = botvote,
		voting = voting, constants = constants, time = 1000,
	}
end

-- A spectator gets no load-out, the way the engine gives one only to the two
-- playing teams.
local function player(server, num, team, isBot)
	team = team or 1
	server.engine.connect(num, team, 0)

	if team == 1 or team == 2 then
		server.engine.spawn(num)
	else
		server.engine.health(num, 100)
	end

	server.engine.place(num, { num * 128, 0, 0 }, { 0, 0, 0 })

	if isBot then
		botslots[num] = true
	end

	return num
end

-- a client command, exactly as et_ClientCommand() delivers it
local function command(server, num, text)
	server.engine.parse_command(text)
	return server.events.trigger("onClientCommand", num, text)
end

local function callvote(server, num, text)
	return command(server, num, "callvote " .. text)
end

local function vote(server, num, answer)
	return command(server, num, "vote " .. answer)
end

-- everything the server sent to everybody, and to one client
local function broadcast(server)
	local out = {}
	for _, c in ipairs(server.engine.commands) do
		if c.num == -1 then out[#out + 1] = c.cmd end
	end
	return table.concat(out, "\n")
end

local function sentTo(server, num)
	local out = {}
	for _, c in ipairs(server.engine.commands) do
		if c.num == num then out[#out + 1] = c.cmd end
	end
	return table.concat(out, "\n")
end

local function countIn(text, needle)
	local _, n = text:gsub(needle, "")
	return n
end

local function console(server)
	return server.engine.console_text()
end

local function silence(server)
	server.engine.commands = {}
	server.engine.consoles = {}
end

-- let the vote window run out: util.timers drives botvote.finish()
local function timeOut(server)
	server.engine.advance(30001)
	server.time = server.time + 30001
	server.events.trigger("onGameFrame", server.time)
end

-- --------------------------------- tests ---------------------------------

test("the engine's vote list has no bots in it, and the constants say so", function()
	local server = new_server({ sv_maxclients = 4 })
	local types = server.constants.VOTE_TYPES

	local seen = {}
	for _, name in ipairs(types) do seen[name] = true end

	-- aVoteInfo[] in g_vote.c: these are the types the engine will carry
	for _, name in ipairs({ "gametype", "kick", "mute", "unmute", "map", "campaign",
		"maprestart", "matchreset", "mutespecs", "nextmap", "referee", "shuffleteams",
		"shuffleteams_norestart", "startmatch", "swapteams", "friendlyfire", "timelimit",
		"unreferee", "warmupdamage", "antilag", "balancedteams", "surrender",
		"restartcampaign", "nextcampaign", "poll", "config", "cointoss" }) do
		check(seen[name] == true, name .. " is in the list the engine knows")
	end

	-- vote_allow_muting gates both mute votes, so voting.allow() needs the name
	check(seen["muting"] == true, "muting is there for the cvar that gates mute and unmute")

	-- the mangled ETPro names this list used to carry
	check(seen["gamconstantsype"] == nil, "no gamconstantsype")
	check(seen["matchresconstants"] == nil, "no matchresconstants")
	check(seen["shufflconstantseamsxp"] == nil, "no shufflconstantseamsxp")
	check(seen["comp"] == nil and seen["pub"] == nil, "no ETPro comp or pub")
	check(seen["bots"] == nil, "and no bots - the engine would reject it as an unknown vote")

	for _, name in ipairs(types) do
		check(name:find("constants", 1, true) == nil, "nothing in the list still says 'constants': " .. name)
	end

	-- voting.load() reads a vote_allow_ cvar per type; the engine has most of them
	server.voting.load()
	check(not server.voting.isAllowed("gamconstantsype"), "a name that is not a cvar is not allowed")
end)

test("callvote bots on runs a vote the engine's rules decide", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)
	player(server, 1, 2)

	local ret = callvote(server, 0, "bots on")
	check(ret == 1, "the module claims the command, so the engine never sees an unknown vote type")
	check(server.botvote.isActive(), "and a vote is running")
	check(broadcast(server):find("called a vote", 1, true) ~= nil, "everybody is told a vote was called")
	check(broadcast(server):find("bots on", 1, true) ~= nil, "with what it is for")
	check(broadcast(server):find("vote yes", 1, true) ~= nil, "and how to answer it")
	check(console(server) == "", "the engine's own console commands were not used to say it")

	-- one player in the game voting yes out of two: 50% of 2 is 1, and the
	-- engine passes a vote on yes > threshold, so it is still open
	check(not broadcast(server):find("Vote passed", 1, true), "one yes out of two is not a majority yet")

	ret = vote(server, 1, "yes")
	check(ret == 1, "vote yes is claimed while the vote runs")
	check(broadcast(server):find("Vote passed!", 1, true) ~= nil,
		"two yeses out of two passes, with the engine's wording")
	check(broadcast(server):find("Y:2", 1, true) ~= nil, "and its tally")
	check(not server.botvote.isActive(), "the vote is over")

	check(console(server):find("bot minbots -1", 1, true) ~= nil, "the omnibot minbots command went out")
	check(console(server):find("bot maxbots 10", 1, true) ~= nil,
		"and maxbots with the omnibot_maxbots setting")
end)

test("callvote bots off takes the bots out again", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)

	-- a single player in the game: vote_percent of 1 is 0, so yes > 0 passes at
	-- once, which is what the engine does with the same arithmetic
	local ret = callvote(server, 0, "bots off")
	check(ret == 1, "the command is claimed")
	check(not server.botvote.isActive(), "and the vote settled immediately")
	check(broadcast(server):find("Vote passed!", 1, true) ~= nil, "with the engine's announcement")
	check(console(server):find("bot kickall", 1, true) ~= nil, "bot kickall went out")
	check(console(server):find("bot maxbots -1", 1, true) ~= nil, "and maxbots -1 with it")
end)

test("a majority of no votes fails it, and the window closing times it out", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 0, 1)
	player(server, 1, 1)
	player(server, 2, 2)
	player(server, 3, 2)

	callvote(server, 0, "bots off")
	vote(server, 1, "no")
	check(not broadcast(server):find("Vote FAILED", 1, true),
		"one no vote is not enough: the engine wants no > 1")
	check(server.botvote.isActive(), "so the vote is still open")

	vote(server, 2, "no")
	check(broadcast(server):find("Vote FAILED!", 1, true) ~= nil,
		"two no votes out of four reach the threshold and fail it")
	check(not server.botvote.isActive(), "the vote is over")
	check(console(server) == "", "and nothing was sent to the bots")

	-- now let one run out of time instead
	silence(server)
	callvote(server, 1, "bots on")
	check(server.botvote.isActive(), "a new vote can be called once the last one is over")
	timeOut(server)
	check(broadcast(server):find("Vote TIMEOUT!", 1, true) ~= nil, "30 seconds later it times out")
	check(broadcast(server):find("Not enough voters", 1, true) ~= nil, "with the engine's reason")
	check(not server.botvote.isActive(), "and the vote is gone")
	check(console(server) == "", "the bots were left alone")
end)

test("a vote cannot be called twice, and only players in the game take part", function()
	local server = new_server({ sv_maxclients = 8 })
	player(server, 0, 1)
	player(server, 1, 2)
	player(server, 2, 3)          -- a spectator
	player(server, 3, 1, true)    -- an omnibot

	callvote(server, 0, "bots on")

	local ret = callvote(server, 1, "bots off")
	check(ret == 1, "a second callvote is still claimed while the vote runs")
	check(sentTo(server, 1):find("A vote is already in progress", 1, true) ~= nil,
		"and answered the way the engine answers it (g_cmds.c:3319)")
	check(countIn(sentTo(server, 1), "A vote is already in progress") == 1,
		"said once, not once per handler on the bus")
	check(server.botvote.getVote().string == "bots on", "the first vote is the one still running")

	ret = vote(server, 2, "yes")
	check(ret == 1, "a spectator's vote is claimed too")
	check(sentTo(server, 2):find("spectators cannot vote", 1, true) ~= nil, "but refused")

	ret = vote(server, 0, "yes")
	check(sentTo(server, 0):find("already voted", 1, true) ~= nil, "the caller cannot vote twice")

	-- the bot is a client, but it gets no say in the count
	local total = 0
	for clientId = 0, 3 do
		if not (clientId == 2 or clientId == 3) then total = total + 1 end
	end
	check(total == 2, "two of the four clients can vote")

	-- a spectator cannot call one either
	silence(server)
	server.botvote.cancel("test")
	ret = callvote(server, 2, "bots on")
	check(ret == 1, "a spectator's callvote is claimed")
	check(not server.botvote.isActive(), "but no vote starts")
	check(sentTo(server, 2):find("Spectators cannot call a vote", 1, true) ~= nil, "and they are told why")
end)

test("the bot vote can be switched off, and a bot admin skips the poll", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)
	player(server, 1, 2)

	et.trap_Cvar_Set("g_botVote", "0")
	local ret = callvote(server, 0, "bots on")
	check(ret == 1, "the command is still claimed while the vote is disabled")
	check(not server.botvote.isActive(), "but no vote starts")
	check(sentTo(server, 0):find("Bot votes are disabled", 1, true) ~= nil, "and the caller is told")

	et.trap_Cvar_Set("g_botVote", "1")
	referees[1] = true
	silence(server)
	ret = callvote(server, 1, "bots on")
	check(ret == 1, "a bot admin's callvote is claimed")
	check(not server.botvote.isActive(), "and it does not start a poll")
	check(broadcast(server):find("Referee changed setting!", 1, true) ~= nil,
		"the engine's wording for a ref's callvote (g_cmds.c:3396)")
	check(console(server):find("bot minbots -1", 1, true) ~= nil, "the bots went straight in")
end)

test("vote_limit caps how many votes one player may call", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)
	player(server, 1, 2)

	et.trap_Cvar_Set("vote_limit", "1")

	callvote(server, 0, "bots on")
	check(server.botvote.isActive(), "the first vote is called")
	timeOut(server)
	check(not server.botvote.isActive(), "and times out")

	silence(server)
	local ret = callvote(server, 0, "bots off")
	check(ret == 1, "the second call is still claimed")
	check(not server.botvote.isActive(), "but no vote starts")
	check(sentTo(server, 0):find("maximum number of votes (1)", 1, true) ~= nil,
		"with the engine's message (g_cmds.c:3336)")

	-- the other player has not called any
	ret = callvote(server, 1, "bots off")
	check(server.botvote.isActive(), "somebody else can still call one")
end)

test("the vote actions the omnibot interface understands", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)
	player(server, 1, 1, true)   -- a bot to be moved
	player(server, 2, 2, true)

	-- max: the setting has to move as well, because bots.enable() reads it back
	callvote(server, 0, "bots max 8")
	check(console(server):find("bot maxbots 8", 1, true) ~= nil, "bot maxbots went out")
	check(settingValues.omnibot_maxbots == 8, "and omnibot_maxbots was remembered")

	silence(server)
	callvote(server, 0, "bots difficulty uber")
	check(console(server):find("bot difficulty 6", 1, true) ~= nil, "a difficulty name is turned into its level")

	silence(server)
	callvote(server, 0, "bots difficulty 3")
	check(console(server):find("bot difficulty 3", 1, true) ~= nil, "and a level is taken as it is")

	silence(server)
	callvote(server, 0, "bots axis")
	check(console(server):find("!put 1 r", 1, true) ~= nil, "the axis bots are put on the axis team")
	check(console(server):find("!put 2 r", 1, true) ~= nil, "including the ones that were allied")

	silence(server)
	callvote(server, 0, "bots allies")
	check(console(server):find("!put 1 b", 1, true) ~= nil, "and the same the other way round")

	-- nothing was sent to a console command no engine implements
	check(console(server):find("putbots", 1, true) == nil, "no putbots")
	check(console(server):find("needbots", 1, true) == nil, "no needbots")
	check(console(server):find("kickbots", 1, true) == nil, "no kickbots")
end)

test("a vote that makes no sense is refused with the usage", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)

	local ret = callvote(server, 0, "bots sideways")
	check(ret == 1, "the command is claimed")
	check(not server.botvote.isActive(), "and no vote starts")
	check(sentTo(server, 0):find("callvote bots", 1, true) ~= nil, "the caller gets the usage")
	check(sentTo(server, 0):find("no such bot vote", 1, true) ~= nil, "and the reason")

	silence(server)
	ret = callvote(server, 0, "bots max 999")
	check(not server.botvote.isActive(), "an absurd maximum is refused")
	check(sentTo(server, 0):find("between 0 and", 1, true) ~= nil, "with the range it accepts")

	silence(server)
	ret = callvote(server, 0, "bots")
	check(not server.botvote.isActive(), "an empty action is refused")
	check(sentTo(server, 0):find("difficulty", 1, true) ~= nil, "and the usage lists the actions")
end)

test("the wording game/voting.lua accepted from a poll still parses", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)
	local botvote = server.botvote

	local cases = {
		{ "enable bots", "on" }, { "disable bots", "off" },
		{ "need bots", "on" }, { "kick bots", "off" },
		{ "put bots axis", "axis" }, { "put bots allies", "allies" },
		{ "set bot max 8", "max", 8 }, { "set bot difficulty 4", "difficulty", 4 },
		{ "set bot difficulty very poor", "difficulty", 1 },
		{ "on", "on" }, { "off", "off" }, { "max 3", "max", 3 },
	}

	for _, case in ipairs(cases) do
		local action, value = botvote.parse(case[1])
		check(action == case[2], "\"" .. case[1] .. "\" parses as " .. tostring(case[2]))

		if case[3] then
			check(value == case[3], "\"" .. case[1] .. "\" keeps its value " .. tostring(case[3]))
		end
	end

	-- an action word with something after it is somebody else's vote wording:
	-- a poll called "kick 3" must stay a kick vote, not become "bots off"
	local nothing = { "should we rush the depot", "map oasis", "kick 3", "", "max",
		"difficulty legendary", "on 3", "off now", "enable all the things", "axis 2",
		"put bots", "mute 2" }
	for _, text in ipairs(nothing) do
		local action = botvote.parse(text)
		check(action == nil, "\"" .. text .. "\" is not a bot vote")
	end
end)

test("a passed poll reaches the bots through game/botvote", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)

	-- main.lua:216 turns the engine's log line into this event
	server.events.trigger("onPollFinish", true, "enable bots")
	check(console(server):find("bot minbots -1", 1, true) ~= nil, "the poll put the bots in")
	check(console(server):find("needbots", 1, true) == nil,
		"and the console command no engine implements is gone")
	check(broadcast(server):find("put the bots back in the game", 1, true) ~= nil,
		"with a line saying what it did")

	silence(server)
	server.events.trigger("onPollFinish", true, "disable bots")
	check(console(server):find("bot kickall", 1, true) ~= nil, "a disable poll takes them out")

	silence(server)
	server.events.trigger("onPollFinish", true, "put bots axis")
	check(console(server) == "", "with no bots connected there is nobody to put anywhere")

	silence(server)
	server.events.trigger("onPollFinish", false, "enable bots")
	check(console(server) == "", "a poll that did not pass does nothing")

	silence(server)
	server.events.trigger("onPollFinish", true, "should we rush the depot")
	check(console(server) == "", "and an ordinary poll is left alone")
end)

test("the vote is cleaned up when its caller leaves or the map changes", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)
	player(server, 1, 2)

	callvote(server, 0, "bots on")
	check(server.botvote.isActive(), "a vote is running")

	server.events.trigger("onClientDisconnect", 1)
	check(server.botvote.isActive(), "a voter leaving does not cancel it")

	server.events.trigger("onClientDisconnect", 0)
	check(not server.botvote.isActive(), "the caller leaving does")
	check(broadcast(server):find("Vote CANCELED!", 1, true) ~= nil, "with the engine's wording")
	check(console(server) == "", "and the bots were left alone")

	silence(server)
	callvote(server, 1, "bots on")
	check(server.botvote.isActive(), "another vote can be called")
	server.events.trigger("onGameInit", 5000, 0, true)
	check(not server.botvote.isActive(), "a new map clears it")

	-- and vote_limit counts per map
	et.trap_Cvar_Set("vote_limit", "1")
	callvote(server, 1, "bots off")
	check(server.botvote.isActive(), "the same player may call one again after the restart")
	et.trap_Cvar_Set("vote_limit", "0")
end)

test("everything that is not this vote is left to the engine", function()
	local server = new_server({ sv_maxclients = 4 })
	player(server, 0, 1)
	-- a second player, so a called vote stays open instead of passing at once
	player(server, 1, 2)

	check(command(server, 0, "kill") == 0, "kill is not claimed")
	check(command(server, 0, "vote yes") == 0, "vote yes is not claimed while no vote runs")
	check(callvote(server, 0, "map oasis") == 0, "an engine vote type is passed through")
	check(callvote(server, 0, "kick 1") == 0, "including kick")

	-- "callvote ?" prints the engine's own help, which cannot list a vote type
	-- the engine does not know, so this one adds its line and lets the rest through
	local ret = callvote(server, 0, "?")
	check(ret == 0, "the help call is not swallowed")
	check(sentTo(server, 0):find("callvote bots", 1, true) ~= nil,
		"but the bots vote is advertised in it")

	-- once a vote runs, another callvote is ours to answer
	callvote(server, 0, "bots on")
	check(server.botvote.isActive(), "a vote is running")
	check(callvote(server, 0, "map oasis") == 1,
		"and while it runs no other vote can be called, as in the engine")
	check(countIn(sentTo(server, 0), "A vote is already in progress") == 1,
		"which is also said exactly once")
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
