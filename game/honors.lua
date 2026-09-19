
-- WolfAdmin module for Wolfenstein: Enemy Territory servers.
-- Roll of Honor: extra end-of-map awards, announced in chat/console.
--
-- ET:Legacy's own debriefing "Roll of Honor" (the awards page of the
-- intermission screen) has a fixed list of categories compiled into the
-- client - src/cgame/cg_debriefing.c, awardNames[] with NUM_ENDGAME_AWARDS
-- entries - and nothing in the server or the Lua API can add a title to it.
-- What the server may do is fill in the winners (CS_ENDGAME_STATS from
-- G_BuildEndgameStats() in src/game/g_stats.c), which is why a fully
-- server-side honours list lives here instead: this module computes its own
-- categories from the stats the engine keeps per client and announces them
-- when the map ends.
--
-- Data comes from the engine, not from guesswork:
--   * sess.kills / deaths / gibs / team_kills / self_kills / damage_given
--     and sess.time_played are the same session counters the scoreboard and
--     the stock awards use (read-only fields in g_lua.c).
--   * sess.aWeaponStats[WS_*] is the per-weapon stat block (atts, deaths,
--     headshots, hits, kills) the accuracy awards are built from; the WS_*
--     indexes mirror extWeaponStats_t in bg_public.h.
--   * XP earned on this map is the same sum the engine's own "Highest
--     Experience Points" award uses: sum(sess.skillpoints - sess.startskillpoints).
--   * Revives cannot be read back (PERS_REVIVE_COUNT counts the *revived*
--     player, not the medic), so they are counted from the Medic_Revive line
--     main.lua turns into onPlayerRevive.
--
-- The counters are snapshotted every SNAPSHOT_MS and at the end of the map,
-- so a player who leaves before the end still shows up in the results; each
-- snapshot only ever raises a value, a lagging read can not undo a higher one.
--
-- Categories (gameplay / team / fun):
--   Deadliest (kills), Efficient killer (K/D), Headhunter (headshots),
--   Silent blade (knife kills), Demolitions expert (explosive kills),
--   Heavy hitter (damage), Spray and pray (shots fired),
--   Killing machine (longest spree), Angel of Mercy (revives),
--   Most XP earned, Iron man (time played), Butcher (gibs),
--   Cannon fodder (deaths), Friendly fire (team kills),
--   Suicide king (self kills), Sharp eye (accuracy).
-- Each award is only announced when somebody actually qualifies, so a quiet
-- map stays quiet. Add/remove entries in CATEGORIES to taste.
--
-- Install: loaded automatically when WolfAdmin loads via main.lua (no extra
-- lua_modules entries required). Server cvars:
--   g_honors          0 disables the module (default 1)
--   g_honors_bots     1 lets bots into the results (default 0)
--   g_honors_messages 1 chat (default), 2 popups, 3 both, 0 server log only
-- =========================================================================

local events = wolfa_requireModule("util.events")
local constants = wolfa_requireModule("util.constants")
local players = wolfa_requireModule("players.players")

local honors = {}

-- ============================== CONFIG ===================================

local ENABLE           = true
local CVAR             = "g_honors"     -- server cvar: 0 disables, anything else enables
local SHOW_BOTS        = false          -- bots in the results? (g_honors_bots overrides)
local MIN_PLAY_MS      = 60000          -- a player with less time on the map can not win
local SNAPSHOT_MS      = 15000          -- how often the engine counters are copied
local MESSAGES         = 1              -- 1 chat, 2 popups, 3 both, 0 server log only
                                        -- (g_honors_messages overrides)
local ROW_LIMIT        = 16             -- at most this many awards per map (0 = all)
local TITLE            = "Roll of Honor"
local LOG_TO_CONSOLE   = true           -- also write the block to the server log

-- announcement colours
local COLOR_TEXT       = "^d"
local COLOR_NAME       = "^7"
local COLOR_VALUE      = "^9"
local COLOR_GAMEPLAY   = "^2"
local COLOR_TEAM       = "^4"
local COLOR_FUN        = "^3"

-- ============================ weapon stats ===============================

-- extWeaponStats_t (bg_public.h): the index sess.aWeaponStats is keyed by.
-- Not the same numbering as WP_*, and not exported to Lua.
local WS = {
	KNIFE = 0, KNIFE_KBAR = 1,
	PANZERFAUST = 8, BAZOOKA = 9, FLAMETHROWER = 10,
	GRENADE = 11, MORTAR = 12, MORTAR2 = 13, DYNAMITE = 14,
	AIRSTRIKE = 15, ARTILLERY = 16, SATCHEL = 17, GRENADELAUNCHER = 18,
	LANDMINE = 19, MAX = 28,
}

-- _etH_gentity_getweaponstat() returns the stat block as {atts, deaths,
-- headshots, hits, kills}, i.e. 1..5 in Lua.
local WS_ATTS, WS_HEADSHOTS, WS_HITS, WS_KILLS = 1, 3, 4, 5

local function ws_set(list)
	local set = {}
	for _, w in ipairs(list) do set[w] = true end
	return set
end

local KNIFE_WS = ws_set({ WS.KNIFE, WS.KNIFE_KBAR })
local EXPLOSIVE_WS = ws_set({
	WS.PANZERFAUST, WS.BAZOOKA, WS.GRENADE, WS.GRENADELAUNCHER,
	WS.LANDMINE, WS.SATCHEL, WS.DYNAMITE, WS.AIRSTRIKE, WS.ARTILLERY,
	WS.MORTAR, WS.MORTAR2,
})

-- ============================== helpers ==================================

local function log(msg)
	if type(et) == "table" and type(et.G_Print) == "function" then
		et.G_Print("[wolfadmin:honors] " .. msg .. "\n")
	end
end

local function is_enabled()
	if not ENABLE then return false end
	if type(et) == "table" and type(et.trap_Cvar_Get) == "function" then
		local v = et.trap_Cvar_Get(CVAR)
		if v ~= nil and v ~= "" then
			local n = tonumber(v)
			if n ~= nil then return n ~= 0 end
		end
	end
	return true
end

-- protected read of a client field, nil when the slot has no client data
local function get(num, field, index)
	if type(et) ~= "table" or type(et.gentity_get) ~= "function" then return nil end
	local ok, val = pcall(et.gentity_get, num, field, index)
	if not ok then return nil end
	return val
end

local function number(num, field, index)
	local v = get(num, field, index)
	if type(v) == "number" then return v end
	return tonumber(v) or 0
end

local function cvar_number(name, default)
	if type(et) == "table" and type(et.trap_Cvar_Get) == "function" then
		local v = et.trap_Cvar_Get(name)
		if v ~= nil and v ~= "" then
			local n = tonumber(v)
			if n ~= nil then return n end
		end
	end
	return default
end

local function show_bots()
	return cvar_number("g_honors_bots", SHOW_BOTS and 1 or 0) ~= 0
end

local function messages()
	return cvar_number("g_honors_messages", MESSAGES)
end

local function is_connected(num)
	return number(num, "pers.connected") == constants.CON_CONNECTED
end

local function is_bot(num)
	if type(players.isBot) ~= "function" then return false end
	local ok, v = pcall(players.isBot, num)
	return ok and v and true or false
end

local function name_of(num)
	if type(players.getName) == "function" then
		local ok, v = pcall(players.getName, num)
		if ok and type(v) == "string" and v ~= "" then return v end
	end
	local v = get(num, "pers.netname")
	return (type(v) == "string" and v ~= "") and v or ("player " .. num)
end

-- a stable key per player, so somebody who leaves keeps his numbers
local function key_of(num)
	if type(players.getGUID) == "function" then
		local ok, guid = pcall(players.getGUID, num)
		if ok and type(guid) == "string" and guid ~= "" and guid ~= "no" then
			return guid
		end
	end
	return "slot:" .. num
end

local function int(v)
	if v >= 0 then return tostring(math.floor(v + 0.5)) end
	return "-" .. tostring(math.floor(-v + 0.5))
end

-- ============================ the records ================================

local data = {}         -- [key] = record
local by_slot = {}      -- [clientId] = key
local last_snapshot = 0

local function new_record(key)
	return {
		key = key, name = "?", bot = false,
		kills = 0, deaths = 0, gibs = 0, team_kills = 0, self_kills = 0,
		damage_given = 0, time_played = 0, xp = 0,
		headshots = 0, knife_kills = 0, explosive_kills = 0, shots = 0, hits = 0,
		revives = 0, spree = 0, best_spree = 0,
	}
end

local function record(num, create)
	local key = by_slot[num]
	if not key and create then
		key = key_of(num)
		by_slot[num] = key
	end
	if not key then return nil end
	local rec = data[key]
	if not rec and create then
		rec = new_record(key)
		data[key] = rec
	end
	if rec and create then
		-- keep the display name current (players rename mid-map)
		rec.name = name_of(num)
		rec.bot = is_bot(num)
	end
	return rec
end

local function raise(rec, field, value)
	if value == nil then return end
	if type(value) ~= "number" then value = tonumber(value) or 0 end
	if value > (rec[field] or 0) then rec[field] = value end
end

local function add(rec, field, amount)
	rec[field] = (rec[field] or 0) + amount
end

-- copies the engine counters of one player into his record; values only go up
local function snapshot(num)
	local rec = record(num, true)
	if not rec then return nil end

	raise(rec, "kills", number(num, "sess.kills"))
	raise(rec, "deaths", number(num, "sess.deaths"))
	raise(rec, "gibs", number(num, "sess.gibs"))
	raise(rec, "team_kills", number(num, "sess.team_kills"))
	raise(rec, "self_kills", number(num, "sess.self_kills"))
	raise(rec, "damage_given", number(num, "sess.damage_given"))
	raise(rec, "time_played", number(num, "sess.time_played"))

	-- XP earned on this map, the way G_BuildEndgameStats() computes it
	local xp = 0
	for skill = 0, 6 do
		xp = xp + number(num, "sess.skillpoints", skill)
			- number(num, "sess.startskillpoints", skill)
	end
	if xp > rec.xp then rec.xp = xp end

	-- per-weapon block: headshots, knife kills, explosive kills, accuracy
	local headshots, knife, explosive, shots, hits = 0, 0, 0, 0, 0
	local ok_all = true
	for w = 0, WS.MAX - 1 do
		local ws = get(num, "sess.aWeaponStats", w)
		if type(ws) == "table" then
			local atts = tonumber(ws[WS_ATTS]) or 0
			shots = shots + atts
			hits = hits + (tonumber(ws[WS_HITS]) or 0)
			headshots = headshots + (tonumber(ws[WS_HEADSHOTS]) or 0)
			local kills = tonumber(ws[WS_KILLS]) or 0
			if KNIFE_WS[w] then knife = knife + kills end
			if EXPLOSIVE_WS[w] then explosive = explosive + kills end
		else
			ok_all = false
		end
	end
	if ok_all then
		raise(rec, "headshots", headshots)
		raise(rec, "knife_kills", knife)
		raise(rec, "explosive_kills", explosive)
		raise(rec, "shots", shots)
		raise(rec, "hits", hits)
	end

	return rec
end

local function snapshot_all(final)
	for num = 0, 63 do
		if is_connected(num) then
			if show_bots() or not is_bot(num) then
				snapshot(num)
			end
		elseif final then
			-- a slot that is empty now may still hold the numbers of a player
			-- who left: his record was snapshotted before he disconnected
			by_slot[num] = nil
		end
	end
end

-- ============================= categories ================================

-- value        - record field, or a function returning the number to rank by
-- min          - the winner needs at least this much to be announced
-- qualifies    - optional extra test on the record
-- text         - how the value is shown after the name
local function count(unit)
	return function(v) return int(v) .. " " .. unit end
end

local function ratio(a, b)
	if b <= 0 then return a end
	return a / b
end

local CATEGORIES = {
	{ title = "Deadliest",           group = COLOR_GAMEPLAY, value = "kills", min = 5, text = count("kills") },
	{ title = "Efficient killer",    group = COLOR_GAMEPLAY, value = function(r) return ratio(r.kills, r.deaths) end,
		min = 0, qualifies = function(r) return r.kills >= 10 end, text = function(v) return string.format("%.2f K/D", v) end },
	{ title = "Headhunter",          group = COLOR_GAMEPLAY, value = "headshots", min = 1, text = count("headshots") },
	{ title = "Silent blade",        group = COLOR_GAMEPLAY, value = "knife_kills", min = 1, text = count("knife kills") },
	{ title = "Demolitions expert",  group = COLOR_GAMEPLAY, value = "explosive_kills", min = 3, text = count("explosive kills") },
	{ title = "Heavy hitter",        group = COLOR_GAMEPLAY, value = "damage_given", min = 100, text = count("damage") },
	{ title = "Spray and pray",      group = COLOR_GAMEPLAY, value = "shots", min = 100, text = count("shots fired") },
	{ title = "Killing machine",     group = COLOR_GAMEPLAY, value = "best_spree", min = 5, text = count("kill spree") },

	{ title = "Angel of Mercy",      group = COLOR_TEAM, value = "revives", min = 1, text = count("revives") },
	{ title = "Most XP earned",      group = COLOR_TEAM, value = "xp", min = 1, text = count("XP") },
	{ title = "Iron man",            group = COLOR_TEAM, value = "time_played", min = 0,
		ignore_min_play = true, text = function(v) return int(v / 60000) .. " min played" end },
	{ title = "Butcher",             group = COLOR_TEAM, value = "gibs", min = 1, text = count("gibs") },

	{ title = "Cannon fodder",       group = COLOR_FUN, value = "deaths", min = 5, text = count("deaths") },
	{ title = "Friendly fire",       group = COLOR_FUN, value = "team_kills", min = 1, text = count("team kills") },
	{ title = "Suicide king",        group = COLOR_FUN, value = "self_kills", min = 1, text = count("self kills") },
	{ title = "Sharp eye",           group = COLOR_FUN, value = function(r) return 100 * ratio(r.hits, r.shots) end,
		min = 0, qualifies = function(r) return r.shots >= 100 end, text = function(v) return string.format("%.1f%% accuracy", v) end },
}

-- best record for one category, nil when nobody qualifies
local function winner_of(category)
	local best, best_value
	for _, rec in pairs(data) do
		if (show_bots() or not rec.bot)
			and (category.ignore_min_play or (rec.time_played or 0) >= MIN_PLAY_MS)
			and (not category.qualifies or category.qualifies(rec))
		then
			local value = category.value
			if type(value) == "function" then value = value(rec) else value = rec[value] or 0 end
			if value >= (category.min or 0) and value > 0 then
				if not best
					or value > best_value
					or (value == best_value and (rec.time_played or 0) > (best.time_played or 0))
					or (value == best_value and (rec.time_played or 0) == (best.time_played or 0) and rec.name < best.name)
				then
					best, best_value = rec, value
				end
			end
		end
	end
	if not best then return nil end
	return best, best_value
end

-- ============================== output ===================================

-- cut a coloured string to `max` visible characters (the ^x codes are kept,
-- they do not count). cpm popups have a hard limit, chat lines do not.
local function truncate(text, max)
	local out, visible = {}, 0
	local i, len = 1, #text
	while i <= len do
		local char = text:sub(i, i)
		if char == "^" and i < len then
			out[#out + 1] = text:sub(i, i + 1)
			i = i + 2
		else
			if visible >= max then
				out[#out + 1] = ".."
				break
			end
			out[#out + 1] = char
			visible = visible + 1
			i = i + 1
		end
	end
	return table.concat(out)
end

local function say(text)
	local mode = messages()
	if mode == 1 or mode == 3 then
		et.trap_SendConsoleCommand(et.EXEC_APPEND, 'cchat -1 "' .. text .. '";')
	end
	if mode == 2 or mode == 3 then
		et.trap_SendConsoleCommand(et.EXEC_APPEND, 'cpm "' .. truncate(text, 52) .. '";')
	end
end

local function announce()
	if not is_enabled() then return end
	if type(et) ~= "table" or type(et.trap_SendConsoleCommand) ~= "function" then return end

	snapshot_all(true)

	local rows = {}
	for _, category in ipairs(CATEGORIES) do
		local rec, value = winner_of(category)
		if rec then
			local text = category.text and category.text(value) or int(value)
			rows[#rows + 1] = {
				line = COLOR_TEXT .. category.title .. COLOR_TEXT .. ": " .. COLOR_NAME .. rec.name
					.. " " .. COLOR_VALUE .. "(" .. text .. ")",
				plain = category.title .. ": " .. rec.name .. " (" .. text .. ")",
			}
			if ROW_LIMIT > 0 and #rows >= ROW_LIMIT then break end
		end
	end

	if #rows == 0 then
		log("map ended without a single award to hand out")
		return
	end

	local map = "this map"
	if type(et.trap_Cvar_Get) == "function" then
		local name = et.trap_Cvar_Get("mapname")
		if name and name ~= "" then map = name end
	end

	say(COLOR_TEXT .. "== " .. TITLE .. " ==" .. COLOR_VALUE .. " " .. map)
	for _, row in ipairs(rows) do
		say(row.line)
	end

	if LOG_TO_CONSOLE then
		local block = { TITLE .. " - " .. map }
		for _, row in ipairs(rows) do block[#block + 1] = "  " .. row.plain end
		log(table.concat(block, "\n"))
	end
end

-- ============================== events ===================================

local function on_client_connect(clientId)
	-- ClientConnect() cleared the gclient_t: a new player in this slot gets a
	-- new record, the old one stays in data for the end-of-map results
	by_slot[clientId] = nil
end

local function on_client_disconnect(clientId)
	if not is_enabled() then return end
	if show_bots() or not is_bot(clientId) then
		snapshot(clientId)   -- last chance to read this client's counters
	end
	by_slot[clientId] = nil
end

local function on_game_frame(levelTime)
	if not is_enabled() then return end
	local now = type(et.trap_Milliseconds) == "function" and (et.trap_Milliseconds() or 0) or (levelTime or 0)
	if last_snapshot and now - last_snapshot < SNAPSHOT_MS then return end
	last_snapshot = now
	snapshot_all(false)
end

local function on_player_death(victimId, killerId, mod)
	if not is_enabled() then return end
	if type(victimId) ~= "number" then return end

	local victim = record(victimId, true)
	if victim then victim.spree = 0 end

	if type(killerId) ~= "number" or killerId < 0 or killerId >= 1022 then return end
	if killerId == victimId then return end
	if number(killerId, "sess.sessionTeam") == number(victimId, "sess.sessionTeam") then return end

	local killer = record(killerId, true)
	if not killer then return end
	add(killer, "spree", 1)
	if killer.spree > killer.best_spree then killer.best_spree = killer.spree end
end

local function on_player_revive(clientMedic, clientVictim)
	if not is_enabled() then return end
	if type(clientMedic) ~= "number" or type(clientVictim) ~= "number" then return end
	if clientMedic == clientVictim then return end

	local medic = record(clientMedic, true)
	if medic then add(medic, "revives", 1) end
end

local function on_game_state_change(gameState)
	if gameState == constants.GAME_STATE_INTERMISSION then
		announce()
	end
	-- a new round keeps the same records: the engine counters keep counting
	-- within a map, and a restart is handled by onGameInit below
end

local function on_game_init(levelTime, randomSeed, restartMap)
	data, by_slot = {}, {}
	last_snapshot = 0
	if is_enabled() then
		log("Roll of Honor ready - set " .. CVAR .. " 0 to disable")
	end
end

events.handle("onGameInit",         on_game_init)
events.handle("onGameFrame",        on_game_frame)
events.handle("onGameStateChange",  on_game_state_change)
events.handle("onClientConnect",    on_client_connect)
events.handle("onClientDisconnect", on_client_disconnect)
events.handle("onPlayerDeath",      on_player_death)
events.handle("onPlayerRevive",     on_player_revive)

-- ============================== public API ===============================

-- used by tests and by a possible !honors command later on
function honors.get(key) return data[key] end
function honors.all() return data end
function honors.announce() announce() end
function honors.categories() return CATEGORIES end

return honors
