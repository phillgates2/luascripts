-- Regression tests for "!setlevel and !acl still error" on the live server.
--
-- The earlier specs load single modules with database stand-ins; nothing ran
-- the real db/sqlite3.lua, the stock schema and the console/player command
-- paths together. Doing that (tests/wolfadmin_server.lua) showed:
--
--   1. commands/server/acl.lua and commands/admin/acl.lua both defined GLOBAL
--      commandAcl*/commandAcl helpers; admin/ loads after server/, so the
--      console's `acl listlevels` ran the in-game function without a clientId:
--      "commands/admin/acl.lua:46: attempt to concatenate a nil value (local
--      'clientId')" - and every other `acl ...` console action likewise.
--   2. LuaSQL's mysql driver hands every column back as a string (and old
--      sqlite3 drivers as a float): !setlevel compared "3" > 5 -> "attempt to
--      compare string with number"; the acl cache was keyed by "3" while the
--      commands looked up 3 -> "permission denied" / "has no permissions".
--   3. `!setlevel Alice admin` (any non-numeric level) ran `tonumber(level)
--      or 0` and demoted the player to guest.
--   4. A console without its player row (databases not created from the stock
--      schema) got level 0 - unable to !setlevel anyone - and history.add()
--      then concatenated a nil player id into SQL.
--   5. `!resetsprees all` ran TRUNCATE on SQLite, which has no TRUNCATE.
--
-- Run with:   lua tests/acl_setlevel_spec.lua [--verbose]
-- Exit code:  0 when everything passes, 1 otherwise.
-- Needs the lupa runtime (python bridge) for the sqlite driver; without it the
-- spec reports itself skipped and exits 0.

local HERE = (...) and debug.getinfo(1, "S").source:match("@(.*/)") or "./tests/"
if HERE == "" then HERE = "./tests/" end

local server = dofile(HERE .. "wolfadmin_server.lua")

if not server.available() then
	print("acl_setlevel_spec: skipped (needs the lupa runtime for the sqlite driver)")
	os.exit(0)
end

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

local function short(err)
	return (tostring(err):gsub("\nstack traceback.*", ""))
end

local function no_errors(s, what)
	local errs = s.new_errors()
	check(#errs == 0, what .. " raises nothing" .. (#errs > 0 and (": " .. short(errs[1])) or ""))
end

local function has(text, needle)
	return text:find(needle, 1, true) ~= nil
end

local GUID = { A = ("A"):rep(32), B = ("B"):rep(32), C = ("C"):rep(32), X = ("X"):rep(32) }

-- the same scenario on the three value types the LuaSQL drivers produce
local MODES = {
	{ name = "sqlite3 (integers)" },
	{ name = "mysql (every column a string)", strings = true },
	{ name = "old sqlite3 (every number a float)", floats = true },
}

for _, mode in ipairs(MODES) do
	local function new_server(opts)
		opts = opts or {}
		opts.strings = mode.strings
		opts.floats = mode.floats
		local s = server.new(opts)
		s.init()
		assert(#s.errors == 0, "et_InitGame raised: " .. tostring(s.errors[1]))
		return s
	end

	test("[" .. mode.name .. "] the console's `acl` command is the server command, not the in-game one", function()
		local s = new_server()
		s.mark()
		s.console("acl listlevels")
		no_errors(s, "acl listlevels")
		local log = s.log()
		check(has(log, "Server Owner"), "acl listlevels prints the level table to the console")
		check(not has(s.output(), "csay"), "and nothing goes through csay")

		s.console("acl addlevel 6 Root")
		s.console("acl listpermissions 6")
		s.console("acl addpermission 6 kick")
		s.console("acl isallowed 6 kick")
		s.console("acl copypermissions 5 6")
		s.console("acl relevel 6 5")
		s.console("acl removepermissions 6")
		s.console("acl removelevel 6")
		s.console("acl")
		s.console("acl addlevel")
		s.console("acl listpermissions x")
		no_errors(s, "every acl console action")
		check(has(s.log(), "added level 6 (Root)"), "acl addlevel answers on the console")
		check(has(s.log(), "level 6 HAS kick"), "acl isallowed answers on the console")
		check(#s.query("SELECT * FROM level WHERE id=6") == 0, "acl removelevel removed the level")
		s.close()
	end)

	test("[" .. mode.name .. "] !setlevel from the console", function()
		local s = new_server()
		assert(s.join(2, { name = "Alice", guid = GUID.A }))
		assert(s.join(3, { name = "Bob", guid = GUID.B }))

		s.mark()
		s.console("!setlevel 2 5")
		no_errors(s, "!setlevel 2 5")
		check(has(s.output(), "Alice ^9is now a level ^75"), "Alice is announced as level 5")
		local row = s.query("SELECT level_id FROM player WHERE guid='" .. GUID.A .. "'")[1]
		check(row and tonumber(row.level_id) == 5, "and the row says 5")
		check(#s.query("SELECT * FROM history WHERE type='level'") == 1, "one history entry was written")

		s.mark()
		s.console("!setlevel Bob 3")
		no_errors(s, "!setlevel by name")
		check(has(s.output(), "Bob ^9is now a level ^73"), "Bob is level 3 by name")

		s.mark()
		s.console("!setlevel 2 abc")
		no_errors(s, "!setlevel with a non-numeric level")
		check(has(s.output(), "is not a level number"), "a non-numeric level is refused")
		row = s.query("SELECT level_id FROM player WHERE guid='" .. GUID.A .. "'")[1]
		check(tonumber(row.level_id) == 5, "and Alice is still level 5, not demoted to 0")

		for _, bad in ipairs({ "2.5", "-1", "0x3", "" }) do
			s.mark()
			s.console("!setlevel 2 " .. bad)
			no_errors(s, "!setlevel 2 '" .. bad .. "'")
			check(not has(s.output(), "is now a level"), "'" .. bad .. "' changes nothing")
		end

		s.mark()
		s.console("!setlevel 2 9")
		check(has(s.output(), "does not exist"), "a level that is not in the table is refused")
		s.mark()
		s.console("!setlevel 7 1")
		check(has(s.output(), "no connected player"), "an empty slot is refused")
		s.mark()
		s.console("!setlevel zzz 1")
		check(has(s.output(), "no or multiple matches"), "an unknown name is refused")
		s.mark()
		s.console("!setlevel")
		check(has(s.output(), "setlevel usage"), "no arguments prints the usage")
		no_errors(s, "the refusals")
		s.close()
	end)

	test("[" .. mode.name .. "] !setlevel and !acl by players, level checks compare as numbers", function()
		local s = new_server()
		assert(s.join(2, { name = "Alice", guid = GUID.A }))
		assert(s.join(3, { name = "Bob", guid = GUID.B }))
		assert(s.join(4, { name = "Carol", guid = GUID.C }))
		s.console("!setlevel 2 5")
		s.console("!setlevel 3 3")
		s.new_errors()

		s.mark()
		s.client(2, "say", "!setlevel Carol 4")
		no_errors(s, "a level 5 player's !setlevel in chat")
		check(has(s.output(), "Carol ^9is now a level ^74"), "Alice (5) can set Carol to 4")

		s.mark()
		s.client(2, "!setlevel 4 3")
		no_errors(s, "a level 5 player's silent !setlevel")
		check(has(s.output(), "Carol ^9is now a level ^73"), "silent (console) !setlevel works too")

		s.mark()
		s.client(2, "say", "!setlevel 3 6")
		check(has(s.output(), "does not exist"), "a level that does not exist is refused")

		s.mark()
		s.client(2, "say", "!admintest")
		check(has(s.output(), "level 5 user"), "!admintest shows Alice as level 5")
		s.mark()
		s.client(3, "say", "!admintest")
		check(has(s.output(), "level 3 user (^7Admin"), "!admintest shows Bob as level 3 with the level name")

		-- Bob is level 3, which has no 'setlevel' in the stock schema
		s.mark()
		s.client(3, "say", "!setlevel 2 0")
		check(has(s.output(), "permission denied"), "Bob (3) is denied !setlevel")
		local row = s.query("SELECT level_id FROM player WHERE guid='" .. GUID.A .. "'")[1]
		check(tonumber(row.level_id) == 5, "and Alice stays level 5")

		-- grant it, then the level comparisons apply
		s.console("!acl addpermission 3 setlevel")
		s.mark()
		s.client(3, "say", "!setlevel 2 0")
		check(has(s.output(), "higher admin level than you"), "Bob (3) cannot touch Alice (5)")
		s.mark()
		s.client(3, "say", "!setlevel 4 4")
		check(has(s.output(), "may not setlevel higher"), "Bob (3) cannot grant level 4")
		s.mark()
		s.client(3, "say", "!setlevel 4 1")
		check(has(s.output(), "Carol ^9is now a level ^71"), "Bob (3) can set Carol to 1")
		no_errors(s, "the player-side level checks")

		-- !acl in game
		s.mark()
		s.client(2, "say", "!acl listlevels")
		check(has(s.output(), "Server Owner"), "!acl listlevels lists the levels")
		s.mark()
		s.client(2, "say", "!acl listpermissions 1")
		check(has(s.output(), "listmaps"), "!acl listpermissions finds level 1's permissions")
		s.mark()
		s.client(2, "say", "!acl isallowed 1 kick")
		check(has(s.output(), "HAS NOT"), "!acl isallowed answers HAS NOT")
		s.mark()
		s.client(2, "say", "!acl addpermission 1 kick")
		check(has(s.output(), "added ^7kick"), "!acl addpermission adds")
		check(#s.query("SELECT * FROM level_permission WHERE level_id=1 AND permission='kick'") == 1, "and the row exists")
		s.mark()
		s.client(2, "say", "!acl isallowed 1 kick")
		check(has(s.output(), "HAS ^7kick"), "!acl isallowed now answers HAS")
		s.mark()
		s.client(2, "say", "!acl addpermission 1 kick")
		check(has(s.output(), "already has"), "adding twice is refused, not duplicated")
		s.mark()
		s.client(2, "say", "!acl addpermission 1 kcik")
		check(has(s.output(), "warning"), "a mistyped permission is warned about")
		s.mark()
		s.client(2, "say", "!acl removepermission 1 kick")
		check(has(s.output(), "removed ^7kick"), "!acl removepermission removes")
		check(#s.query("SELECT * FROM level_permission WHERE level_id=1 AND permission='kick'") == 0, "and the row is gone")
		s.mark()
		s.client(2, "say", "!acl copypermissions 2 1")
		check(has(s.output(), "copied"), "!acl copypermissions copies")
		s.mark()
		s.client(2, "say", "!acl missing")
		check(has(s.output(), "every permission") or has(s.output(), "granted to no level"), "!acl missing answers")
		s.mark()
		s.client(2, "say", "!acl addpermission 9 kick")
		check(has(s.output(), "no level ^79"), "an unknown level is refused")
		s.mark()
		s.client(2, "say", "!acl addpermission x kick")
		check(has(s.output(), "not a level number"), "a non-numeric level is refused")
		s.mark()
		s.client(2, "say", "!acl bogus 1 2")
		check(has(s.output(), "unknown action"), "an unknown action is refused")
		s.mark()
		s.client(3, "say", "!acl listlevels")
		no_errors(s, "every !acl action")
		s.close()
	end)

	test("[" .. mode.name .. "] a permission granted in game takes effect at once and survives a map change", function()
		local s = new_server()
		assert(s.join(2, { name = "Alice", guid = GUID.A }))
		assert(s.join(3, { name = "Bob", guid = GUID.B }))
		s.console("!setlevel 2 5")
		s.console("!setlevel 3 1")

		s.mark()
		s.client(3, "say", "!lol 2")
		check(has(s.output(), "permission denied"), "Bob (1) is denied !lol")

		s.client(2, "say", "!acl addpermission 1 lol")
		s.mark()
		s.client(3, "say", "!lol 2")
		check(not has(s.output(), "permission denied"), "after !acl addpermission Bob's !lol is allowed")

		s.shutdown(true)
		s.init(true)
		no_errors(s, "map_restart (shutdown + init on the same VM)")
		s.mark()
		s.client(3, "say", "!lol 2")
		check(not has(s.output(), "permission denied"), "and still allowed after the map change")
		s.mark()
		s.client(2, "say", "!admintest")
		check(has(s.output(), "level 5 user"), "Alice is still level 5 after the map change")
		s.close()
	end)

	test("[" .. mode.name .. "] a database without the console's player row", function()
		local s = new_server({ sql = { "DELETE FROM player WHERE guid='" .. GUID.X .. "'" } })
		assert(s.join(2, { name = "Alice", guid = GUID.A }))

		s.mark()
		s.console("!setlevel 2 5")
		no_errors(s, "console !setlevel with no console row")
		check(has(s.output(), "Alice ^9is now a level ^75"), "the console can still make the first Server Owner")
		check(#s.query("SELECT * FROM history") == 1, "the history entry was written")

		s.console("acl addlevel 6 Root")
		s.mark()
		s.console("!setlevel 2 6")
		no_errors(s, "console !setlevel to a level above the stock ones")
		check(has(s.output(), "is now a level ^76"), "the console outranks every level, including a new one")
		s.close()
	end)

	test("[" .. mode.name .. "] a client without a GUID", function()
		local s = new_server()
		local _, denied = s.join(5, { name = "NoGuid", guid = "" })
		check(denied ~= nil, "a client without a GUID is refused at connect")
		s.mark()
		s.console("!setlevel 5 1")
		s.console("!finger 5")
		no_errors(s, "!setlevel / !finger on that slot")
		check(not has(s.output(), "is now a level"), "nothing is stored for it")
		s.close()
	end)

	test("[" .. mode.name .. "] !resetsprees all on SQLite", function()
		local s = new_server()
		assert(s.join(2, { name = "Alice", guid = GUID.A }))
		s.console("!setlevel 2 5")
		s.new_errors()
		s.client(2, "say", "!resetsprees all")
		no_errors(s, "!resetsprees all")
		s.close()
	end)
end

-- --------------------------- the full sweep -------------------------------

test("every admin command, from the console and from players, raises nothing", function()
	local s = server.new({})
	s.init()
	assert(s.join(2, { name = "Alice", guid = GUID.A }))
	assert(s.join(3, { name = "Bob", guid = GUID.B }))
	assert(s.join(4, { name = "Carol", guid = GUID.C }))
	s.console("!setlevel 2 5")
	s.console("!setlevel 3 3")
	s.new_errors()

	local commands = require("luascripts/wolfadmin/commands/commands")
	local names = {}
	for name in pairs(commands.getadmin()) do names[#names + 1] = name end
	table.sort(names)

	local errors, swept = {}, 0
	local function record(who, line)
		for _, e in ipairs(s.new_errors()) do
			local key = short(e)
			errors[key] = errors[key] or (who .. ": " .. line .. (VERBOSE and ("\n" .. e) or ""))
		end
	end

	for _, name in ipairs(names) do
		for _, args in ipairs({ "", "3", "3 1", "3 1 reason", "Bob", "3 600 reason", "all", "4 1" }) do
			local line = "!" .. name .. (args ~= "" and " " .. args or "")
			s.console(line); s.frame(50); record("console", line)
			s.client(2, "say", line); s.frame(50); record("Alice (5) chat", line)
			s.client(2, line); s.frame(50); record("Alice (5) silent", line)
			s.client(3, "say", line); s.frame(50); record("Bob (3) chat", line)
			s.client(4, "say_team", line); s.frame(50); record("Carol (0) team chat", line)
			swept = swept + 5
		end
	end

	local count = 0
	for key, where in pairs(errors) do
		count = count + 1
		print("  ERROR " .. key .. "\n        first at " .. where)
	end
	check(count == 0, #names .. " admin commands, " .. swept .. " invocations: " .. count .. " distinct errors")
	s.close()
end)

-- --------------------------------- result ---------------------------------

print("")
if #failures > 0 then
	print(#failures .. " of " .. checks .. " checks FAILED:")
	for _, f in ipairs(failures) do print("  - " .. f) end
	os.exit(1)
end
print(checks .. " checks passed")
