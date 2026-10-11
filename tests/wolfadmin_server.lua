-- A WolfAdmin server for the specs: the REAL main.lua and the real module
-- tree (every file under admin/, auth/, commands/, db/, game/, players/,
-- util/), the real db/sqlite3.lua on top of a real SQLite database with the
-- stock WolfAdmin schema, driven through tests/et_stub.lua as the engine.
--
-- tests/command_target_spec.lua and friends load single modules with
-- stand-ins for the database; this is the other end of the scale, for the
-- bugs those stand-ins cannot see: SQL that concatenates a nil, a row value
-- that is a string where the code compares numbers, a console command with
-- no player row behind it.
--
-- Needs the lupa runtime (the `python` bridge) for the sqlite driver, see
-- tests/luasql_sqlite3_fake.lua; `server.available()` says whether it is.
--
--   local server = dofile("tests/wolfadmin_server.lua")
--   local s = server.new{ schema = "tests/schema/sqlite.sql" }
--   s.join(2, { name = "Alice", guid = ("A"):rep(32) })
--   s.console("!setlevel 2 3")            -- rcon / server console
--   s.client(2, "say", "!acl listlevels")  -- a player, in chat
--   s.client(2, "!acl listlevels")         -- a player, silent (console)
--   print(s.output())                      -- everything the players were sent

local HERE = debug.getinfo(1, "S").source:match("@(.*/)") or "./tests/"
local ROOT = HERE .. "../"

local stub = dofile(HERE .. "et_stub.lua")
local fakesql = dofile(HERE .. "luasql_sqlite3_fake.lua")

local server = {}

function server.available()
	return fakesql.available()
end

local function read_file(path)
	local f = assert(io.open(path, "rb"))
	local s = f:read("a")
	f:close()
	return s
end

-- a tiny TOML reader, enough for the [section] key = value files WolfAdmin
-- ships (wolfadmin.toml and the data files); arrays of tables ([[rule]]) too
local function parse_toml(text)
	local root, current = {}, nil
	for line in (text .. "\n"):gmatch("([^\n]*)\n") do
		line = line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
		if line == "" then
		elseif line:match("^%[%[(.-)%]%]$") then
			local name = line:match("^%[%[(.-)%]%]$")
			root[name] = root[name] or {}
			current = {}
			table.insert(root[name], current)
		elseif line:match("^%[(.-)%]$") then
			local name = line:match("^%[(.-)%]$")
			root[name] = root[name] or {}
			current = root[name]
		else
			local key, value = line:match("^([%w_%-]+)%s*=%s*(.-)$")
			if key then
				local v
				if value:match('^".*"$') then
					v = value:sub(2, -2)
				elseif value == "true" then
					v = true
				elseif value == "false" then
					v = false
				elseif value:match("^%[.*%]$") then
					v = {}
					for item in value:sub(2, -2):gmatch("[^,]+") do
						item = item:gsub("^%s+", ""):gsub("%s+$", "")
						if item:match('^".*"$') then item = item:sub(2, -2) else item = tonumber(item) or item end
						table.insert(v, item)
					end
				else
					v = tonumber(value) or value
				end
				(current or root)[key] = v
			end
		end
	end
	return root
end

-- the lupa runtime builds Lua without io.popen; settings.determineOS() and
-- files.ls() need it (uname / ls), so provide one through Python
local function ensure_popen()
	local ok = pcall(io.popen, "true")
	if ok then return end
	local run = python.eval("lambda c: __import__('subprocess').run(c, shell=True, capture_output=True, text=True).stdout")
	io.popen = function(command)
		local text = ""
		pcall(function() text = run(command) or "" end)
		local pos = 1
		local handle = {}
		function handle:read(fmt)
			if fmt == "*a" or fmt == "a" then
				local rest = text:sub(pos)
				pos = #text + 1
				return rest
			end
			if pos > #text then return nil end
			local nl = text:find("\n", pos, true) or (#text + 1)
			local line = text:sub(pos, nl - 1)
			pos = nl + 1
			return line
		end
		function handle:lines()
			return function() return handle:read("*l") end
		end
		function handle:close() return true end
		return handle
	end
end

function server.new(opts)
	opts = opts or {}
	assert(server.available(), "tests/wolfadmin_server.lua needs the lupa runtime (python bridge) for sqlite")
	ensure_popen()

	local engine = stub.new({ sv_maxclients = opts.maxclients or 20 })
	engine.install()

	-- the directory layout the engine sees: <basepath>/<fs_game>/luascripts/
	-- wolfadmin is this repository (files.ls() runs `ls` on it)
	local tmp = os.tmpname()
	os.remove(tmp)
	local base = tmp .. "_wa"
	assert(os.execute('mkdir -p "' .. base .. '/legacy/luascripts"'))
	assert(os.execute('ln -sfn "$(cd "' .. ROOT .. '" && pwd)" "' .. base .. '/legacy/luascripts/wolfadmin"'))

	engine.cvars.fs_basepath = base
	engine.cvars.fs_homepath = base
	engine.cvars.fs_game = opts.fs_game or "legacy"
	engine.cvars.sv_maxclients = tostring(opts.maxclients or 20)
	engine.cvars.g_gametype = "2"
	engine.cvars.sv_privateClients = "0"
	engine.cvars.mapname = "oasis"
	engine.cvars.version = "ET Legacy v2.82"
	for k, v in pairs(opts.cvars or {}) do engine.cvars[k] = tostring(v) end

	-- ---------------------------------------------------------------- files
	local files = {
		["wolfadmin.toml"] = opts.toml or table.concat({
			"[main]",
			"standalone = " .. tostring(opts.standalone == nil and 1 or opts.standalone),
			'os = "unix"', -- skips determineOS(), whose `uname -s 2>nul` leaves a file called nul in the cwd
			"[db]",
			'type = "sqlite3"',
			'file = "wolfadmin.db"',
		}, "\n"),
	}
	for name, content in pairs(opts.files or {}) do files[name] = content end
	server.files = files

	local handles = {}
	et.FS_READ, et.FS_WRITE, et.FS_APPEND = 0, 1, 2
	et.trap_FS_FOpenFile = function(name, mode)
		if mode == et.FS_READ then
			local content = files[name]
			if not content then return -1, -1 end
			handles[#handles + 1] = { name = name, content = content }
			return #handles, #content
		end
		handles[#handles + 1] = { name = name, content = "", write = true }
		return #handles, 0
	end
	et.trap_FS_Read = function(fd, len)
		local h = handles[fd]
		return h and h.content:sub(1, len) or ""
	end
	et.trap_FS_Write = function(data, len, fd)
		local h = handles[fd]
		if h then h.content = h.content .. tostring(data):sub(1, len) end
	end
	et.trap_FS_FCloseFile = function(fd)
		local h = handles[fd]
		if h and h.write then files[h.name] = h.content end
	end

	-- ---------------------------------------------------------- client info
	engine.userinfo = engine.userinfo or {}
	local userinfo = {}
	et.trap_GetUserinfo = function(num) return userinfo[num] or "" end
	et.trap_SetUserinfo = function(num, info) userinfo[num] = info end
	et.Info_ValueForKey = function(info, key)
		if type(info) ~= "string" then return "" end
		for k, v in (info .. "\\"):gmatch("\\([^\\]*)\\([^\\]*)") do
			if k == key then return v end
		end
		return ""
	end
	et.Info_SetValueForKey = function(info, key, value)
		local out, seen = {}, false
		for k, v in (tostring(info) .. "\\"):gmatch("\\([^\\]*)\\([^\\]*)") do
			if k == key then
				seen = true
				if value ~= "" then out[#out + 1] = "\\" .. k .. "\\" .. value end
			else
				out[#out + 1] = "\\" .. k .. "\\" .. v
			end
		end
		if not seen and value ~= "" then out[#out + 1] = "\\" .. key .. "\\" .. value end
		return table.concat(out)
	end
	et.Q_CleanStr = function(s) return (tostring(s):gsub("%^.", "")) end
	et.trap_GetConfigstring = function() return "" end
	et.trap_SetConfigstring = function() end
	et.trap_DropClient = function(num, reason)
		engine.drops = engine.drops or {}
		engine.drops[#engine.drops + 1] = { num = num, reason = reason }
	end
	et.G_Say = function() end
	et.MutePlayer = function() end
	et.UnmutePlayer = function() end
	et.isBitSet = function(bit, value) return (value & bit) ~= 0 end
	et.G_ShaderRemap = function() end
	et.G_ResetRemappedShaders = function() end
	et.G_SetGlobalFog = function() end
	et.G_GlobalClientEvent = function() end
	et.G_AddEvent = function() end
	et.G_XP_Set = function() end
	et.G_ResetXP = function() end
	et.G_ClientSound = function() end
	et.G_Sound = function() end

	-- the engine's ClientNumberFromString() (g_cmds.c): a slot number, or a
	-- unique partial, case-insensitive, colour-stripped name match
	et.ClientNumberFromString = function(s)
		s = tostring(s or "")
		local num = tonumber(s)
		if num and num == math.floor(num) and num >= 0 and num < tonumber(engine.cvars.sv_maxclients) then
			local e = engine.ents[num]
			if e and e.client and e.client.pers.connected == 2 then return num end
			return -1
		end
		local needle = et.Q_CleanStr(s):lower()
		local found = -1
		for i = 0, tonumber(engine.cvars.sv_maxclients) - 1 do
			local e = engine.ents[i]
			if e and e.client and e.client.pers.connected == 2 then
				local name = et.Q_CleanStr(e.client.pers.netname):lower()
				if name == needle then return i end
				if name:find(needle, 1, true) then
					if found ~= -1 then return -1 end
					found = i
				end
			end
		end
		return found
	end

	-- --------------------------------------------------------------- modules
	local toml = { parse = parse_toml }
	package.preload["lualibs/toml"] = function() return toml end
	package.preload["luasql.sqlite3"] = function() return fakesql.new({ strings = opts.strings, floats = opts.floats }) end
	package.loaded["luasql.sqlite3"] = nil
	package.loaded["lualibs/toml"] = nil

	-- main.lua requires "luascripts/wolfadmin/<module>": point that path at
	-- the repository, and forget whatever an earlier server instance loaded
	for name in pairs(package.loaded) do
		if name:find("^luascripts/wolfadmin/") then package.loaded[name] = nil end
	end
	package.path = ROOT .. "?.lua;" .. package.path
	local searcher = function(name)
		local short = name:match("^luascripts/wolfadmin/(.*)$")
		if not short then return nil end
		local path = ROOT .. short .. ".lua"
		local chunk, err = loadfile(path)
		if not chunk then return "\n\t" .. tostring(err) end
		return chunk, path
	end
	table.insert(package.searchers, 2, searcher)

	-- a fresh set of engine callbacks for this instance
	for _, name in ipairs({ "et_InitGame", "et_ShutdownGame", "et_ConsoleCommand", "et_ClientConnect",
	                        "et_ClientBegin", "et_ClientDisconnect", "et_ClientUserinfoChanged",
	                        "et_ClientCommand", "et_RunFrame", "et_Print", "et_Obituary",
	                        "et_ClientSpawn", "et_Damage", "et_WeaponFire", "et_SpawnEntitiesFromString" }) do
		_G[name] = nil
	end
	_G.outputDebug = nil

	assert(load(read_file(ROOT .. "main.lua"), "luascripts/wolfadmin/main.lua"))()

	-- -------------------------------------------------------------- database
	-- the schema goes in before et_InitGame(): db.start() refuses a database
	-- without the `config` table ("Database schema does not exist")
	local luasql = require("luasql.sqlite3")
	local env = luasql.sqlite3()
	local schema = opts.schema or (HERE .. "schema/sqlite.sql")
	-- the module opens <homepath>/<fs_game>/wolfadmin.db; prepare that file
	local dbfile = base .. "/" .. engine.cvars.fs_game .. "/wolfadmin.db"
	local con = assert(env:connect(dbfile))
	if schema ~= false then
		assert(con:executescript(read_file(schema)))
	end
	for _, sql in ipairs(opts.sql or {}) do
		assert(con:execute(sql))
	end
	con:close()
	env:close()

	-- ------------------------------------------------------------------ api
	local s = { engine = engine, et = et, base = base, dbfile = dbfile }

	-- open a second connection to look at the data from the outside
	function s.query(sql)
		local env2 = luasql.sqlite3()
		local c = assert(env2:connect(dbfile))
		local cur = assert(c:execute(sql))
		local rows = {}
		if type(cur) == "table" then
			local row = cur:fetch({}, "a")
			while row do
				rows[#rows + 1] = row
				row = cur:fetch({}, "a")
			end
			cur:close()
		end
		c:close()
		env2:close()
		return rows
	end

	function s.exec(sql)
		local env2 = luasql.sqlite3()
		local c = assert(env2:connect(dbfile))
		assert(c:execute(sql))
		c:close()
		env2:close()
	end

	-- every error a callback raised, in order: the engine prints these as
	-- "Lua API: <hook> error running lua script: '<message>'" and carries on
	s.errors = {}

	local function hook(name, ...)
		local fn = rawget(_G, name)
		if type(fn) ~= "function" then return nil end
		local ok, result = xpcall(fn, debug.traceback, ...)
		if not ok then
			s.errors[#s.errors + 1] = name .. ": " .. tostring(result)
			return nil
		end
		return result
	end
	s.hook = hook

	function s.init(restart)
		engine.time = 0
		return hook("et_InitGame", 0, 12345, restart and 1 or 0)
	end

	function s.shutdown(restart)
		return hook("et_ShutdownGame", restart and 1 or 0)
	end

	function s.frame(ms)
		engine.advance(ms or 50)
		return hook("et_RunFrame", engine.time)
	end

	-- a human client connecting and entering the game, as the engine would
	-- call the hooks (ClientConnect -> ClientUserinfoChanged -> ClientBegin)
	function s.join(num, info)
		info = info or {}
		local team = info.team or 1
		local e = engine.connect(num, team, info.class or 0)
		e.client.pers.netname = info.name or ("Player" .. num)
		e.client.sess.sessionTeam = team
		local guid = info.guid or string.format("%032X", num)
		local ip = info.ip or ("10.0.0." .. num .. ":27960")
		userinfo[num] = "\\name\\" .. (info.name or ("Player" .. num)) .. "\\cl_guid\\" .. guid .. "\\ip\\" .. ip .. "\\protocol\\84\\rate\\25000"
		local denied = hook("et_ClientConnect", num, info.firstTime == false and 0 or 1, info.bot and 1 or 0)
		if denied and denied ~= "" and denied ~= 0 then
			return nil, denied
		end
		hook("et_ClientUserinfoChanged", num)
		hook("et_ClientBegin", num)
		return e
	end

	-- ClientDisconnect(): the hook runs first, then the engine clears the
	-- slot - but ent->client stays allocated for every slot below maxclients
	-- (G_InitGame), with pers.connected = CON_DISCONNECTED and an empty name,
	-- so gentity_get(slot, "pers.netname") answers "" instead of raising
	function s.leave(num)
		hook("et_ClientDisconnect", num)
		local e = engine.ents[num]
		if e and e.client then
			e.client.pers.connected = 0
			e.client.pers.netname = ""
			e.inuse = 0
		end
		userinfo[num] = nil
		if engine.class_of then engine.class_of[num] = nil end
	end

	-- rcon / server console: `cmd arg1 arg2` -> et_ConsoleCommand()
	function s.console(text)
		engine.parse_command(text)
		local first = engine.argv[1] or ""
		return hook("et_ConsoleCommand", first)
	end

	-- a client command: s.client(2, "say", "!setlevel 3 2") or s.client(2, "!setlevel 3 2")
	function s.client(num, command, text)
		if text then
			engine.argv = { command, text }
		else
			engine.parse_command(command)
		end
		return hook("et_ClientCommand", num, engine.argv[1] or "")
	end

	-- what the server told the players and the console since the last mark
	local mark = 0
	function s.mark()
		mark = #engine.consoles
		s.log_mark = #engine.log
	end
	function s.output()
		local out = {}
		for i = mark + 1, #engine.consoles do out[#out + 1] = engine.consoles[i].cmd end
		return table.concat(out, "\n")
	end
	function s.log()
		local out = {}
		for i = (s.log_mark or 0) + 1, #engine.log do out[#out + 1] = engine.log[i] end
		return table.concat(out, "\n")
	end
	function s.new_errors()
		local out = {}
		for i = (s.error_mark or 0) + 1, #s.errors do out[#out + 1] = s.errors[i] end
		s.error_mark = #s.errors
		return out
	end

	function s.close()
		pcall(s.shutdown)
		os.execute('rm -rf "' .. base .. '"')
	end

	return s
end

return server
