-- Minimal stand-in for ET:Legacy's Lua API, precise enough to catch the
-- class of bug reported on the server:
--
--   [wolfadmin:gameplay] warning: client slot 3 has no client fields
--   (tried to get invalid gentity field "ps.weapons")
--
-- That message came from et.gentity_get() raising. The important part is
-- *why* it raises, so this stub mirrors the real rules from ET:Legacy's
-- src/game/g_lua.c:
--
--   * field names are looked up in the engine's own tables
--     (_et_gclient_addfield / _et_gentity_addfield); an unknown name raises
--     "tried to get invalid gentity field \"<name>\"".
--   * client fields sit in gclient_fields and are only found while the slot
--     owns a gclient_t (g_entities[i].client); ClientConnect() sets it for
--     i < level.maxclients (= g_maxclients) and for anyone connecting into a
--     higher slot, and nothing clears it again.
--   * the field tables have no ps.weapons: only ps.weapon/ps.weaponstate.
--     Pass expose_weapon_mask = true to model an engine that has it.
--   * the old-style accessors return nil for a slot that is not inuse
--     (the field-table API reads the raw struct, so an unused slot simply
--     reads as its memset value: inuse = 0)
--
-- Everything the gameplay module touches (weapon grants, ammo pools, the
-- SetWolfSpawnWeapons() load-out from bg_classes.c, tracings) is modelled
-- after the engine so the tests exercise real behaviour, not mocks that
-- always say yes.

local stub = {}

local MAX_CLIENTS  = 64
local MAX_GENTITIES = 1024

-- ammoIndex / clipIndex from weaponTable[] (bg_misc.c). Everything that is
-- not listed uses its own weapon number, like the engine's table does.
local AMMO_INDEX = {
	[14] = 2,    -- WP_SILENCER          -> luger pool
	[35] = 7,    -- WP_AKIMBO_COLT       -> colt reserve
	[36] = 2,    -- WP_AKIMBO_LUGER      -> luger reserve
	[39] = 7,    -- WP_SILENCED_COLT     -> colt pool
	[44] = 11,   -- WP_MEDIC_ADRENALINE  -> syringe pool
	[45] = 7,    -- WP_AKIMBO_SILENCEDCOLT
	[46] = 2,    -- WP_AKIMBO_SILENCEDLUGER
}
local CLIP_INDEX = {
	[35] = 35, [45] = 35,   -- akimbo clips have their own pool
	[36] = 36, [46] = 36,
	[44] = 11,              -- WP_MEDIC_ADRENALINE -> the syringe's clip
	[39] = 7,               -- WP_SILENCED_COLT    -> colt pool
}

-- client fields the engine exposes (gclient_fields in g_lua.c), as paths into
-- the per-client table this stub keeps. "array" fields take a trailing index.
local CLIENT_FIELDS = {
	["pers.connected"] = { "pers", "connected" },
	["pers.netname"] = { "pers", "netname" },
	["sess.sessionTeam"] = { "sess", "sessionTeam" },
	["sess.playerType"] = { "sess", "playerType" },
	["sess.playerWeapon"] = { "sess", "playerWeapon" },
	["sess.playerWeapon2"] = { "sess", "playerWeapon2" },
	["sess.latchPlayerType"] = { "sess", "latchPlayerType" },
	["sess.latchPlayerWeapon"] = { "sess", "latchPlayerWeapon" },
	["sess.latchPlayerWeapon2"] = { "sess", "latchPlayerWeapon2" },
	["ps.stats"] = { "ps", "stats", array = true },
	["ps.origin"] = { "ps", "origin" },
	["ps.viewangles"] = { "ps", "viewangles" },
	["ps.viewheight"] = { "ps", "viewheight" },
	["ps.weapon"] = { "ps", "weapon" },
	["ps.weaponstate"] = { "ps", "weaponstate" },
	["ps.weapons"] = { "ps", "weapons", array = true, weapon_mask = true },
	["ps.ammo"] = { "ps", "ammo", array = true },
	["ps.ammoclip"] = { "ps", "ammoclip", array = true },
	["ps.powerups"] = { "ps", "powerups", array = true },
	["ps.persistant"] = { "ps", "persistant", array = true },
	-- session stats the scoreboard and G_BuildEndgameStats() use
	["sess.kills"] = { "sess", "kills" },
	["sess.deaths"] = { "sess", "deaths" },
	["sess.gibs"] = { "sess", "gibs" },
	["sess.team_kills"] = { "sess", "team_kills" },
	["sess.self_kills"] = { "sess", "self_kills" },
	["sess.damage_given"] = { "sess", "damage_given" },
	["sess.damage_received"] = { "sess", "damage_received" },
	["sess.time_played"] = { "sess", "time_played" },
	["sess.skillpoints"] = { "sess", "skillpoints", array = true },
	["sess.startskillpoints"] = { "sess", "startskillpoints", array = true },
	-- FIELD_WEAPONSTAT: the read pushes {atts, deaths, headshots, hits, kills}
	["sess.aWeaponStats"] = { "sess", "aWeaponStats", weaponstat = true },
}

-- gentity fields (gentity_fields in g_lua.c) used by the modules under test
local GENTITY_FIELDS = {
	["inuse"] = { "inuse" },
	["classname"] = { "classname" },
	["origin"] = { "origin" },
	["s.eType"] = { "s", "eType" },
	["s.weapon"] = { "s", "weapon" },
	["s.pos"] = { "s", "pos" },
	["r.ownerNum"] = { "r", "ownerNum" },
	["r.currentOrigin"] = { "r", "currentOrigin" },
}


-- fields with FIELD_FLAG_READONLY in g_lua.c: et.gentity_set() raises for them
local READONLY = {
	["sess.time_played"] = true,
	["sess.skillpoints"] = true,
	["sess.startskillpoints"] = true,
	["sess.aWeaponStats"] = true,
	["pers.connected"] = true,
	["pers.netname"] = true,
	["ps.viewheight"] = true,
	["ps.weapon"] = true,
	["ps.weaponstate"] = true,
	["s.weapon"] = true,
}

-- One player class load-out per team, taken from bg_playerClasses in
-- bg_classes.c: the knife (WP_KNIFE for the axis, WP_KNIFE_KABAR for the
-- allies), the grenade, the primary, the secondary and the misc weapons. The
-- last number of each entry is the starting clip - for the weapons without
-- ammo of their own (knife, pliers, mines, smoke) the engine still sets it,
-- which is what the gameplay module's fallback relies on.
local CLASSES = {
	[1] = { -- TEAM_AXIS
		[0] = { -- PC_SOLDIER
			knife = { 1, 1, 0 }, primary = { 3, 60, 30 }, secondary = { 2, 24, 8 },
			grenade = { 4, 4, 0 },
		},
		[1] = { -- PC_MEDIC
			knife = { 1, 1, 0 }, primary = { 3, 0, 30 }, secondary = { 2, 24, 8 },
			grenade = { 4, 1, 0 }, misc = { { 11, 10, 1 }, { 19, 0, 1 } },
		},
		[2] = { -- PC_ENGINEER
			knife = { 1, 1, 0 }, primary = { 3, 30, 30 }, secondary = { 2, 24, 8 },
			grenade = { 4, 4, 0 }, misc = { { 16, 0, 1 }, { 21, 0, 1 }, { 26, 0, 1 } },
		},
		[3] = { -- PC_FIELDOPS
			knife = { 1, 1, 0 }, primary = { 3, 30, 30 }, secondary = { 2, 24, 8 },
			grenade = { 4, 4, 0 },
		},
		[4] = { -- PC_COVERTOPS
			knife = { 1, 1, 0 }, primary = { 54, 64, 32 }, secondary = { 14, 24, 8 },
			grenade = { 4, 2, 0 }, misc = { { 29, 0, 1 }, { 27, 0, 1 } },
		},
	},
	[2] = { -- TEAM_ALLIES
		[0] = {
			knife = { 48, 1, 0 }, primary = { 8, 60, 30 }, secondary = { 7, 24, 8 },
			grenade = { 9, 4, 0 },
		},
		[1] = {
			knife = { 48, 1, 0 }, primary = { 8, 0, 30 }, secondary = { 7, 24, 8 },
			grenade = { 9, 1, 0 }, misc = { { 11, 10, 1 }, { 19, 0, 1 } },
		},
		[2] = {
			knife = { 48, 1, 0 }, primary = { 8, 30, 30 }, secondary = { 7, 24, 8 },
			grenade = { 9, 4, 0 }, misc = { { 16, 0, 1 }, { 21, 0, 1 }, { 26, 0, 1 } },
		},
		[3] = {
			knife = { 48, 1, 0 }, primary = { 8, 30, 30 }, secondary = { 7, 24, 8 },
			grenade = { 9, 4, 0 },
		},
		[4] = {
			knife = { 48, 1, 0 }, primary = { 10, 40, 20 }, secondary = { 14, 24, 8 },
			grenade = { 9, 2, 0 }, misc = { { 29, 0, 1 }, { 27, 0, 1 } },
		},
	},
}

-- ps.weapons is int weapons[(WP_NUM_WEAPONS + 31) / 32]: COM_BitSet/COM_BitCheck
-- and the Lua array fields are all 0-based, so word 0 holds weapons 0..31.
-- COM_BitSet() is "|=", which is idempotent: setting a bit that is already set
-- is a no-op. Using "+" here instead would carry into the neighbouring bit and
-- silently rewrite the whole load-out whenever a weapon the player already owns
-- is granted again (which AddWeaponToPlayer does on every spawn, e.g. to top up
-- the knife clip).
local function bit_set(mask, w)
	local word = math.floor(w / 32)
	local v    = mask[word] or 0
	local bit  = 2 ^ (w % 32)
	if math.floor(v / bit) % 2 == 0 then
		mask[word] = v + bit
	end
end

local function bit_clear(mask, w)
	local word = math.floor(w / 32)
	local v = mask[word] or 0
	if math.floor(v / (2 ^ (w % 32))) % 2 == 1 then
		mask[word] = v - 2 ^ (w % 32)
	end
end

local function bit_get(mask, w)
	local v = mask[math.floor(w / 32)] or 0
	return math.floor(v / (2 ^ (w % 32))) % 2 == 1
end

-- ============================ the engine ==================================

-- opts.sv_maxclients    - cvar value the module reads (default 16)
-- opts.expose_weapon_mask - does this "engine" have the ps.weapons field?
function stub.new(opts)
	opts = opts or {}

	local engine = {}
	engine.log = {}
	engine.commands = {}
	engine.consoles = {}
	engine.damage = {}
	engine.ents = {}          -- [entnum] = { client = ..., inuse = ..., ... }
	engine.next_ent = MAX_CLIENTS
	engine.time = 1000
	engine.cvars = {
		sv_maxclients = tostring(opts.sv_maxclients or 16),
		g_gameplay = "1",
		g_honors = "1",
		mapname = "test_map",
	}
	engine.expose_weapon_mask = opts.expose_weapon_mask and true or false

	-- ---------------------------------------------------------------- entity
	local ZERO = {}   -- g_entities is memset at map start: an untouched slot reads 0/nil

	local function new_client(num)
		return {
			pers = { connected = 0, netname = "" },
			sess = {
				sessionTeam = 0, playerType = 0,
				playerWeapon = 0, playerWeapon2 = 0,
				latchPlayerType = 0, latchPlayerWeapon = 0, latchPlayerWeapon2 = 0,
				kills = 0, deaths = 0, gibs = 0, team_kills = 0, self_kills = 0,
				damage_given = 0, damage_received = 0, time_played = 0,
				skillpoints = {}, startskillpoints = {}, aWeaponStats = {},
			},
			sess_stats = nil,
			ps = {
				weapon = 0, weaponstate = 0, stats = { [0] = 0 },
				origin = { 0, 0, 0 }, viewangles = { 0, 0, 0 }, viewheight = 32,
				weapons = {}, ammo = {}, ammoclip = {}, powerups = {}, persistant = {},
			},
		}
	end

	-- G_InitGame(): every slot below level.maxclients (= g_maxclients) owns a
	-- gclient_t from the start, connected or not - that is exactly why the
	-- module can probe a field on slot 0. Slots above it only get one when
	-- somebody actually connects into them.
	local gclient_slots = tonumber(engine.cvars.sv_maxclients) or MAX_CLIENTS
	for i = 0, MAX_CLIENTS - 1 do
		engine.ents[i] = { inuse = 0, classname = "clientslot" }
		if i < gclient_slots then engine.ents[i].client = new_client(i) end
	end

	local function ent(num)
		engine.ents[num] = engine.ents[num] or {}
		return engine.ents[num]
	end

	local function client_field_path(name)
		local path = CLIENT_FIELDS[name]
		if not path then return nil end
		if path.weapon_mask and not engine.expose_weapon_mask then return nil end
		return path
	end

	-- like g_lua.c: client fields are only resolvable while the entity owns a
	-- gclient_t, everything else raises "invalid gentity field"
	local function lookup(entnum, name)
		local e = engine.ents[entnum] or ZERO
		local path = client_field_path(name)
		if path then
			if not e.client then return nil, name end
			return path, nil
		end
		if GENTITY_FIELDS[name] then return GENTITY_FIELDS[name], nil end
		return nil, name
	end

	local function get_path(root, path, index)
		local v = root
		for _, key in ipairs(path) do
			if type(v) ~= "table" then return nil end
			v = v[key]
		end
		if path.array then
			if type(v) ~= "table" then return nil end
			return v[index or 0]
		end
		return v
	end

	local function gentity_get(entnum, name, index)
		local e = engine.ents[entnum] or ZERO
		local path, bad = lookup(entnum, name)
		if not path then
			error("tried to get invalid gentity field \"" .. tostring(bad) .. "\"", 0)
		end
		if GENTITY_FIELDS[name] then
			-- plain struct read; an unused slot simply reads as 0/false
			return get_path(e, path, index)
		end
		if path.weaponstat then
			-- _etH_gentity_getweaponstat(): one weapon's block, indexed 1..5
			local all = get_path(e.client, path, nil)
			local ws = type(all) == "table" and all[index or 0] or nil
			if type(ws) ~= "table" then
				ws = { atts = 0, deaths = 0, headshots = 0, hits = 0, kills = 0 }
			end
			return { ws.atts or 0, ws.deaths or 0, ws.headshots or 0, ws.hits or 0, ws.kills or 0 }
		end
		return get_path(e.client, path, index)
	end

	local function gentity_set(entnum, name, val1, val2)
		local e = engine.ents[entnum] or ZERO
		local path, bad = lookup(entnum, name)
		if not path then
			error("tried to set invalid gentity field \"" .. tostring(bad) .. "\"", 0)
		end
		if READONLY[name] then
			error("tried to set read-only gentity field \"" .. name .. "\"", 0)
		end
		local root = GENTITY_FIELDS[name] and e or e.client
		if not root then return 0 end
		local parent = root
		for i = 1, #path - 1 do
			parent[path[i]] = parent[path[i]] or {}
			parent = parent[path[i]]
		end
		local key = path[#path]
		if path.array then
			parent[key] = parent[key] or {}
			parent[key][val1] = val2
		else
			parent[key] = val1
		end
		return 0
	end

	-- ------------------------------------------------------------------ API
	local et        -- forward declaration (assigned below)

	-- _et_AddWeaponToPlayer (g_lua.c): refuses a slot that owns no gclient_t
	-- ("clientNum is not a client entity"), assigns the ammo pools - it does
	-- not add to them - and optionally puts the weapon in hand. It is not the
	-- C AddWeaponToPlayer() from g_client.c, which also rolls in skill ammo.
	local function add_weapon(num, w, ammo, clip, setcurrent)
		local e = engine.ents[num]
		if not (e and e.client) then
			error("clientNum \"" .. tostring(num) .. "\" is not a client entity", 0)
		end
		local c = e.client
		bit_set(c.ps.weapons, w)
		c.ps.ammoclip[CLIP_INDEX[w] or w] = clip or 0
		c.ps.ammo[AMMO_INDEX[w] or w] = ammo or 0
		if setcurrent == 1 then c.ps.weapon = w end
		return true
	end

	local function remove_weapon(num, w)
		local e = engine.ents[num]
		if not (e and e.client) then
			error("clientNum \"" .. tostring(num) .. "\" is not a client entity", 0)
		end
		bit_clear(e.client.ps.weapons, w)
		return true
	end

	et = {
		MAX_CLIENTS = MAX_CLIENTS,
		MAX_GENTITIES = MAX_GENTITIES,
		STAT_HEALTH = 0,
		TEAM_FREE = 0, TEAM_AXIS = 1, TEAM_ALLIES = 2, TEAM_SPECTATOR = 3,
		MASK_SOLID = 1, MASK_SHOT = 0x100000,
		WP_KNIFE = 1, WP_LUGER = 2, WP_MP40 = 3, WP_GRENADE_LAUNCHER = 4,
		WP_COLT = 7, WP_THOMPSON = 8, WP_GRENADE_PINEAPPLE = 9, WP_STEN = 10,
		WP_MEDIC_SYRINGE = 11, WP_SILENCER = 14, WP_DYNAMITE = 16,
		WP_MEDKIT = 19, WP_PLIERS = 21, WP_SMOKE_MARKER = 22,
		WP_LANDMINE = 26, WP_SATCHEL = 27, WP_SMOKE_BOMB = 29,
		WP_AKIMBO_COLT = 35, WP_AKIMBO_LUGER = 36, WP_SILENCED_COLT = 39,
		WP_MEDIC_ADRENALINE = 44, WP_AKIMBO_SILENCEDCOLT = 45,
		WP_AKIMBO_SILENCEDLUGER = 46, WP_KNIFE_KABAR = 48, WP_MP34 = 54,
		MOD_KNIFE = 5, MOD_SYRINGE = 24,
		PW_OPS_DISGUISED = 7,

		gentity_get = gentity_get,
		gentity_set = gentity_set,

		G_Print = function(msg) engine.log[#engine.log + 1] = tostring(msg) end,
		G_SoundIndex = function() return 1 end,
		trap_Cvar_Get = function(name) return engine.cvars[name] or "" end,
		trap_Cvar_Set = function(name, value) engine.cvars[name] = tostring(value) end,
		trap_Milliseconds = function()
			engine.time = engine.time + 50
			return engine.time
		end,
		trap_SendServerCommand = function(num, cmd)
			engine.commands[#engine.commands + 1] = { num = num, cmd = cmd }
		end,
		trap_SendConsoleCommand = function(exec, cmd)
			engine.consoles[#engine.consoles + 1] = { exec = exec, cmd = tostring(cmd) }
		end,
		trap_Argv = function(i) return engine.argv and engine.argv[i + 1] or "" end,
		trap_LinkEntity = function() end,
		trap_UnlinkEntity = function() end,
		trap_Trace = function(startpos, mins, maxs, endpos, passent, mask)
			return { entityNum = MAX_GENTITIES - 1, fraction = 1, endpos = endpos }
		end,
		AddWeaponToPlayer = add_weapon,
		RemoveWeaponFromPlayer = remove_weapon,
		G_Damage = function(target, inflictor, attacker, damage, flags, mod)
			engine.damage[#engine.damage + 1] =
				{ target = target, attacker = attacker, damage = damage, mod = mod }
		end,
		G_Spawn = function()
			local num = engine.next_ent
			engine.next_ent = num + 1
			local e = ent(num)
			e.inuse = 1
			e.classname = "noclass"
			e.s = {}
			e.r = {}
			return num
		end,
		G_FreeEntity = function(num)
			local e = engine.ents[num]
			if e then e.inuse = 0 end
		end,
	}

	-- ------------------------------------------------------------- test API
	-- a connected client, as ClientConnect()/ClientBegin() leave it
	function engine.connect(num, team, class, opts2)
		opts2 = opts2 or {}
		local e = ent(num)
		-- ClientConnect() memsets the gclient_t and sets ent->client
		e.client = new_client(num)
		e.client.pers.connected = 2
		e.client.pers.netname = "Player" .. num
		e.client.sess.sessionTeam = team
		e.client.sess.playerType = class
		e.client.sess.latchPlayerType = class
		e.client.ps.stats[0] = 100
		e.inuse = 1                    -- ClientBegin() -> G_InitGentity()
		e.classname = "clientslot"
		engine.class_of = engine.class_of or {}
		engine.class_of[num] = { team = team, class = class, opts = opts2 }
		return e
	end

	-- ClientSpawn() -> SetWolfSpawnWeapons(): pools cleared, then the class
	-- weapons added, exactly like g_client.c does it
	function engine.spawn(num)
		local info = engine.class_of[num]
		assert(info, "client " .. tostring(num) .. " is not connected")
		local e = engine.ents[num]
		local c = e.client
		local loadout = CLASSES[info.team][info.class]
		assert(loadout, "no class table for team/class " .. info.team .. "/" .. info.class)

		c.ps.ammo, c.ps.ammoclip, c.ps.weapons = {}, {}, {}
		c.ps.weapon, c.ps.weaponstate = 0, 0
		c.ps.stats[0] = 100

		local function give(entry, current)
			add_weapon(num, entry[1], entry[2], entry[3], current and 1 or 0)
		end

		give(loadout.knife, true)
		if loadout.grenade then give(loadout.grenade, false) end

		local primary = { loadout.primary[1], loadout.primary[2], loadout.primary[3] }
		local secondary = { loadout.secondary[1], loadout.secondary[2], loadout.secondary[3] }
		if info.opts.primary then primary = info.opts.primary end
		if info.opts.secondary then secondary = info.opts.secondary end

		give(primary, true)
		c.sess.playerWeapon = primary[1]
		c.sess.latchPlayerWeapon = primary[1]

		if secondary[1] ~= primary[1] then give(secondary, false) end
		c.sess.playerWeapon2 = secondary[1]
		c.sess.latchPlayerWeapon2 = secondary[1]

		for _, misc in ipairs(loadout.misc or {}) do give(misc, false) end
		c.sess.playerType = info.class
		c.sess.latchPlayerType = info.class
		return c
	end

	function engine.parse_command(text)
		engine.argv = {}
		for word in tostring(text):gmatch("%S+") do
			engine.argv[#engine.argv + 1] = word
		end
		return text
	end

	function engine.client(num) return engine.ents[num] and engine.ents[num].client end
	function engine.has_weapon(num, w)
		local c = engine.client(num)
		return c ~= nil and bit_get(c.ps.weapons, w)
	end
	engine.add_weapon = add_weapon

	-- session stats as the engine would have them at this point
	function engine.set_stats(num, t)
		local c = engine.client(num)
		assert(c, "client " .. tostring(num) .. " is not connected")
		for k, v in pairs(t) do c.sess[k] = v end
		return c
	end

	-- skillpoints (current) and startskillpoints (value at map start)
	function engine.set_skillpoints(num, skill, current, start)
		local c = engine.client(num)
		c.sess.skillpoints[skill] = current
		c.sess.startskillpoints[skill] = start or 0
		return c
	end

	-- sess.aWeaponStats[ws] - see extWeaponStats_t in bg_public.h
	function engine.set_weapon_stats(num, ws, t)
		local c = engine.client(num)
		c.sess.aWeaponStats[ws] = {
			atts = t.atts or t[1] or 0, deaths = t.deaths or t[2] or 0,
			headshots = t.headshots or t[3] or 0, hits = t.hits or t[4] or 0,
			kills = t.kills or t[5] or 0,
		}
		return c
	end

	-- moves the engine clock, so the module's snapshot interval passes
	function engine.advance(ms)
		engine.time = engine.time + (ms or 0)
		return engine.time
	end

	function engine.console_text()
		local out = {}
		for _, c in ipairs(engine.consoles) do out[#out + 1] = c.cmd end
		return table.concat(out, "\n")
	end

	function engine.console_count(pattern)
		local n = 0
		for _, c in ipairs(engine.consoles) do
			if c.cmd:find(pattern, 1, true) then n = n + 1 end
		end
		return n
	end

	function engine.log_text()
		return table.concat(engine.log, "\n")
	end

	function engine.count(pattern)
		local n = 0
		for _, line in ipairs(engine.log) do
			if line:find(pattern, 1, true) then n = n + 1 end
		end
		return n
	end

	function engine.install()
		_G.et = et
		return et
	end

	return engine
end

stub.MAX_CLIENTS = MAX_CLIENTS
stub.MAX_GENTITIES = MAX_GENTITIES
stub.CLIENT_FIELDS = CLIENT_FIELDS
stub.GENTITY_FIELDS = GENTITY_FIELDS
stub.CLASSES = CLASSES

return stub
