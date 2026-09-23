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
--
-- Two of those used to be mocks that always said yes, and both hid a real bug:
--
--   * et.G_Spawn() does not exist in g_lua.c's etlib[] table. The stub provided
--     it anyway, so a whole feature was written against an API the engine never
--     had and the tests could not tell. It is gone; et.G_CreateEntity() (the
--     only entity constructor Lua gets) and et.G_ModelIndex() are modelled
--     instead, with real spawn-var parsing and the real G_FreeEntity() memset
--     semantics.
--   * et.trap_Trace() returned "hit nothing" for every call. It now sweeps the
--     segment against engine.world (see stub.add_wall) and against every live
--     client's playerMins/playerMaxs box, honouring the mask and the passant.
--
-- engine.place(num, origin, viewangles) and engine.health(num, hp) set the
-- world up for those traces; engine.trace_log / link_log / gent_create_log /
-- gent_free_log / models record what the module asked the engine to do, and
-- stub.wolfadmin_client_command() stands in for commands/commands.lua's
-- handler, which main.lua registers before game.gameplay's.

local stub = {}

local MAX_CLIENTS  = 64
local MAX_GENTITIES = 1024

-- Contents bits from qcommon/q_shared.h (ET renames CONTENTS_MONSTER and
-- CONTENTS_DEADMONSTER to CONTENTS_BODY / CONTENTS_CORPSE) and the masks from
-- game/bg_public.h. The stub used to invent MASK_SHOT = 0x100000; with the real
-- values a module that traces with the wrong mask is caught instead of waved
-- through.
local CONTENTS_SOLID       = 1
local CONTENTS_MISSILECLIP = 128
local CONTENTS_BODY        = 0x02000000
local CONTENTS_CORPSE      = 0x04000000
local MASK_SHOT            = CONTENTS_SOLID + CONTENTS_BODY + CONTENTS_CORPSE   -- 0x06000001
local MASK_MISSILESHOT     = MASK_SHOT + CONTENTS_MISSILECLIP                   -- 0x06000081

-- meansOfDeath_t (bg_public.h). MOD_KNIFE and MOD_SYRINGE already matched the
-- engine; MOD_KNIFE_KABAR is the one the throwable knife reports for allies.
local MOD_KNIFE            = 5
local MOD_SYRINGE          = 24
local MOD_SUICIDE          = 33
local MOD_KNIFE_KABAR      = 61

-- g_client.c playerMins/playerMaxs and bg_public.h DEFAULT_VIEWHEIGHT: what a
-- trace can hit on a standing player, and where their eyes are.
local PLAYER_MINS = { -18, -18, -24 }
local PLAYER_MAXS = {  18,  18,  48 }
local DEFAULT_VIEWHEIGHT = 40

-- trace_t.entityNum when the trace hit the world rather than an entity
local ENTITYNUM_NONE = MAX_GENTITIES - 1

-- contents/mask bit test without Lua 5.3's & operator: every CONTENTS_* bit is
-- a power of two, and the values are small enough to stay exact in a double.
local function mask_has(mask, bit)
	if bit == 0 then return false end
	return math.floor((mask or 0) / bit) % 2 == 1
end

-- the debug logs are capped so a long spec run cannot grow them without bound
local LOG_CAP = 4000
local function log_push(t, entry)
	if #t < LOG_CAP then t[#t + 1] = entry end
	return entry
end

---------------------------------------------------------------------------
-- Segment vs axis-aligned box, the slab method, with the target expanded by the
-- trace's own extents -- that is what CM_BoxTrace() does for a box sweep.
-- Returns the entry fraction in [0, 1] and whether the sweep started inside.
---------------------------------------------------------------------------
local function segment_vs_box(start, finish, bmins, bmaxs, tmins, tmaxs)
	local lo, hi, dir = {}, {}, {}
	for i = 1, 3 do
		lo[i]  = bmins[i] - tmaxs[i]
		hi[i]  = bmaxs[i] - tmins[i]
		dir[i] = finish[i] - start[i]
	end
	local tmin, tmax = 0, 1
	for i = 1, 3 do
		if math.abs(dir[i]) < 1e-9 then
			if start[i] < lo[i] or start[i] > hi[i] then return nil end
		else
			local t1 = (lo[i] - start[i]) / dir[i]
			local t2 = (hi[i] - start[i]) / dir[i]
			if t1 > t2 then t1, t2 = t2, t1 end
			if t1 > tmin then tmin = t1 end
			if t2 < tmax then tmax = t2 end
			if tmin > tmax then return nil end
		end
	end
	return tmin, (tmin <= 0)
end

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
	-- FIELD_VEC3 in g_lua.c: read and written as one table with the keys 1..3
	["ps.origin"] = { "ps", "origin", vec3 = true },
	["ps.viewangles"] = { "ps", "viewangles", vec3 = true },
	["ps.velocity"] = { "ps", "velocity", vec3 = true },
	-- movement state, all FIELD_INT and all FIELD_FLAG_READONLY
	["ps.pm_flags"] = { "ps", "pm_flags" },
	["ps.pm_type"] = { "ps", "pm_type" },
	["ps.eFlags"] = { "ps", "eFlags" },
	["freezed"] = { "freezed" },
	["noclip"] = { "noclip" },
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
	-- ent->health and ent->takedamage: FIELD_INT, both writable
	["health"] = { "health" },
	["takedamage"] = { "takedamage" },
	["origin"] = { "origin", vec3 = true },
	["s.eType"] = { "s", "eType" },
	["s.weapon"] = { "s", "weapon" },
	["s.pos"] = { "s", "pos" },
	["r.ownerNum"] = { "r", "ownerNum" },
	["r.currentOrigin"] = { "r", "currentOrigin", vec3 = true },
	["r.mins"] = { "r", "mins", vec3 = true },
	["r.maxs"] = { "r", "maxs", vec3 = true },
	["r.contents"] = { "r", "contents" },
	["r.linked"] = { "r", "linked" },
	["s.number"] = { "s", "number" },
	["s.modelindex"] = { "s", "modelindex" },
	["s.angles"] = { "s", "angles", vec3 = true },
	["s.apos"] = { "s", "apos" },
	-- the burning window. The engine reads both back against level.time in its
	-- flamethrower burn loop (g_active.c:196-206), which is why !burn and
	-- !firegod have to stamp them from the level clock (GAMEPLAY-FIX.md 9.1).
	["s.onFireStart"] = { "s", "onFireStart" },
	["s.onFireEnd"] = { "s", "onFireEnd" },
	["clipmask"] = { "clipmask" },
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
	["ps.origin"] = true,
	["ps.viewangles"] = true,
	["ps.pm_flags"] = true,
	["ps.pm_type"] = true,
	["ps.eFlags"] = true,
	["noclip"] = true,
	["ps.weapon"] = true,
	["ps.weaponstate"] = true,
	["s.weapon"] = true,
	["s.number"] = true,
	["r.linked"] = true,
}
-- s.number and r.linked carry FIELD_FLAG_READONLY in g_lua.c, so Lua may not
-- write them, but the engine itself does. The stub's own spawn/link/free paths
-- therefore assign them straight onto the table instead of going through
-- gentity_set().

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
	engine.world = {}         -- solid level geometry trap_Trace can hit
	engine.trace_log = {}     -- every trap_Trace call: {start, end, passent, mask}
	engine.link_log = {}      -- every trap_LinkEntity call: {number, origin}
	engine.gent_create_log = {}
	engine.gent_free_log = {}
	engine.models = {}        -- G_ModelIndex() names, in allocation order
	engine.model_indexes = {} -- [name] = CS_MODELS index
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
				origin = { 0, 0, 0 }, viewangles = { 0, 0, 0 },
				velocity = { 0, 0, 0 },
				pm_flags = 0, pm_type = 0, eFlags = 0,
				viewheight = DEFAULT_VIEWHEIGHT,
				weapons = {}, ammo = {}, ammoclip = {}, powerups = {}, persistant = {},
			},
			freezed = 0, noclip = 0,
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
		if path.vec3 then
			-- _etH_gentity_setvec3() indexes the value with the keys 1..3, so a
			-- FIELD_VEC3 takes one table. Handing it a component index instead
			-- makes the real engine raise "attempt to index a number value" -
			-- the failure that left !freeze, !throw and !launch doing nothing
			-- on a server (GAMEPLAY-FIX.md 9.2). The stub has to fail the same
			-- way, or a spec cannot see it.
			if type(val1) ~= "table" then
				error("attempt to index a " .. type(val1) .. " value", 0)
			end
			parent[key] = { val1[1] or 0, val1[2] or 0, val1[3] or 0 }
		elseif path.array then
			-- FIELD_INT_ARRAY / FIELD_FLOAT_ARRAY: (index, value)
			if type(val1) ~= "number" or type(val2) ~= "number" then
				error("bad argument to gentity_set (number expected, got " ..
					type(val1) .. ", " .. type(val2) .. ")", 0)
			end
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
		CONTENTS_SOLID = CONTENTS_SOLID, CONTENTS_MISSILECLIP = CONTENTS_MISSILECLIP,
		CONTENTS_BODY = CONTENTS_BODY, CONTENTS_CORPSE = CONTENTS_CORPSE,
		MASK_SOLID = CONTENTS_SOLID, MASK_SHOT = MASK_SHOT,
		MASK_MISSILESHOT = MASK_MISSILESHOT,
		MASK_PLAYERSOLID = CONTENTS_SOLID + 0x00010000 + CONTENTS_BODY,
		WP_KNIFE = 1, WP_LUGER = 2, WP_MP40 = 3, WP_GRENADE_LAUNCHER = 4,
		WP_COLT = 7, WP_THOMPSON = 8, WP_GRENADE_PINEAPPLE = 9, WP_STEN = 10,
		WP_MEDIC_SYRINGE = 11, WP_SILENCER = 14, WP_DYNAMITE = 16,
		WP_MEDKIT = 19, WP_PLIERS = 21, WP_SMOKE_MARKER = 22,
		WP_LANDMINE = 26, WP_SATCHEL = 27, WP_SMOKE_BOMB = 29,
		WP_AKIMBO_COLT = 35, WP_AKIMBO_LUGER = 36, WP_SILENCED_COLT = 39,
		WP_MEDIC_ADRENALINE = 44, WP_AKIMBO_SILENCEDCOLT = 45,
		WP_AKIMBO_SILENCEDLUGER = 46, WP_KNIFE_KABAR = 48, WP_MP34 = 54,
		MOD_KNIFE = MOD_KNIFE, MOD_SYRINGE = MOD_SYRINGE,
		MOD_SUICIDE = MOD_SUICIDE, MOD_KNIFE_KABAR = MOD_KNIFE_KABAR,
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
		trap_Argc = function() return engine.argv and #engine.argv or 0 end,
		-- SV_LinkEntity() reads r.currentOrigin (not origin) to work out which
		-- leaf sectors the entity belongs to, so this only records that the
		-- caller re-linked after moving the entity.
		trap_LinkEntity = function(num)
			local e = engine.ents[num]
			if not e then return end
			e.r = e.r or {}
			e.r.linked = true          -- engine-side write, not a Lua field set
			local o = e.r.currentOrigin or e.origin or { 0, 0, 0 }
			log_push(engine.link_log, { number = num, origin = { o[1], o[2], o[3] } })
		end,
		trap_UnlinkEntity = function(num)
			local e = engine.ents[num]
			if e and e.r then e.r.linked = false end
		end,

		-- A real trace. The stub used to hand back "hit nothing" for every call,
		-- which is why a knife that could not hit anything at all still passed
		-- the test suite. This sweeps the segment against the level geometry in
		-- engine.world and against every live client's bounding box, honours
		-- CONTENTS_BODY/CONTENTS_CORPSE in the mask, skips the passent entity
		-- (the thrower, whose box the muzzle starts inside) and returns the
		-- table shape _etH_gettrace() builds in g_lua.c.
		trap_Trace = function(startpos, mins, maxs, endpos, passent, mask)
			local s = { startpos[1], startpos[2], startpos[3] }
			local f = { endpos[1], endpos[2], endpos[3] }
			local tm = mins or { 0, 0, 0 }
			local tx = maxs or { 0, 0, 0 }
			mask = mask or 0
			log_push(engine.trace_log, {
				start = { s[1], s[2], s[3] }, end_ = { f[1], f[2], f[3] },
				passent = passent, mask = mask,
			})

			local best = {
				fraction = 1, entityNum = ENTITYNUM_NONE,
				startsolid = false, allsolid = false,
				endpos = { f[1], f[2], f[3] },
				plane = { 0, 0, 0 }, surfaceFlags = 0, contents = 0,
			}
			local function hit(t, startsolid, entnum, contents)
				best = {
					fraction = t,
					endpos = { s[1] + (f[1] - s[1]) * t, s[2] + (f[2] - s[2]) * t,
					           s[3] + (f[3] - s[3]) * t },
					entityNum = entnum,
					startsolid = startsolid and true or false,
					allsolid = startsolid and true or false,
					plane = { 0, 0, 0 }, surfaceFlags = 0,
					contents = contents or 0,
				}
			end

			-- level geometry: engine.world is a list of {mins, maxs, contents}
			for _, box in ipairs(engine.world) do
				local bc = box.contents or CONTENTS_SOLID
				if mask_has(mask, bc) then
					local t, ss = segment_vs_box(s, f, box.mins, box.maxs, tm, tx)
					if t and t < best.fraction then hit(t, ss, ENTITYNUM_NONE, bc) end
				end
			end

			-- players: CONTENTS_BODY while alive, CONTENTS_CORPSE once dead
			for num, e in pairs(engine.ents) do
				if e.client and e.inuse == 1 and num ~= passent then
					local c = e.client
					local o = c.ps.origin
					local dead = (c.ps.stats[0] or 0) <= 0
					local bc = dead and CONTENTS_CORPSE or CONTENTS_BODY
					if mask_has(mask, bc) then
						local bmins = { o[1] + PLAYER_MINS[1], o[2] + PLAYER_MINS[2], o[3] + PLAYER_MINS[3] }
						local bmaxs = { o[1] + PLAYER_MAXS[1], o[2] + PLAYER_MAXS[2], o[3] + PLAYER_MAXS[3] }
						local t, ss = segment_vs_box(s, f, bmins, bmaxs, tm, tx)
						if t and t < best.fraction then hit(t, ss, num, bc) end
					end
				end
			end
			return best
		end,
		AddWeaponToPlayer = add_weapon,
		RemoveWeaponFromPlayer = remove_weapon,
		-- _et_G_Damage() does "g_entities + n" for all three entity numbers and
		-- never checks the range, so a number outside g_entities[0..1023] makes
		-- the engine read past the end of the array and hand G_Damage() whatever
		-- the linker put there as the attacker. The stub raises instead of
		-- guessing: staying quiet about it is how six admin commands came to send
		-- 1024 for "nobody" (GAMEPLAY-FIX.md 9.4).
		G_Damage = function(target, inflictor, attacker, damage, flags, mod)
			for label, num in pairs({ target = target, inflictor = inflictor, attacker = attacker }) do
				if type(num) ~= "number" or num < 0 or num >= MAX_GENTITIES then
					error("G_Damage: " .. label .. " entity number " .. tostring(num) ..
						" is outside g_entities[0.." .. (MAX_GENTITIES - 1) .. "]", 0)
				end
			end

			engine.damage[#engine.damage + 1] =
				{ target = target, attacker = attacker, damage = damage, mod = mod }
		end,
		-- There is NO et.G_Spawn(): g_lua.c's etlib[] table does not list it, so
		-- calling it raises "attempt to call a nil value". The stub used to
		-- provide one, which is exactly how the throwable knife came to be
		-- written against an API that does not exist. What the engine does
		-- expose is G_CreateEntity(spawnvars) -> entnum, which runs the string
		-- through G_SpawnGEntityFromSpawnVars().
		G_CreateEntity = function(params)
			local vars = stub.parse_spawnvars(params)
			-- G_Spawn() starts at MAX_CLIENTS: the first slots are the players
			local num
			for i = MAX_CLIENTS, MAX_GENTITIES - 1 do
				local e = engine.ents[i]
				if not (e and e.inuse == 1) then
					num = i
					break
				end
			end
			if not num then
				-- the engine calls G_Error() here, which brings the server down
				error("G_Spawn() - no free entities", 0)
			end
			local e = ent(num)
			stub.reset_gentity(e)
			stub.apply_spawnvars(e, vars)
			e.inuse = 1
			e.s.number = num            -- G_InitGentity(): engine-side write
			engine.next_ent = num + 1
			log_push(engine.gent_create_log, {
				number = num, classname = e.classname,
				origin = { e.origin[1], e.origin[2], e.origin[3] },
				vars = tostring(params),
			})
			-- G_CallSpawn() fails for a classname with no spawn function and
			-- G_SpawnGEntityFromSpawnVars() frees the entity again - but the
			-- number is still returned, so a caller that does not check inuse
			-- tracks a slot the engine has already given away.
			if not stub.SPAWN_CLASSES[e.classname or ""] then
				log_push(engine.gent_free_log, {
					number = num, classname = e.classname, reason = "no spawn function",
				})
				stub.reset_gentity(e)
				e.classname = "freed"
				e.s.number = num
				e.inuse = 0
			end
			return num
		end,

		G_ModelIndex = function(name)
			-- G_ModelIndex() (g_utils.c) allocates a CS_MODELS configstring;
			-- CG_General() draws cgs.gameModels[s.modelindex] from it
			local key = tostring(name or "")
			if not engine.model_indexes[key] then
				engine.models[#engine.models + 1] = key
				engine.model_indexes[key] = #engine.models
			end
			return engine.model_indexes[key]
		end,

		G_FreeEntity = function(num)
			local e = engine.ents[num]
			if not (e and e.inuse == 1) then return end
			log_push(engine.gent_free_log, { number = num, classname = e.classname })
			e.r = e.r or {}
			e.r.linked = false
			stub.reset_gentity(e)
			-- G_FreeEntity() memsets the gentity and leaves classname "freed";
			-- G_InitGentity() restores s.number when the slot is reused
			e.classname = "freed"
			e.s.number = num
			e.inuse = 0
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
		e.health = 0
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
		e.health, e.takedamage = 100, 1   -- ClientSpawn(): alive and damageable

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

	-- Put a client somewhere in the world and aim them. Without this every
	-- client sits at the origin, so any real trace starts inside everybody
	-- else's bounding box.
	function engine.place(num, origin, viewangles)
		local c = engine.client(num)
		assert(c, "client " .. tostring(num) .. " is not connected")
		if origin then c.ps.origin = { origin[1], origin[2], origin[3] } end
		if viewangles then
			c.ps.viewangles = { viewangles[1], viewangles[2], viewangles[3] }
		end
		return c
	end

	function engine.health(num, value)
		local c = engine.client(num)
		assert(c, "client " .. tostring(num) .. " is not connected")
		c.ps.stats[0] = value
		-- G_Damage() keeps ent->health and ps.stats[STAT_HEALTH] in step, and
		-- Lua reads the former for "health"
		engine.ents[num].health = value
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

---------------------------------------------------------------------------
-- G_SpawnGEntityFromSpawnVars(): the key/value string G_CreateEntity() is
-- handed, e.g.  'classname target_position origin "12.0 0.0 40.0"'
---------------------------------------------------------------------------
function stub.parse_spawnvars(text)
	local src = tostring(text or "")
	local n, i = #src, 1
	local function token()
		while i <= n and src:sub(i, i):match("%s") do i = i + 1 end
		if i > n then return nil end
		if src:sub(i, i) == '\"' then
			i = i + 1
			local from = i
			while i <= n and src:sub(i, i) ~= '\"' do i = i + 1 end
			local v = src:sub(from, i - 1)
			i = i + 1
			return v
		end
		local from = i
		while i <= n and not src:sub(i, i):match("%s") and src:sub(i, i) ~= '\"' do
			i = i + 1
		end
		return src:sub(from, i - 1)
	end

	local vars = {}
	while true do
		local key = token()
		if not key then break end
		vars[key] = token() or ""
	end
	return vars
end

local function to_vec3(text)
	local x, y, z = tostring(text or ""):match("^%s*(-?[%d%.eE+]+)%s+(-?[%d%.eE+]+)%s+(-?[%d%.eE+]+)")
	if not x then return nil end
	return { tonumber(x), tonumber(y), tonumber(z) }
end

-- The spawn fields a spawn function can read (the field[] table in g_spawn.c).
-- "target_position" only ever calls G_SetOrigin(), so this covers everything
-- the modules under test can create.
function stub.apply_spawnvars(e, vars)
	e.spawnvars = vars
	e.classname = vars.classname or e.classname
	if vars.origin then
		local v = to_vec3(vars.origin)
		if v then e.origin = v end
	end
	if vars.angle or vars.angles then
		local v = to_vec3(vars.angles or vars.angle)
		if v then e.angles = v end
	elseif vars.angle and tonumber(vars.angle) then
		e.angles = { 0, tonumber(vars.angle), 0 }
	end
	if vars.model then e.model = vars.model end
	if vars.target then e.target = vars.target end
	if vars.targetname then e.targetname = vars.targetname end
	if vars.spawnflags then e.spawnflags = tonumber(vars.spawnflags) or 0 end
	return e
end

-- G_FreeEntity() memsets the gentity and G_InitGentity() puts the engine-side
-- fields back. Client pointers are not touched: the engine keeps gclient_t for
-- a slot until ClientDisconnect() clears it.
function stub.reset_gentity(e)
	e.classname = ""
	e.origin = { 0, 0, 0 }
	e.angles = nil
	e.model = nil
	e.target = nil
	e.targetname = nil
	e.spawnflags = nil
	e.spawnvars = nil
	e.clipmask = 0
	e.s = { number = -1, eType = 0, modelindex = 0, angles = nil, apos = nil, pos = nil }
	e.r = {
		ownerNum = 0, currentOrigin = { 0, 0, 0 },
		mins = nil, maxs = nil, contents = 0, linked = false,
	}
	e.inuse = 0
	return e
end

-- Add a solid box to the level so trap_Trace() has geometry to hit. mins/maxs
-- are absolute coordinates, like a brush's bounds.
function stub.add_wall(engine, mins, maxs, contents)
	engine.world[#engine.world + 1] = {
		mins = { mins[1], mins[2], mins[3] },
		maxs = { maxs[1], maxs[2], maxs[3] },
		contents = contents or CONTENTS_SOLID,
	}
	return engine.world[#engine.world]
end

-- The spawn classes G_CallSpawn() (g_spawn.c) knows, i.e. the ones a Lua module
-- may create an entity with. Anything else is freed again by
-- G_SpawnGEntityFromSpawnVars() while G_CreateEntity() still hands back the
-- (now stale) entity number - the trap the original throwable knife fell into.
-- "target_position" is the inert one: its spawn function is a single
-- G_SetOrigin() (g_target.c), so the entity comes back with no think function,
-- no model and no contents.
stub.SPAWN_CLASSES = {
	target_position = true,
	target_location = true,
	target_delay = true,
	target_print = true,
	target_speaker = true,
	trigger_multiple = true,
	trigger_always = true,
	func_explosive = true,
	misc_model = true,
}

-- A stand-in for commands/commands.lua's onClientCommand(), which main.lua
-- registers *before* game.gameplay's (main.lua requires commands.commands at
-- line 138 and game.gameplay at line 143). The real module cannot be loaded in
-- a unit test: it needs wolfa_requireLib("toml") from ET:Legacy's lua lib path,
-- the admin settings files and a sqlite database. What has to be faithful here
-- is the return value, because that is the bug: commands.onClientCommand()
-- ends in an unconditional `return 0` (commands/commands.lua:349) for every
-- command it does not own - "kill" included - and an events.trigger() that
-- keeps the first non-nil return hands that 0 to the engine, swallowing a later
-- handler's `return 1`.
--
-- engine.client_commands[name] = { func = f, chat = true, flag = "" } models
-- clientcmds[]; engine.admin_commands[name] models admincmds[].
function stub.wolfadmin_client_command(engine)
	engine.client_commands = engine.client_commands or {}
	engine.admin_commands = engine.admin_commands or {}

	local function argv(i) return engine.argv and engine.argv[i + 1] or "" end
	local function argc() return engine.argv and #engine.argv or 0 end

	return function(clientId, command)
		local wolfCmd = string.lower(tostring(command or ""))

		-- mod-specific or custom commands: "!kill" style console commands that
		-- WolfAdmin itself owns (commands.lua:242)
		local c = engine.client_commands[wolfCmd]
		if c and c.func then
			local args = {}
			for i = 1, argc() - 1 do args[#args + 1] = argv(i) end
			local isFinished = c.func(clientId, wolfCmd, table.unpack(args))
			if isFinished ~= nil then return isFinished and 1 or 0 end
		end

		-- chat commands: say "/cmd ..." (commands.lua:259) and say "!cmd ..."
		if wolfCmd == "say" or wolfCmd == "say_team" or wolfCmd == "say_buddy" then
			local first = argv(1)
			local lead = first:sub(1, 1)
			if lead == "/" then
				local name = first:sub(2):match("^%S+")
				if name then
					local cc = engine.client_commands[string.lower(name)]
					if cc and cc.func and cc.chat then
						return cc.func(clientId, string.lower(name)) and 1 or 0
					end
				end
			elseif lead == "!" then
				local name = first:sub(2):match("^%S+")
				if name and engine.admin_commands[string.lower(name)] then
					return 0        -- said in chat: the engine may print it
				end
			end
		elseif wolfCmd:sub(1, 1) == "!" then
			-- silent console admin command (commands.lua:325): swallowed only
			-- when WolfAdmin actually ran it
			local name = wolfCmd:sub(2)
			if engine.admin_commands[name] then return 1 end
		end

		return 0                    -- commands.lua:349 - and that is the point
	end
end

stub.MAX_CLIENTS = MAX_CLIENTS
stub.MAX_GENTITIES = MAX_GENTITIES
stub.CLIENT_FIELDS = CLIENT_FIELDS
stub.GENTITY_FIELDS = GENTITY_FIELDS
stub.CLASSES = CLASSES
stub.CONTENTS_SOLID = CONTENTS_SOLID
stub.CONTENTS_MISSILECLIP = CONTENTS_MISSILECLIP
stub.CONTENTS_BODY = CONTENTS_BODY
stub.CONTENTS_CORPSE = CONTENTS_CORPSE
stub.MASK_SHOT = MASK_SHOT
stub.MASK_MISSILESHOT = MASK_MISSILESHOT
stub.PLAYER_MINS = PLAYER_MINS
stub.PLAYER_MAXS = PLAYER_MAXS
stub.DEFAULT_VIEWHEIGHT = DEFAULT_VIEWHEIGHT
stub.ENTITYNUM_NONE = ENTITYNUM_NONE

return stub
