-- A `luasql.sqlite3` stand-in for the test suite, with the LuaSQL API surface
-- db/sqlite3.lua uses (env:connect(), con:execute(), con:escape(),
-- con:close(), cur:fetch(tbl, "a"), cur:close(), env:close()) on top of a
-- real SQLite database: Python's sqlite3 module, reached through the `python`
-- bridge the lupa runtime exposes (that is how `lua` runs in this sandbox).
--
-- It is deliberately faithful about the two things that bit the live server:
--
--   * con:execute() returns `nil, message` on a SQL error, so db/sqlite3.lua's
--     `assert(con:execute(...))` raises exactly like it does on a server;
--   * row values come back typed the way LuaSQL's sqlite3 driver hands them
--     over (INTEGER -> Lua integer, REAL -> float, TEXT -> string), unless
--     `strings = true` is passed to new(), which makes every value a string,
--     the way LuaSQL's **mysql** driver does, or `floats = true`, which makes
--     every INTEGER a float (3.0), the way LuaSQL < 2.4's sqlite3 driver did
--     on Lua 5.3+. All three must work.
--
-- Only strings cross the Lua/Python bridge: every statement runs on the
-- Python side and its result set comes back as one encoded string that is
-- decoded here. (Handing Python cursors and row tuples to Lua one by one was
-- flaky under garbage collection: "'tuple' object is not callable".)
--
-- Usage from a spec:
--
--   local fake = dofile("tests/luasql_sqlite3_fake.lua")
--   package.preload["luasql.sqlite3"] = function() return fake.new{} end
--
-- or, without lupa, `fake.available()` is false and the spec can skip itself.

local M = {}

function M.available()
	return type(python) == "table" and python.builtins ~= nil and python.eval ~= nil
end

-- the Python side: a connection registry and one function that runs a
-- statement and encodes the outcome.
--   "E" .. message                               a SQL error
--   "N" .. rowcount                              a statement without a result set
--   "R" .. columns RS rows                       a result set; rows separated by
--                                                GS, fields by US, each field
--                                                typed: i<int> f<float> s<text> n
local PY = [==[
import sqlite3

connections = {}
counter = [0]

RS, GS, US = "\x1e", "\x1d", "\x1f"

def connect(path):
    con = sqlite3.connect(path, timeout=5.0)
    con.isolation_level = None
    counter[0] += 1
    connections[counter[0]] = con
    return counter[0]

def close(cid):
    con = connections.pop(cid, None)
    if con is not None:
        con.close()
        return 1
    return 0

def encode_value(v):
    if v is None:
        return "n"
    if isinstance(v, bool):
        return "i" + str(int(v))
    if isinstance(v, int):
        return "i" + str(v)
    if isinstance(v, float):
        return "f" + repr(v)
    if isinstance(v, bytes):
        return "s" + v.decode("utf-8", "replace")
    return "s" + str(v)

def execute(cid, sql):
    con = connections.get(cid)
    if con is None:
        return "Econnection is closed"
    try:
        cur = con.execute(sql)
    except Exception as e:
        return "E" + str(e)
    if cur.description is None:
        n = cur.rowcount
        return "N" + str(n if n is not None and n >= 0 else 0)
    columns = US.join(d[0] for d in cur.description)
    rows = GS.join(US.join(encode_value(v) for v in row) for row in cur.fetchall())
    return "R" + columns + RS + rows

def executescript(cid, script):
    con = connections.get(cid)
    if con is None:
        return "Econnection is closed"
    try:
        con.executescript(script)
    except Exception as e:
        return "E" + str(e)
    return "N0"
]==]

local py

local function python_side()
	if py then return py end
	local ns = python.builtins.dict()
	python.builtins.exec(PY, ns)
	local items = python.as_itemgetter(ns)
	py = {
		connect = items["connect"],
		close = items["close"],
		execute = items["execute"],
		executescript = items["executescript"],
	}
	return py
end

local RS, GS, US = "\30", "\29", "\31"

local function split(s, sep)
	local out = {}
	if s == "" then return out end
	local from = 1
	while true do
		local at = s:find(sep, from, true)
		if not at then
			out[#out + 1] = s:sub(from)
			return out
		end
		out[#out + 1] = s:sub(from, at - 1)
		from = at + 1
	end
end

function M.new(opts)
	opts = opts or {}

	local side = python_side()
	local luasql = {}

	local function decode(field)
		local kind, body = field:sub(1, 1), field:sub(2)
		if kind == "n" then
			return nil
		elseif kind == "i" then
			if opts.strings then return body end
			local n = math.tointeger(tonumber(body)) or tonumber(body)
			if opts.floats then return n + 0.0 end
			return n
		elseif kind == "f" then
			if opts.strings then return body end
			return tonumber(body)
		else
			return body
		end
	end

	local function new_cursor(payload)
		local head, body = payload:match("^(.-)" .. RS .. "(.*)$")
		local columns = split(head, US)
		local rows = split(body, GS)
		local index = 0
		local cur = { closed = false }

		function cur:fetch(tbl, mode)
			if index >= #rows then
				return nil
			end
			index = index + 1
			local fields = split(rows[index], US)
			tbl = tbl or {}
			for k in pairs(tbl) do tbl[k] = nil end
			for i, name in ipairs(columns) do
				local v = decode(fields[i] or "n")
				if mode == "a" then
					tbl[name] = v
				else
					tbl[i] = v
				end
			end
			return tbl
		end

		function cur:close()
			self.closed = true
			return true
		end

		function cur:numrows() return #rows end
		function cur:getcolnames() return columns end

		return cur
	end

	local function new_connection(cid)
		local con = { open = true, statements = {} }
		M.last_connection = con

		local function run(result)
			local kind, rest = result:sub(1, 1), result:sub(2)
			if kind == "E" then
				return nil, rest
			elseif kind == "N" then
				return tonumber(rest) or 0
			end
			return new_cursor(rest)
		end

		function con:execute(sql)
			if not self.open then
				return nil, "connection is closed"
			end
			self.statements[#self.statements + 1] = sql
			return run(side.execute(cid, sql))
		end

		function con:escape(s)
			-- LuaSQL's sqlite3 driver calls sqlite3_mprintf("%q"), and %q is
			-- strict about its argument: a nil here raises in C, and in Lua.
			if type(s) ~= "string" and type(s) ~= "number" then
				error("bad argument #1 to 'escape' (string expected, got " .. type(s) .. ")", 2)
			end
			return (tostring(s):gsub("'", "''"))
		end

		function con:commit() return true end
		function con:rollback() return true end
		function con:setautocommit() return true end

		function con:close()
			if not self.open then return false end
			side.close(cid)
			self.open = false
			return true
		end

		-- test hook: run the schema or any other SQL script
		function con:executescript(script)
			local ok, err = run(side.executescript(cid, script))
			if not ok then error(err, 2) end
			return true
		end

		return con
	end

	function luasql.sqlite3()
		local env = { open = true }

		function env:connect(uri)
			local path = uri
			if type(uri) == "string" and uri:find(":memory:", 1, true) then
				path = ":memory:"
			end
			local ok, cid = pcall(side.connect, path)
			if not ok then
				return nil, tostring(cid)
			end
			return new_connection(cid)
		end

		function env:close()
			if not self.open then return false end
			self.open = false
			return true
		end

		return env
	end

	return luasql
end

return M
