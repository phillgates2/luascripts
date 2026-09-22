
-- WolfAdmin module for Wolfenstein: Enemy Territory servers.
-- Extra gameplay tweaks bundled into one module.
--
-- Features (see the CONFIG blocks below to toggle/tune each):
--   * adrenaline_all_classes  - adrenaline shot for every class except medics;
--                               slot 7 toggles landmine <-> adrenaline
--   * covert_disguise_break   - disguise breaks when switching weapons in
--                               front of an enemy
--   * kick_projectiles        - kick grenades / canisters / smoke bombs with USE
--   * no_combat_selfkill      - /kill refused while in combat or spotted
--   * poison_needle           - syringe poisons enemies; all classes carry it;
--                               slot 5 toggles needle <-> pliers / smoke
--   * soldier_smg_slot2       - soldiers can pull their SMG from slot 2
--   * throwable_knife         - throw knives as pick-up-able projectiles
--
-- Install: loaded automatically when WolfAdmin loads via main.lua (no extra
-- lua_modules entries required).
-- =========================================================================

local events = wolfa_requireModule("util.events")

local gameplay = {}

-- ============================== CONFIG ====================================
-- Each section can be toggled off individually if you don't want that
-- feature; defaults match the upstream standalone scripts.

-- --- adrenaline for all classes (slot-7 toggle built in) -----------------
local ADRENALINE_ENABLE     = true
local ADRENALINE_AMMO       = 0
local ADRENALINE_AMMOCLIP   = 1
local SLOT7_NOTIFY          = false     -- centre print the switched-to weapon
local SLOT7_TOGGLE_COMMAND  = "togglemine"

-- --- covert ops disguise breaks on weapon switch ------------------------
local DISGUISE_BREAK_ENABLE = true
local BREAK_RANGE           = 384
local BREAK_CONE_HALF_ANGLE = 75
local BREAK_REQUIRE_LOS     = true
local BREAK_ANNOUNCE        = true
local BREAK_ANNOUNCE_TEXT   = "Your cover has been blown!"

-- --- kick grenades / canisters ------------------------------------------
local KICK_ENABLE           = true
local KICK_RANGE            = 64
local KICK_CONE_HALF_ANGLE  = 60
local KICK_POWER            = 420
local KICK_UP               = 240
local KICK_COOLDOWN_MS      = 1200
local KICK_POP              = 4
local KICK_SOUND            = true
local KICK_SOUND_FILE       = "sound/footsteps/footstep1.wav"
local KICK_STATIONARY_SPEED = 120
local KICK_AIM_SLOP         = 40

-- --- no /kill in a fire fight -------------------------------------------
local NOKILL_ENABLE         = true
local COMBAT_WINDOW_MS      = 5000
local SIGHT_RANGE           = 2000
local SIGHT_CONE_ANGLE      = 90
local NOKILL_BLOCK_TEAM     = false
local STUCK_GRACE_MS        = 8000
local NOKILL_LOW_HEALTH     = false
local NOKILL_LOW_HEALTH_VAL = 20

-- --- poison needle -------------------------------------------------------
local POISON_ENABLE         = true
local POISON_DURATION_MS    = 10000
local POISON_TICK_MS        = 1000
local POISON_TICK_DAMAGE    = 10
local SYRINGE_RANGE         = 48
local POISON_CURE_MEDPACK   = true
local POISON_CURE_ADRENALINE= true
local POISON_NOTIFY_VICTIM  = true
local POISON_NOTIFY_ATTACKER= true
local POISON_ALL_CLASSES    = true
local SYRINGE_AMMO          = 0
local SYRINGE_AMMOCLIP      = 8
local SLOT5_TOGGLE          = true
local SLOT5_NOTIFY          = false
local SLOT5_TOGGLE_COMMAND  = "poisonneedle"

-- --- soldier SMG on slot 2 ----------------------------------------------
local SMG_SLOT2_ENABLE      = true
local GRANT_TEAM_SMG        = false
local GRANT_SMG_AMMO        = 90
local GRANT_SMG_CLIP        = 30

-- --- throwable knife -----------------------------------------------------
local KNIFE_ENABLE          = true
local KNIFE_CLIP_MAX        = 5     -- knives per clip (spawn + pickup cap)
local THROW_SPEED           = 1400
local THROW_UP              = 40
local THROW_DAMAGE          = 45
local THROW_DAMAGE_HEAD     = 100
local THROW_COOLDOWN_MS     = 800
local KNIFE_LIFETIME_MS     = 30000
local KNIFE_PICKUP_RANGE    = 48
-- A hit this far above the victim's origin counts as a headshot. It matches the
-- engine's own head box: G_BuildHead() (g_combat.c) puts it at origin +
-- ps.viewheight with mins z -2, so the box starts at viewheight - 2 = 38 for a
-- standing player (DEFAULT_VIEWHEIGHT 40, bg_public.h). 46 left only the top
-- two units of the 72-unit player box as a head, so headshots were effectively
-- unreachable. When ps.viewheight can be read the victim's real value is used
-- instead, which keeps it right for a crouching player (CROUCH_VIEWHEIGHT 16).
local KNIFE_HEAD_HEIGHT     = 38
local KNIFE_MODEL           = true  -- draw it with the knife's own world model
local KNIFE_SPIN            = 720   -- degrees/second of tumble (0 = no spin)
local KNIFE_MAX_LIVE        = 12    -- cap on knives in the world (entity slots)
local KNIFE_SPAWN_CLASS     = "target_position"

-- misc
DEBUG                 = false
-- ==========================================================================

-- -------------------------- constants ------------------------------------
local PC_SOLDIER, PC_MEDIC = 0, 1

local TEAM_FREE     = (et and et.TEAM_FREE)     or 0
local TEAM_AXIS     = (et and et.TEAM_AXIS)     or 1
local TEAM_ALLIES   = (et and et.TEAM_ALLIES)   or 2
local TEAM_SPECTATOR= (et and et.TEAM_SPECTATOR)or 3

local MAX_CLIENTS   = (et and et.MAX_CLIENTS)   or 64
local MAX_ENTITIES  = (et and et.MAX_GENTITIES) or 1024
local STAT_HEALTH   = (et and et.STAT_HEALTH)  or 0

local MASK_SOLID    = (et and et.MASK_SOLID)    or 1
local MASK_SHOT     = (et and et.MASK_SHOT)     or MASK_SOLID

-- weapons
local WP_KNIFE        = (et and et.WP_KNIFE)        or 1
local WP_LUGER        = (et and et.WP_LUGER)        or 2
local WP_MP40         = (et and et.WP_MP40)         or 3
local WP_GRENADE_LAUNCHER = (et and et.WP_GRENADE_LAUNCHER) or 4
local WP_LANDMINE     = (et and et.WP_LANDMINE)     or 26
local WP_SMOKE_MARKER = (et and et.WP_SMOKE_MARKER) or 22
local WP_SMOKE_BOMB   = (et and et.WP_SMOKE_BOMB)   or 29
local WP_GRENADE_PINEAPPLE = (et and et.WP_GRENADE_PINEAPPLE) or 9
local WP_COLT         = (et and et.WP_COLT)         or 7
local WP_THOMPSON     = (et and et.WP_THOMPSON)     or 8
local WP_STEN         = (et and et.WP_STEN)         or 10
local WP_SILENCER     = (et and et.WP_SILENCER)     or 14
local WP_MEDIC_SYRINGE= (et and et.WP_MEDIC_SYRINGE)or 11
local WP_PLIERS       = (et and et.WP_PLIERS)       or 21
local WP_MEDIC_ADRENALINE = (et and et.WP_MEDIC_ADRENALINE) or 44
local WP_AKIMBO_COLT  = (et and et.WP_AKIMBO_COLT)  or 35
local WP_AKIMBO_LUGER = (et and et.WP_AKIMBO_LUGER) or 36
local WP_SILENCED_COLT= (et and et.WP_SILENCED_COLT)or 39
local WP_AKIMBO_SILENCEDCOLT  = (et and et.WP_AKIMBO_SILENCEDCOLT)  or 45
local WP_AKIMBO_SILENCEDLUGER = (et and et.WP_AKIMBO_SILENCEDLUGER) or 46
local WP_KNIFE_KABAR  = (et and et.WP_KNIFE_KABAR)  or 48
local WP_MP34         = (et and et.WP_MP34)         or 54

local MOD_SYRINGE     = (et and et.MOD_SYRINGE)     or 24
local MOD_KNIFE       = (et and et.MOD_KNIFE)       or 5

local PW_OPS_DISGUISED= (et and et.PW_OPS_DISGUISED)or 7
local DAMAGE_NO_KNOCKBACK = 8

-- entityType_t / trType_t (q_shared.h). Neither enum is exposed to Lua, so the
-- values are kept here; they have not moved since ET 1.0. The rest of them
-- (ET_GENERAL, TR_LINEAR) are only used by the throwable knife and hang off its
-- table, because this chunk is at Lua's 200-local limit.
local ET_MISSILE    = 3
local TR_STATIONARY = 0
local TR_GRAVITY    = 6

local BANK7 = { WP_LANDMINE, WP_MEDIC_ADRENALINE }
local BANK5 = { WP_MEDIC_SYRINGE, WP_PLIERS, WP_SMOKE_MARKER, WP_SMOKE_BOMB }

local SMG_WEAPONS = {
	[WP_THOMPSON] = true, [WP_MP40] = true, [WP_STEN] = true, [WP_MP34] = true,
}
local TEAM_SMG = { [TEAM_AXIS] = WP_MP40, [TEAM_ALLIES] = WP_THOMPSON }
local PISTOLS = {
	WP_AKIMBO_SILENCEDCOLT, WP_AKIMBO_SILENCEDLUGER,
	WP_AKIMBO_COLT, WP_AKIMBO_LUGER,
	WP_SILENCED_COLT, WP_SILENCER,
	WP_COLT, WP_LUGER,
}
local PISTOL_POOL = {
	[WP_AKIMBO_COLT] = WP_COLT, [WP_AKIMBO_SILENCEDCOLT] = WP_COLT,
	[WP_SILENCED_COLT] = WP_COLT,
	[WP_AKIMBO_LUGER] = WP_LUGER, [WP_AKIMBO_SILENCEDLUGER] = WP_LUGER,
	[WP_SILENCER] = WP_LUGER,
}
-- ps.ammo / ps.ammoclip are indexed with the weapon table's ammoIndex /
-- clipIndex (bg_misc.c), which is not always the weapon number: the side
-- arms share the pool of their base weapon and the adrenaline shot shares
-- the medic syringe's.
local AMMO_POOL = {
	[WP_MEDIC_ADRENALINE] = WP_MEDIC_SYRINGE,
}
for w, pool in pairs(PISTOL_POOL) do AMMO_POOL[w] = pool end

local KNIVES = { [WP_KNIFE] = true, [WP_KNIFE_KABAR] = true }
local KICKABLE_WEAPONS = {
	[WP_GRENADE_LAUNCHER] = true,
	[WP_GRENADE_PINEAPPLE] = true,
	[WP_SMOKE_MARKER] = true,
	[WP_SMOKE_BOMB] = true,
}

DEG2RAD = math.pi / 180

MODULE_TAG = "[wolfadmin:gameplay]"

-- ============================== state ====================================
local client_slots
local no_client = {}          -- [num] = true: slot has no client data right now
local reported_errors = {}

-- per-feature state
local last_kick = {}           -- kick cooldowns   [ent] = levelTime
local kick_sound_index = 0
local last_kick_debug = 0

local last_weapon = {}         -- disguise-break tracking [cnum] = prev ps.weapon

local last_combat = {}         -- no-combat-selfkill [cnum] = levelTime
local still_since  = {}
local last_origin  = {}

local poisoned = {}            -- poison_needle [cnum] = { attacker, expires, next_tick }

local knives = {}              -- throwable_knife [ent] = flight/pickup record
local next_throw = {}

local enabled = true

-- ============================== the clock ================================
-- Every timestamp this module writes or compares comes from ONE clock:
-- level.time, which et_RunFrame() hands to onGameFrame(). The callbacks that
-- get no time (client command, damage, weapon fire) read the value of the last
-- frame through now_ms(), so nothing is ever compared with a reading taken
-- from a different clock.
--
-- The two readings this module could use are equal only by coincidence:
-- et.trap_Milliseconds() is Sys_Milliseconds() (sv_game.c:447), wall clock since
-- the server process started, while level.time is sv.time, which the server
-- carries across map changes and resets to 0 only when sv_serverTimeReset is 1
-- (sv_init.c:812; the default is 0). On a server that sets it - and after the
-- 23-day wraparound restart, which resets sv.time as well - the two are minutes
-- to hours apart, and every comparison that mixes them fails the same silent
-- way:
--
--   * still_since[] written with level.time but compared against
--     trap_Milliseconds() makes is_stuck() answer "stuck here for ages" for
--     every player who stands still, and is_stuck() answering true is what lets
--     a /kill through before the combat window is ever looked at;
--   * poison's expires/next_tick written with trap_Milliseconds() and compared
--     against level.time in on_game_frame() are never reached, so the poison
--     never ticks and never wears off.
--
-- One clock, read in one place, removes the coincidence.
local frame_time = 0

-- ============================== helpers ==================================

local function is_gameplay_enabled()
	if type(et) == "table" and type(et.trap_Cvar_Get) == "function" then
		local v = et.trap_Cvar_Get("g_gameplay")
		if v ~= "" then
			local n = tonumber(v)
			if n ~= nil then return n ~= 0 end
		end
	end
	return true
end

local function log(msg)
	if type(et) == "table" and type(et.G_Print) == "function" then
		et.G_Print(MODULE_TAG .. " " .. msg .. "\n")
	end
end

local function refresh_client_slots()
	local n
	if type(et.trap_Cvar_Get) == "function" then
		n = tonumber(et.trap_Cvar_Get("sv_maxclients") or "")
	end
	if not n or n <= 0 or n > MAX_CLIENTS then
		n = MAX_CLIENTS
	end
	client_slots = n
	return n
end

local function get_client_slots()
	return client_slots or refresh_client_slots()
end

-- Every client field this module reads. et.gentity_get() resolves client
-- fields through the engine's own field table (g_lua.c, _et_gclient_addfield)
-- and only while the slot owns a gclient_t, so "the engine does not have this
-- field" and "this slot has no client" raise the very same error
-- (tried to get invalid gentity field "<name>"). Probing the list once per
-- map on slot 0 - which always owns a gclient_t, g_main.c assigns
-- g_entities[i].client for i < level.maxclients - tells the two apart: a field
-- the engine does not have is dropped for the whole map and can never make a
-- real player look like an empty slot.
--
-- This is not hypothetical: ET:Legacy's field table has no ps.weapons (only
-- ps.weapon/ps.weaponstate), so the old code reported one player after another
-- and then threw that player's client data away, which silently disabled every
-- feature of this module for them.
--
-- The bookkeeping sits in one table (rather than one local per piece) because
-- Lua allows 200 locals per function and this module is close to that limit.
local fields = {
	names = {
		"pers.connected", "pers.netname",
		"sess.sessionTeam", "sess.playerType",
		"sess.playerWeapon", "sess.playerWeapon2",
		"sess.latchPlayerWeapon", "sess.latchPlayerWeapon2",
		"ps.stats", "ps.origin", "ps.viewangles", "ps.viewheight", "ps.weapon",
		"ps.weapons", "ps.ammo", "ps.ammoclip", "ps.powerups",
		-- read by the kick feature; ET:Legacy only added ps.velocity (and
		-- ps.pm_type, ps.leanf) in 2.77, so it has to be probed like the rest:
		-- an unprobed field that the engine does not have makes client_get()
		-- mark the whole slot as "no client data" on the first frame
		"ps.velocity",
	},
	-- the class load-out; a soldier's SMG sits in playerWeapon2 when the light
	-- weapons skill is bought (classSecondaryWeapons in bg_classes.c)
	loadout = {
		"sess.playerWeapon", "sess.playerWeapon2",
		"sess.latchPlayerWeapon", "sess.latchPlayerWeapon2",
	},
	ok = {},   -- [name] = true when this engine exposes the field
}

function fields.probe()
	local missing = {}
	fields.ok = {}
	for _, name in ipairs(fields.names) do
		local ok = type(et.gentity_get) == "function"
			and pcall(et.gentity_get, 0, name, 0)
		fields.ok[name] = ok and true or false
		if not ok then missing[#missing + 1] = name end
	end
	if #missing > 0 then
		log("client fields not exposed by this engine: " .. table.concat(missing, ", "))
	end
	if fields.ok["ps.weapons"] == false then
		log("ps.weapons is not exposed by this engine - weapon ownership is read"
			.. " from the load-out and the ammo pools instead")
	end
end

-- A slot without client data is skipped until an event clears it again
-- (client connect/begin/spawn/disconnect, a client command or damage). The
-- report is per slot and map, never per frame.
function fields.mark_empty(num, err)
	if no_client[num] then return end
	no_client[num] = true
	local key = "no_client:" .. num
	if not reported_errors[key] then
		reported_errors[key] = true
		log("client slot " .. num .. " has no client data ("
			.. tostring(err) .. ") - skipped while it is empty")
	end
end

-- protected client-field read that never aborts the callback
local function client_get(num, field, index)
	if no_client[num] then return nil end
	if num < 0 or num >= get_client_slots() then return nil end
	if fields.ok[field] == false then return nil end
	local ok, val = pcall(et.gentity_get, num, field, index)
	if not ok then
		fields.mark_empty(num, val)
		return nil
	end
	return val
end

local function has_client(num)
	if type(num) ~= "number" or num < 0 or num >= get_client_slots()
		or no_client[num] then
		return false
	end
	local ok, v = pcall(et.gentity_get, num, "inuse")
	if not ok then
		if tostring(v):find("invalid", 1, true) then fields.mark_empty(num, v) end
		return false
	end
	return v == 1
end

local function clear_no_client(num)
	no_client[num] = nil
end

local function team_of(num)
	if not has_client(num) then return nil end
	local t = client_get(num, "sess.sessionTeam")
	if t == TEAM_AXIS or t == TEAM_ALLIES then return t end
	return nil
end

local function is_on_team(num) return team_of(num) ~= nil end

local function is_alive(num)
	local h = client_get(num, "ps.stats", STAT_HEALTH)
	return type(h) == "number" and h > 0
end

local function class_of(num)
	return client_get(num, "sess.playerType")
end

-- ps.weapons is two 32-bit words; weapon w is bit (w%32) of word floor(w/32).
-- When the engine exposes that bitmask we use it and nothing else. ET:Legacy's
-- field table does not (see the probe above), so the fallback below stands in
-- for it:
--   * ps.weapon                          - the weapon in hand right now
--   * the class load-out fields          - what the player selected in the
--     limbo menu; SetWolfSpawnWeapons() grants exactly that load-out
--   * a non-empty ammo pool              - SetWolfSpawnWeapons() adds every
--     owned weapon through AddWeaponToPlayer(), which fills
--     ps.ammo[ammoIndex] / ps.ammoclip[clipIndex] (g_client.c), and
--     bg_classes.c even gives the weapons without ammo of their own (knife,
--     pliers, mines, smoke) a starting clip of 1
-- A weapon that is owned but completely out of ammo *and* not part of the
-- load-out is the only false negative - and that weapon could not be used by
-- the toggles below anyway.
local function has_weapon(num, w)
	local mask = client_get(num, "ps.weapons", math.floor(w / 32))
	if type(mask) == "number" then
		return math.floor(mask / (2 ^ (w % 32))) % 2 == 1
	end

	if client_get(num, "ps.weapon") == w then return true end
	for _, field in ipairs(fields.loadout) do
		if client_get(num, field) == w then return true end
	end

	local pool = AMMO_POOL[w] or w
	local clip = client_get(num, "ps.ammoclip", pool)
	if type(clip) == "number" and clip > 0 then return true end
	local ammo = client_get(num, "ps.ammo", pool)
	return type(ammo) == "number" and ammo > 0
end

-- view forward vector from {pitch, yaw, roll} (q_math.c angles_vectors)
-- positive pitch looks DOWN -> z component is -sin(pitch)
local function view_forward_pitch_yaw(angles)
	if not angles then return nil end
	local pitch = angles[1] * DEG2RAD
	local yaw   = angles[2] * DEG2RAD
	local cp    = math.cos(pitch)
	return { cp * math.cos(yaw), cp * math.sin(yaw), -math.sin(pitch) }
end

-- covert_disguise_break in upstream uses {yaw, pitch} ordering in indices 1/2
-- (NOTE: its comment says {yaw, pitch, roll} and uses angles[1]=yaw, angles[2]=pitch
-- with sp = sin(pitch), cp = cos(pitch), fwd = (cos(yaw)*cp, sin(yaw)*cp, sin(pitch))
-- which equals (cos(pitch)*cos(yaw), cos(pitch)*sin(yaw), sin(pitch)) -- a
-- positive-pitch-LOOKS-UP convention. Keep the upstream math unchanged so the
-- cone test behaves the same.)
local function view_forward_yaw_pitch(angles)
	if not angles then return nil end
	local yaw   = angles[1] * DEG2RAD
	local pitch = angles[2] * DEG2RAD
	local cp    = math.cos(pitch)
	return { math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch) }
end

local function cp(num, text)
	if type(et.trap_SendServerCommand) == "function" then
		et.trap_SendServerCommand(num, 'cp "' .. text .. '"')
	end
end

local function err_once(label, err)
	local key = label .. ":" .. tostring(err)
	if reported_errors[key] then return end
	reported_errors[key] = true
	log("ERROR (" .. label .. "): " .. tostring(err) .. " (reported once per map)")
end

local function now_ms()
	return frame_time
end

local function eyes_of(num, chest_offset)
	local o = client_get(num, "ps.origin")
	if not o then return nil end
	local vh = client_get(num, "ps.viewheight") or 32
	return { o[1], o[2], o[3] + vh + (chest_offset or 0) }
end

local function name_of(num)
	local n = client_get(num, "pers.netname")
	if type(n) == "string" and #n > 0 then return n end
	return "client " .. tostring(num)
end

local function dist2(a, b)
	local dx, dy, dz = a[1] - b[1], a[2] - b[2], a[3] - b[3]
	return dx * dx + dy * dy + dz * dz
end

-- ========================= ADRENALINE + SLOT 7 ===========================

local function adrenaline_grant(clientNum)
	if type(et.AddWeaponToPlayer) ~= "function" then return end
	local ammo, clip = ADRENALINE_AMMO, ADRENALINE_AMMOCLIP
	if has_weapon(clientNum, WP_MEDIC_SYRINGE) then
		ammo  = client_get(clientNum, "ps.ammo",  WP_MEDIC_SYRINGE) or 0
		clip  = (client_get(clientNum, "ps.ammoclip", WP_MEDIC_SYRINGE) or 0)
			+ ADRENALINE_AMMOCLIP
	end
	pcall(et.AddWeaponToPlayer, clientNum, WP_MEDIC_ADRENALINE, ammo, clip, 0)
end

local function adrenaline_strip(clientNum)
	pcall(et.RemoveWeaponFromPlayer, clientNum, WP_MEDIC_ADRENALINE)
end

-- slot 7 helpers
local function bank7_has_ammo(num, w)
	local pool = AMMO_POOL[w] or w
	local clip = client_get(num, "ps.ammoclip", pool)
	local ammo = client_get(num, "ps.ammo", pool)
	if clip == nil and ammo == nil then return true end
	return (clip or 0) > 0 or (ammo or 0) > 0
end

local function pick_bank7(num)
	local cur = client_get(num, "ps.weapon")
	local owned, usable = {}, {}
	for _, w in ipairs(BANK7) do
		if has_weapon(num, w) then
			owned[#owned+1] = w
			if bank7_has_ammo(num, w) then usable[#usable+1] = w end
		end
	end
	local list = #usable > 0 and usable or owned
	if #list == 0 then return nil end
	if #list == 1 then return list[1] end
	for i, w in ipairs(list) do
		if w == cur then return list[(i % #list) + 1] end
	end
	return list[1]
end

local function bank7_select(num, w)
	local pool = AMMO_POOL[w] or w
	local ammo = client_get(num, "ps.ammo", pool) or 0
	local clip = client_get(num, "ps.ammoclip", pool) or 0
	local ok, err = pcall(et.AddWeaponToPlayer, num, w, ammo, clip, 1)
	if ok then
		if SLOT7_NOTIFY then
			cp(num, "^7" .. (w == WP_MEDIC_ADRENALINE and "adrenaline" or "landmine"))
		end
		return true
	end
	err_once("bank7_select", err)
	return false
end

local function is_slot7_command(command)
	if type(command) ~= "string" then return false end
	local c = command:lower()
	if c == SLOT7_TOGGLE_COMMAND or c == "slot7" or c == "togglemine" then return true end
	if c == "weaponbank" or c == "weaponslot" or c:find("weaponbank") or c:find("weaponslot") then
		if type(et.trap_Argv) == "function" then
			local a1 = et.trap_Argv(1) or ""
			if tonumber(a1) == 7 then return true end
		end
		-- handle \"weaponbank 7\" passed as single string
		if c:match("weaponbank%s+7") or c:match("weaponslot%s+7") or c == "weaponbank 7" or c == "weaponslot 7" then
			return true
		end
	end
	return false
end

-- ===================== COVERT DISGUISE BREAK =============================

-- alt-mode pairs of the same base weapon (scope/silencer/set)
local ALT_MODE = {
	[2]=14,[14]=2,[7]=39,[39]=7,[35]=45,[45]=35,[36]=46,[46]=36,
	[23]=37,[37]=23,[24]=38,[38]=24,[25]=40,[40]=25,[31]=41,[41]=31,
	[32]=42,[42]=32,[30]=47,[47]=30,[34]=43,[43]=34,[51]=52,[52]=51,
	[49]=50,[50]=49,[27]=28,[28]=27,
}
local function same_base_weapon(a, b)
	return a == b or (ALT_MODE[a] ~= nil and ALT_MODE[a] == b)
end

local function is_disguised(num)
	return client_get(num, "ps.powerups", PW_OPS_DISGUISED) == 1
end

local function disguise_enemy_in_front(cnum, eye, fwd)
	local myTeam = team_of(cnum)
	local RANGE_SQ = BREAK_RANGE * BREAK_RANGE
	local CONE_COS = math.cos(BREAK_CONE_HALF_ANGLE * DEG2RAD)
	for j = 0, get_client_slots() - 1 do
		if j ~= cnum and has_client(j) then
			local t = team_of(j)
			if t and t ~= TEAM_FREE and t ~= TEAM_SPECTATOR and t ~= myTeam then
				local h = client_get(j, "ps.stats", STAT_HEALTH)
				if h and h > 0 then
					local po = client_get(j, "ps.origin")
					if po then
						local cx, cy, cz = po[1], po[2], po[3] + 24
						local dx, dy, dz = cx - eye[1], cy - eye[2], cz - eye[3]
						local d2 = dx*dx + dy*dy + dz*dz
						if d2 <= RANGE_SQ and d2 > 0 then
							local inv = 1 / math.sqrt(d2)
							local dot = fwd[1]*dx*inv + fwd[2]*dy*inv + fwd[3]*dz*inv
							if dot >= CONE_COS then
								if not BREAK_REQUIRE_LOS then return true end
								local ok, tr = pcall(et.trap_Trace,
									eye, {0,0,0}, {0,0,0},
									{cx,cy,cz}, cnum, MASK_SOLID)
								if not ok or type(tr) ~= "table" then return true end
								if (tr.fraction or 0) >= 1.0 then return true end
							end
						end
					end
				end
			end
		end
	end
	return false
end

local function break_disguise(num)
	pcall(et.gentity_set, num, "ps.powerups", PW_OPS_DISGUISED, 0)
	if BREAK_ANNOUNCE then cp(num, BREAK_ANNOUNCE_TEXT) end
	if DEBUG then log("client " .. num .. " lost the disguise") end
end

-- ============================ KICK PROJECTILES ===========================

KICK_CONE_COS = math.cos(KICK_CONE_HALF_ANGLE * DEG2RAD)
KICK_RANGE_SQ = KICK_RANGE * KICK_RANGE
KICK_STATIONARY_SQ = KICK_STATIONARY_SPEED * KICK_STATIONARY_SPEED

local function kick_collect_players(players)
	for i = 0, get_client_slots() - 1 do
		if has_client(i) then
			local team = client_get(i, "sess.sessionTeam")
			local h    = client_get(i, "ps.stats", STAT_HEALTH)
			if team and team ~= TEAM_FREE and team ~= TEAM_SPECTATOR
				and h and h > 0 then
				local o    = client_get(i, "ps.origin")
				if o then
					local v    = client_get(i, "ps.viewangles")
					local vh   = client_get(i, "ps.viewheight")
					local vel  = client_get(i, "ps.velocity")
					if v and vel then
						players[#players+1] = {
							num = i, origin = o,
							eye = { o[1], o[2], o[3] + (vh or 32) },
							fwd = view_forward_pitch_yaw(v),
							speed2 = vel[1]*vel[1] + vel[2]*vel[2],
						}
					end
				end
			end
		end
	end
end

local function kick_looking_at(pl, pos)
	local ex, ey, ez = pos[1]-pl.eye[1], pos[2]-pl.eye[2], pos[3]-pl.eye[3]
	local el = math.sqrt(ex*ex + ey*ey + ez*ez)
	if el < 1 then return true end
	local dot = pl.fwd[1]*ex/el + pl.fwd[2]*ey/el + pl.fwd[3]*ez/el
	if dot >= KICK_CONE_COS then return true end
	local t = pl.fwd[1]*ex + pl.fwd[2]*ey + pl.fwd[3]*ez
	if t < 0 then return false end
	local perp2 = el*el - t*t
	if perp2 < 0 then perp2 = 0 end
	return perp2 <= KICK_AIM_SLOP * KICK_AIM_SLOP
end

local function do_kick(p, pos, pl, levelTime)
	local fx, fy, fz = pl.origin[1], pl.origin[2], pl.origin[3] + 8
	local dx, dy, dz = pos[1]-fx, pos[2]-fy, pos[3]-fz
	local len = math.sqrt(dx*dx + dy*dy + dz*dz)
	if len < 1 then len = 1 end
	local vx, vy, vz = dx/len*KICK_POWER, dy/len*KICK_POWER, dz/len*KICK_POWER + KICK_UP
	local nb = { pos[1], pos[2], pos[3] + KICK_POP }
	local ok, tr = pcall(et.gentity_get, p, "s.pos")
	if not ok or not tr then return end
	tr.trType = TR_GRAVITY; tr.trTime = levelTime
	tr.trBase = nb; tr.trDelta = {vx, vy, vz}
	pcall(et.gentity_set, p, "s.pos", tr)
	pcall(et.gentity_set, p, "r.currentOrigin", nb)
	last_kick[p] = levelTime
	if KICK_SOUND and kick_sound_index > 0 and type(et.G_Sound) == "function" then
		pcall(et.G_Sound, p, kick_sound_index)
	end
end

-- ======================= NO COMBAT SELFKILL ==============================

local NOKILL_CONE_COS = math.cos(SIGHT_CONE_ANGLE * DEG2RAD)
local NOKILL_RANGE_SQ = SIGHT_RANGE * SIGHT_RANGE

local function can_see(watcher, target)
	local weye = eyes_of(watcher)
	local torg = client_get(target, "ps.origin")
	if not weye or not torg then return false end
	local tpos = { torg[1], torg[2], torg[3] + 32 }
	local dx, dy, dz = tpos[1]-weye[1], tpos[2]-weye[2], tpos[3]-weye[3]
	local d2 = dx*dx + dy*dy + dz*dz
	if d2 > NOKILL_RANGE_SQ then return false end
	local len = math.sqrt(d2)
	if len < 1 then return true end
	local view = client_get(watcher, "ps.viewangles")
	if not view then return false end
	local fwd = view_forward_pitch_yaw(view)
	local dot = fwd[1]*dx/len + fwd[2]*dy/len + fwd[3]*dz/len
	if dot < NOKILL_CONE_COS then return false end
	if type(et.trap_Trace) ~= "function" then return true end
	local ok, tr = pcall(et.trap_Trace, weye, nil, nil, tpos, watcher, MASK_SHOT)
	if not ok or type(tr) ~= "table" then return true end
	if (tr.fraction or 1) >= 1 then return true end
	return tr.entityNum == target
end

local function seen_by_enemy(num)
	local myteam = team_of(num)
	if not myteam then return nil end
	for c = 0, get_client_slots() - 1 do
		if c ~= num and has_client(c) then
			local t = team_of(c)
			if t and t ~= myteam and is_alive(c) and can_see(c, num) then
				return c
			end
		end
	end
	return nil
end

local function is_stuck(num, now)
	local s = still_since[num]
	return s ~= nil and (now - s) >= STUCK_GRACE_MS
end

local function is_selfkill_cmd(cmd)
	return cmd == "kill" or cmd == "suicide" or (NOKILL_BLOCK_TEAM and cmd == "team")
end

-- =========================== POISON NEEDLE ===============================

local function syringe_grant(num)
	if not POISON_ALL_CLASSES then return end
	if not is_on_team(num) then return end
	-- Medics carry the needle as a class weapon (bg_classes.c); nobody else
	-- does. "The pool is not empty" is not proof of a needle here because the
	-- adrenaline shot shares that pool (see AMMO_POOL) - and
	-- adrenaline_grant() runs before this on every spawn.
	if class_of(num) == PC_MEDIC then return end
	local ammo, clip = SYRINGE_AMMO, SYRINGE_AMMOCLIP
	if has_weapon(num, WP_MEDIC_ADRENALINE) then
		ammo = client_get(num, "ps.ammo", WP_MEDIC_SYRINGE) or 0
		clip = (client_get(num, "ps.ammoclip", WP_MEDIC_SYRINGE) or 0) + SYRINGE_AMMOCLIP
	end
	-- CG_WeaponHasAmmo() does not exempt the syringe, so a needle granted with
	-- an empty pool is owned but unselectable: the client's slot-5 key skips
	-- straight past it and the player never sees the needle. Guarantee at
	-- least one charge so the weapon is reachable.
	if (ammo or 0) <= 0 and (clip or 0) <= 0 then clip = 1 end
	if type(et.AddWeaponToPlayer) == "function" then
		et.AddWeaponToPlayer(num, WP_MEDIC_SYRINGE, ammo, clip, 0)
	end
end

-- Mirror of CG_WeaponHasAmmo() (cg_weapons.c), which is what actually decides
-- whether the client's slot-5 key will stop on a weapon:
--
--     if ((GetWeaponTableData(weapon)->type & WEAPON_TYPE_MELEE) || weapon == WP_PLIERS)
--         return qtrue;
--     if (!ps->ammo[ammoIndex] && !ps->ammoclip[clipIndex])
--         return qfalse;
--
-- The pliers are exempt; the syringe is NOT (it is WEAPON_TYPE_SYRINGUE, not
-- MELEE), so a needle handed out with an empty pool is silently skipped by
-- every bank-5 cycle - the player presses 5 and only ever sees the pliers.
local BANK5_NO_AMMO_CHECK = { [WP_PLIERS] = true }

local function bank5_has_ammo(num, w)
	if BANK5_NO_AMMO_CHECK[w] then return true end
	local pool = AMMO_POOL[w] or w
	local clip = client_get(num, "ps.ammoclip", pool)
	local ammo = client_get(num, "ps.ammo", pool)
	-- engine that exposes neither pool: assume usable rather than hide it
	if clip == nil and ammo == nil then return true end
	return (clip or 0) > 0 or (ammo or 0) > 0
end

local function pick_bank5(num)
	local cur = client_get(num, "ps.weapon")
	local owned, usable = {}, {}
	for _, w in ipairs(BANK5) do
		if has_weapon(num, w) then
			owned[#owned+1] = w
			if bank5_has_ammo(num, w) then usable[#usable+1] = w end
		end
	end
	local list = #usable > 0 and usable or owned
	if #list == 0 then return nil end
	if #list == 1 then return list[1] end
	for i, w in ipairs(list) do
		if w == cur then return list[(i % #list) + 1] end
	end
	return list[1]
end

local function bank5_weapon_name(w)
	if w == WP_MEDIC_SYRINGE then return "poison needle" end
	if w == WP_PLIERS then return "pliers" end
	if w == WP_SMOKE_MARKER then return "smoke marker" end
	if w == WP_SMOKE_BOMB then return "smoke bomb" end
	return "weapon " .. w
end

-- NOTE ON FORCED SWITCHES
--
-- Setting ps.weapon server-side (which is what AddWeaponToPlayer's setcurrent
-- flag does - ps.weapon itself is READONLY to Lua) only holds until the next
-- movement frame. PM_Weapon() in bg_pmove.c runs:
--
--     if (pm->ps->weapon != pm->cmd.weapon)
--         PM_BeginWeaponChange(pm->ps->weapon, pm->cmd.weapon, qfalse);
--
-- cmd.weapon is the *client's* own selection (cg.weaponSelect), and the Q3/ET
-- protocol gives a server no way to write it - there is no "stufftext" and no
-- cgame server-command that sets the selection. So a forced switch is undone
-- as soon as the player's next usercmd arrives.
--
-- The switch that does stick is the one the client makes itself: the slot-5
-- key is the cgame command "weaponbank 5" (CG_WeaponBank_f), which cycles the
-- bank locally. All this module has to do for that to work is make sure the
-- needle is owned AND passes CG_WeaponSelectable() - see syringe_grant() and
-- bank5_has_ammo() above. That is the real mechanism behind slot 5.
local function bank5_select(num, w)
	local pool = AMMO_POOL[w] or w
	local ammo = client_get(num, "ps.ammo", pool) or 0
	local clip = client_get(num, "ps.ammoclip", pool) or 0
	local ok, err = pcall(et.AddWeaponToPlayer, num, w, ammo, clip, 1)
	if ok then
		if SLOT5_NOTIFY then cp(num, "^7" .. bank5_weapon_name(w)) end
		return true
	end
	err_once("bank5_select", err)
	return false
end

-- Only custom verbs are matched here.
--
-- "weaponbank"/"weapon"/"weapnext"/... are all in the cgame consoleCommand_t
-- commands[] table (cg_consolecmds.c). CG_ConsoleCommand() returns qtrue for
-- them, which means the client consumes them locally and never forwards them
-- to the server - so et_ClientCommand() is never called with "weaponbank 5"
-- from a real player, and matching it here can only ever fire for a hand-typed
-- "\weaponbank 5" (which cgame would have eaten first anyway).
--
-- The genuine slot-5 keypress is handled entirely client-side; this hook only
-- exists for players who bind the custom verb instead.
local function is_slot5_command(command)
	if type(command) ~= "string" then return false end
	local c = command:lower()
	return c == SLOT5_TOGGLE_COMMAND or c == "slot5" or c == "poisonneedle"
end

local function poison_cure(num, _reason)
	poisoned[num] = nil
end

local function poison_do(target, attacker, levelTime)
	local tt, at = team_of(target), team_of(attacker)
	if not tt or not at then return false end
	if target == attacker or tt == at then return false end
	if not is_alive(target) then return false end
	local fresh = poisoned[target] == nil
	poisoned[target] = {
		attacker  = attacker,
		expires   = levelTime + POISON_DURATION_MS,
		next_tick = levelTime + POISON_TICK_MS,
	}
	if fresh then
		if POISON_NOTIFY_VICTIM then cp(target, "^1you have been poisoned!") end
		if POISON_NOTIFY_ATTACKER then cp(attacker, "^2poisoned ^7" .. name_of(target)) end
	end
	return true
end

local function syringe_trace_target(num)
	if type(et.trap_Trace) ~= "function" then return nil end
	local o = client_get(num, "ps.origin")
	local v = client_get(num, "ps.viewangles")
	if not o or not v then return nil end
	local vh = client_get(num, "ps.viewheight") or 32
	local eye = { o[1], o[2], o[3] + vh }
	local f = view_forward_pitch_yaw(v)
	if not f then return nil end
	local dst = { eye[1]+f[1]*SYRINGE_RANGE, eye[2]+f[2]*SYRINGE_RANGE, eye[3]+f[3]*SYRINGE_RANGE }
	local ok, tr = pcall(et.trap_Trace, eye, nil, nil, dst, num, MASK_SHOT)
	if not ok or type(tr) ~= "table" then return nil end
	local hit = tr.entityNum
	if type(hit) ~= "number" or hit >= get_client_slots() then return nil end
	return hit
end

-- ========================== SOLDIER SMG SLOT 2 ===========================

local function smg_of(num)
	-- The SMG is the primary for most soldiers, but with the light weapons
	-- skill it sits in the secondary slot instead (classSecondaryWeapons in
	-- bg_classes.c) - hence the whole load-out, not just sess.playerWeapon.
	-- SetWolfSpawnWeapons() grants whatever the load-out says, so a load-out
	-- weapon does not need the ownership check.
	for _, field in ipairs(fields.loadout) do
		local chosen = client_get(num, field)
		if type(chosen) == "number" and SMG_WEAPONS[chosen] then return chosen end
	end
	for w in pairs(SMG_WEAPONS) do
		if has_weapon(num, w) then return w end
	end
	return nil
end

local function pistol_of(num)
	for _, w in ipairs(PISTOLS) do
		if has_weapon(num, w) then return w end
	end
	return nil
end

local function smg_has_ammo(num, w)
	local pool = AMMO_POOL[w] or w
	local clip = client_get(num, "ps.ammoclip", pool)
	local ammo = client_get(num, "ps.ammo", pool)
	if clip == nil and ammo == nil then return true end
	return (clip or 0) > 0 or (ammo or 0) > 0
end

local function smg_select(num, w)
	-- ps.weapon and ps.weaponstate are FIELD_FLAG_READONLY in g_lua.c, so
	-- et.gentity_set() refuses them ("tried to set read-only gentity field").
	-- et.AddWeaponToPlayer() is the engine's own helper for this: it writes the
	-- weapon's pools - assignment, not addition, so feed it what the player
	-- already has - and with setcurrent 1 it puts the weapon in hand.
	-- ps.weaponstate needs no write; the engine raises the weapon itself.
	local pool = AMMO_POOL[w] or w
	local ammo = client_get(num, "ps.ammo", pool) or 0
	local clip = client_get(num, "ps.ammoclip", pool) or 0
	local ok, err = pcall(et.AddWeaponToPlayer, num, w, ammo, clip, 1)
	if not ok then
		err_once("smg_select", err)
		return false
	end
	return true
end

local function is_slot2_command(command)
	if type(command) ~= "string" then return false end
	local c = command:lower()
	if c == "slot2" then return true end
	if c == "weaponbank" or c == "weaponslot" or c:find("weaponbank") or c:find("weaponslot") then
		if type(et.trap_Argv) == "function" then
			local a1 = et.trap_Argv(1) or ""
			if tonumber(a1) == 2 then return true end
		end
		if c:match("weaponbank%s+2") or c:match("weaponslot%s+2") or c == "weaponbank 2" or c == "weaponslot 2" then
			return true
		end
	end
	return false
end

-- =========================== THROWABLE KNIFE =============================
--
-- HOW THE KNIFE IS BUILT, because the obvious way does not exist:
--
--   * ET:Legacy's Lua API has no et.G_Spawn(). The only entity constructor in
--     the etlib[] table of g_lua.c is et.G_CreateEntity("<spawn vars>"), which
--     feeds the key/value string to the engine's own
--     G_SpawnGEntityFromSpawnVars(). A classname that is not in the spawn table
--     makes G_CallSpawn() fail and the entity is freed again - which is why the
--     old "thrown_knife" entity never existed at all. The knife now uses a
--     classname that does exist and does nothing: "target_position", whose spawn
--     function is a single G_SetOrigin() (g_target.c). The entity comes back
--     inert - no think function, no model, no physics, r.contents 0 - so it
--     blocks nothing and is touched by nothing.
--
--   * Lua cannot install a think function, so this module has to be the knife's
--     G_RunMissile() (g_missile.c): evaluate the trajectory, trace from the
--     previous position to the new one, move r.currentOrigin, re-link. The
--     engine only advances an entity's position from its think function, so an
--     entity Lua links once never moves server-side.
--
--   * The knife is drawn as ET_GENERAL, not ET_MISSILE. CG_Missile() picks its
--     model from s.weapon, and s.weapon is FIELD_FLAG_READONLY in g_lua.c, so
--     that write always failed (the pcall hid it) and the knife in flight was
--     invisible. CG_General() draws cgs.gameModels[s.modelindex] instead, and
--     s.modelindex IS writable, so the knife flies with its own world model from
--     itemTable[] (bg_misc.c), precached through et.G_ModelIndex().
--
--   * The trajectory is written to s.pos as TR_GRAVITY, which the client
--     evaluates in CG_CalcEntityLerpPositions() with the very same
--     BG_EvaluateTrajectory() that knife.position() mirrors below. What a player
--     sees flying is therefore where the server traces it - and both use the
--     engine's fixed DEFAULT_GRAVITY, not g_gravity.
--
-- The throw counter lives in the knife's own ps.ammoclip: weaponTable[] gives
-- both knives useAmmo/useClip = qfalse and CG_WeaponHasAmmo() exempts
-- WEAPON_TYPE_MELEE, so neither the engine nor the client ever looks at that
-- pool and it is free to count with.
--
-- Everything the feature needs hangs off this one table: Lua allows 200 locals
-- per chunk and this module is at that limit (the `fields` table above exists
-- for the same reason), so twenty functions and ten constants cost one local.
local knife = {}

-- engine constants the Lua API does not expose
knife.ET_GENERAL = 0        -- entityType_t: the type CG_General() renders
knife.TR_LINEAR  = 2        -- trType_t: the spin
knife.GRAVITY    = 800      -- DEFAULT_GRAVITY, used by BG_EvaluateTrajectory()
                            -- for TR_GRAVITY ("FIXME: local gravity...")
knife.MINS       = { -1, -1, -1 }
knife.MAXS       = {  1,  1,  1 }
knife.MASK       = (et and et.MASK_MISSILESHOT) or MASK_SHOT
knife.MODELS = {
	[WP_KNIFE]       = "models/multiplayer/knife/knife.md3",
	[WP_KNIFE_KABAR] = "models/multiplayer/knife_kbar/knife.md3",
}
knife.MODS = {
	[WP_KNIFE]       = MOD_KNIFE,
	[WP_KNIFE_KABAR] = (et and et.MOD_KNIFE_KABAR) or MOD_KNIFE,
}
knife.index = {}            -- [weapon] = modelindex, precached once per map

-- Read how many throws a player has left. The melee stab is never disabled,
-- only the *throw* is gated on clip > 0.
function knife.clip(num, weapon)
	local c = client_get(num, "ps.ammoclip", weapon)
	return (type(c) == "number" and c >= 0) and c or KNIFE_CLIP_MAX
end

function knife.set_clip(num, weapon, new_clip)
	if new_clip < 0 then new_clip = 0 end
	if new_clip > KNIFE_CLIP_MAX then new_clip = KNIFE_CLIP_MAX end
	local cur_ammo = client_get(num, "ps.ammo", weapon) or 0
	pcall(et.AddWeaponToPlayer, num, weapon, cur_ammo, new_clip, 0)
end

-- Grant the clip of throwing knives. Called on spawn / revive so the player
-- starts each life with KNIFE_CLIP_MAX throws.
function knife.grant_clip(num)
	if not KNIFE_ENABLE then return end
	if not is_on_team(num) then return end
	for w, _ in pairs(KNIVES) do
		if has_weapon(num, w) then
			-- et.AddWeaponToPlayer() *assigns* both pools, so hand back the
			-- reserve the class load-out gave the knife (bg_classes.c:
			-- startingAmmo 1, startingClip 0) instead of zeroing it
			local ammo = client_get(num, "ps.ammo", w) or 0
			pcall(et.AddWeaponToPlayer, num, w, ammo, KNIFE_CLIP_MAX, 0)
		end
	end
end

-- Consume one throw (decrement clip).
function knife.consume(num, weapon)
	knife.set_clip(num, weapon, knife.clip(num, weapon) - 1)
end

-- Add one throw to the clip (pickup); returns true if added, false if the clip
-- was already full (so the pickup doesn't "eat" a knife that has nowhere to
-- go and the knife stays in the world).
function knife.add(num, weapon)
	local cur = knife.clip(num, weapon)
	if cur >= KNIFE_CLIP_MAX then return false end
	knife.set_clip(num, weapon, cur + 1)
	return true
end

function knife.free(ent)
	knives[ent] = nil
	if type(et.G_FreeEntity) == "function" then pcall(et.G_FreeEntity, ent) end
end

-- G_Spawn() calls G_Error() - which takes the whole server down - when the
-- entity pool runs out, so the number of knives in the world is capped and the
-- oldest one is freed to make room.
function knife.prune()
	local live = 0
	for _ in pairs(knives) do live = live + 1 end
	while live >= KNIFE_MAX_LIVE do
		local oldest, oldest_ent
		for ent, k in pairs(knives) do
			if not oldest or (k.spawned or 0) < oldest then
				oldest, oldest_ent = k.spawned or 0, ent
			end
		end
		if not oldest_ent then return end
		knife.free(oldest_ent)
		live = live - 1
	end
end

-- precache the world models once per map; et.G_ModelIndex() allocates the
-- CS_MODELS configstring the client reads cgs.gameModels[] from
function knife.register_models()
	knife.index = {}
	if not KNIFE_MODEL then return end
	if type(et.G_ModelIndex) ~= "function" then return end
	for w, path in pairs(knife.MODELS) do
		local ok, idx = pcall(et.G_ModelIndex, path)
		if ok and type(idx) == "number" and idx > 0 then
			knife.index[w] = idx
		elseif not ok then
			err_once("knife_model:" .. path, idx)
		end
	end
end

function knife.create(origin)
	if type(et.G_CreateEntity) ~= "function" then return nil end
	local vars = string.format('classname %s origin "%.1f %.1f %.1f"',
		KNIFE_SPAWN_CLASS, origin[1], origin[2], origin[3])
	local ok, ent = pcall(et.G_CreateEntity, vars)
	if not ok then
		err_once("knife_create", ent)
		return nil
	end
	if type(ent) ~= "number" then return nil end
	-- G_SpawnGEntityFromSpawnVars() frees the entity again when it cannot call
	-- a spawn function for the classname; never track a slot the engine has
	-- already given up, or the next knife.free() would free somebody else's
	local ok2, inuse = pcall(et.gentity_get, ent, "inuse")
	if not ok2 or inuse ~= 1 then return nil end
	return ent
end

-- angles that point a model's forward axis along `dir` (vectoangles() in
-- q_math.c, which negates the elevation because AngleVectors() computes
-- forward[2] as -sin(pitch)). math.atan2 is gone in Lua 5.3+ (math.atan takes
-- two arguments there) and math.atan(y, x) does not exist in the Lua 5.1 /
-- LuaJIT builds ET:Legacy can be compiled with, so support both.
function knife.angles_of(dir)
	local len = math.sqrt(dir[1]*dir[1] + dir[2]*dir[2] + dir[3]*dir[3])
	if len < 0.0001 then return { 0, 0, 0 } end
	local yaw
	if math.atan2 then yaw = math.atan2(dir[2], dir[1]) else yaw = math.atan(dir[2], dir[1]) end
	return { -math.deg(math.asin(math.max(-1, math.min(1, dir[3] / len)))), math.deg(yaw), 0 }
end

-- BG_EvaluateTrajectory() for TR_GRAVITY (bg_misc.c): base + delta*t with the
-- fixed DEFAULT_GRAVITY pulled off the z component.
function knife.position(k, time)
	local dt = (time - k.time0) * 0.001
	return {
		k.base[1] + k.delta[1] * dt,
		k.base[2] + k.delta[2] * dt,
		k.base[3] + k.delta[3] * dt - 0.5 * knife.GRAVITY * dt * dt,
	}
end

function knife.spawn(num, weapon, levelTime)
	local o = client_get(num, "ps.origin")
	local v = client_get(num, "ps.viewangles")
	if not o or not v then return nil end
	local f = view_forward_pitch_yaw(v)
	if not f then return nil end
	local vh = client_get(num, "ps.viewheight") or 32
	-- out in front of the eyes, like the engine's own muzzle point
	local muzzle = { o[1] + f[1]*16, o[2] + f[2]*16, o[3] + vh + f[3]*16 }
	local delta  = { f[1]*THROW_SPEED, f[2]*THROW_SPEED, f[3]*THROW_SPEED + THROW_UP }
	local angles = knife.angles_of(delta)

	knife.prune()
	local ent = knife.create(muzzle)
	if not ent then return nil end

	-- ET_GENERAL + s.modelindex is the one combination Lua can write and the
	-- client draws (CG_General); ET_MISSILE would need the read-only s.weapon
	pcall(et.gentity_set, ent, "s.eType", knife.ET_GENERAL)
	if knife.index[weapon] then
		pcall(et.gentity_set, ent, "s.modelindex", knife.index[weapon])
	end
	pcall(et.gentity_set, ent, "r.ownerNum", num)
	pcall(et.gentity_set, ent, "r.mins", knife.MINS)
	pcall(et.gentity_set, ent, "r.maxs", knife.MAXS)
	pcall(et.gentity_set, ent, "clipmask", knife.MASK)
	pcall(et.gentity_set, ent, "s.angles", angles)
	pcall(et.gentity_set, ent, "s.pos", {
		trType = TR_GRAVITY, trTime = levelTime, trBase = muzzle, trDelta = delta,
	})
	pcall(et.gentity_set, ent, "s.apos", {
		trType = (KNIFE_SPIN > 0) and knife.TR_LINEAR or TR_STATIONARY,
		trTime = levelTime, trBase = angles, trDelta = { KNIFE_SPIN, 0, 0 },
	})
	pcall(et.gentity_set, ent, "r.currentOrigin", muzzle)
	if type(et.trap_LinkEntity) == "function" then pcall(et.trap_LinkEntity, ent) end

	knives[ent] = {
		owner   = num,
		weapon  = weapon,
		spawned = levelTime,
		time0   = levelTime,
		base    = muzzle,
		delta   = delta,
		last    = { muzzle[1], muzzle[2], muzzle[3] },
		landed  = nil,
		resting = nil,
	}
	return ent
end

function knife.hit_player(ent, k, victim, hitpos)
	local vo = client_get(victim, "ps.origin")
	local dmg = THROW_DAMAGE
	-- head box: origin + viewheight, mins z -2 (G_BuildHead, g_combat.c). Using
	-- the victim's own viewheight means a crouching player is still headshottable
	local head = KNIFE_HEAD_HEIGHT
	local vh = client_get(victim, "ps.viewheight")
	if type(vh) == "number" and vh > 0 then head = vh - 2 end
	if vo and hitpos and hitpos[3] - vo[3] >= head then
		dmg = THROW_DAMAGE_HEAD
	end
	-- et.G_Damage(target, inflictor, attacker, damage, dflags, mod)
	pcall(et.G_Damage, victim, k.owner, k.owner, dmg, 0, knife.MODS[k.weapon] or MOD_KNIFE)
end

function knife.land(ent, k, pos, levelTime)
	-- stick the knife in whatever stopped it, pointing along the velocity it
	-- had on impact (BG_EvaluateTrajectoryDelta() for TR_GRAVITY)
	local dt = (levelTime - k.time0) * 0.001
	local angles = knife.angles_of({ k.delta[1], k.delta[2], k.delta[3] - knife.GRAVITY * dt })
	k.landed  = levelTime
	k.resting = { pos[1], pos[2], pos[3] }
	-- freeze the trajectory where the trace says it stopped, so the client's
	-- model stops exactly where the server put the entity
	pcall(et.gentity_set, ent, "s.pos", {
		trType = TR_STATIONARY, trTime = levelTime, trBase = k.resting, trDelta = { 0, 0, 0 },
	})
	pcall(et.gentity_set, ent, "s.apos", {
		trType = TR_STATIONARY, trTime = levelTime, trBase = angles, trDelta = { 0, 0, 0 },
	})
	pcall(et.gentity_set, ent, "s.angles", angles)
	pcall(et.gentity_set, ent, "r.currentOrigin", k.resting)
	if type(et.trap_LinkEntity) == "function" then pcall(et.trap_LinkEntity, ent) end
end

-- one frame of flight, i.e. what G_RunMissile() does for the engine's own
-- grenades: trace from the previous position to the new one - ignoring the
-- thrower, whose bounding box the muzzle starts inside - then hit, land, or
-- move and re-link.
-- One trace of this frame's segment; nil when the engine has no trap_Trace.
function knife.trace(from, to, passent)
	if type(et.trap_Trace) ~= "function" then return nil end
	local ok, t = pcall(et.trap_Trace, from, knife.MINS, knife.MAXS, to, passent, knife.MASK)
	if ok and type(t) == "table" then return t end
	return nil
end

-- A player the knife may damage. Teammates are not one, and neither is a corpse
-- or a spectator.
function knife.is_target(hit, k)
	if type(hit) ~= "number" or hit < 0 or hit >= get_client_slots() then return false end
	if hit == k.owner or not has_client(hit) or not is_alive(hit) then return false end
	local theirs = team_of(hit)
	if not theirs then return false end
	local mine = team_of(k.owner)
	return not (mine and mine == theirs)
end

-- A body the knife flies through instead of hitting.
function knife.pass_through(hit, k)
	if type(hit) ~= "number" or hit < 0 or hit >= get_client_slots() then return false end
	return has_client(hit) and not knife.is_target(hit, k)
end

-- one frame of flight, i.e. what G_RunMissile() does for the engine's own
-- grenades: trace from the previous position to the new one - ignoring the
-- thrower, whose bounding box the muzzle starts inside - then hit, land, or
-- move and re-link.
function knife.fly(ent, k, levelTime)
	local pos = knife.position(k, levelTime)
	-- G_Damage() refuses a same-team target unless the server turned
	-- g_friendlyFire on (g_combat.c:1627), so hitting a friendly would spend
	-- the knife for nothing and make throwing it in a group useless. A trace
	-- that stops on a body which is not a target is therefore continued from the
	-- hit point, with that body as the new passent. One pass-through per frame
	-- is plenty: at THROW_SPEED the knife covers 70 units in a 50ms frame and a
	-- player is 36 units wide.
	local tr = knife.trace(k.last, pos, k.owner)
	if tr and knife.pass_through(tr.entityNum, k) then
		tr = knife.trace(tr.endpos or pos, pos, tr.entityNum) or tr
	end

	if tr then
		local frac = tr.fraction
		if tr.startsolid then frac = 0 end
		local hit = tr.entityNum
		if knife.is_target(hit, k) then
			knife.hit_player(ent, k, hit, tr.endpos or pos)
			knife.free(ent)
			return
		end
		if knife.pass_through(hit, k) then
			-- still inside a friendly: keep flying, never stick in a teammate
			tr = nil
		elseif type(frac) == "number" and frac < 1 then
			knife.land(ent, k, tr.endpos or pos, levelTime)
			return
		end
	end

	k.last = { pos[1], pos[2], pos[3] }
	pcall(et.gentity_set, ent, "r.currentOrigin", pos)
	if type(et.trap_LinkEntity) == "function" then pcall(et.trap_LinkEntity, ent) end
end

function knife.pickup(ent, k, levelTime)
	if levelTime - (k.landed or levelTime) >= KNIFE_LIFETIME_MS then
		knife.free(ent)
		return
	end
	local pos = k.resting
	if not pos then return end
	local range_sq = KNIFE_PICKUP_RANGE * KNIFE_PICKUP_RANGE
	for c = 0, get_client_slots() - 1 do
		if has_client(c) and is_alive(c) and team_of(c) then
			local o = client_get(c, "ps.origin")
			if o and dist2(o, pos) <= range_sq then
				if knife.add(c, k.weapon) then
					knife.free(ent)
					return
				end
			end
		end
	end
end

-- ========================= EVENT HANDLERS ================================

-- runs every server frame - each feature isolated
local function on_game_frame(levelTime)
	-- the module's clock: everything below, and every callback that runs
	-- between two frames, reads time from here
	frame_time = tonumber(levelTime) or frame_time

	-- adrenaline strip medics
	if ADRENALINE_ENABLE then
		local ok, err = pcall(function()
			for i = 0, get_client_slots() - 1 do
				if is_on_team(i) and class_of(i) == PC_MEDIC then
					adrenaline_strip(i)
				end
			end
		end)
		if not ok then err_once("adrenaline_frame", err) end
	end

	-- disguise break
	if DISGUISE_BREAK_ENABLE then
		local ok, err = pcall(function()
			for i = 0, get_client_slots() - 1 do
				if not has_client(i) then
					last_weapon[i] = nil
				else
					local team = client_get(i, "sess.sessionTeam")
					local h    = client_get(i, "ps.stats", STAT_HEALTH)
					local wp   = client_get(i, "ps.weapon")
					if not team or team == TEAM_SPECTATOR or not wp or not h or h <= 0 then
						last_weapon[i] = nil
					else
						local prev = last_weapon[i]
						last_weapon[i] = wp
						if prev ~= nil and not same_base_weapon(prev, wp) and is_disguised(i) then
							local o  = client_get(i, "ps.origin")
							local va = client_get(i, "ps.viewangles")
							local vh = client_get(i, "ps.viewheight")
							if o and va then
								local eye = { o[1], o[2], o[3] + (vh or 32) }
								if disguise_enemy_in_front(i, eye, view_forward_yaw_pitch(va)) then
									break_disguise(i)
								end
							end
						end
					end
				end
			end
		end)
		if not ok then err_once("disguise_frame", err) end
	end

	-- kick projectiles
	if KICK_ENABLE then
		local ok, err = pcall(function()
			local nades, missiles, top_ent = {}, 0, -1
			for e = MAX_CLIENTS, MAX_ENTITIES - 1 do
				local ok2, inuse = pcall(et.gentity_get, e, "inuse")
				if ok2 and inuse == 1 then
					top_ent = e
					local ok3, etype = pcall(et.gentity_get, e, "s.eType")
					if ok3 and etype == ET_MISSILE then
						missiles = missiles + 1
						local ok4, wp = pcall(et.gentity_get, e, "s.weapon")
						if ok4 and wp and KICKABLE_WEAPONS[wp] then
							local ok5, pos = pcall(et.gentity_get, e, "origin")
							if ok5 and pos then nades[#nades+1] = { e, pos } end
						end
					end
				end
			end
			if DEBUG and (not last_kick_debug or levelTime - last_kick_debug >= 2000) then
				last_kick_debug = levelTime
				local pl = {}
				kick_collect_players(pl)
				log("debug kickables=" .. #nades .. " missiles=" .. missiles .. " top=" .. top_ent .. " players=" .. #pl)
			end
			if #nades > 0 then
				local players = {}
				kick_collect_players(players)
				if #players > 0 then
					for _, n in ipairs(nades) do
						local p, pos = n[1], n[2]
						if not last_kick[p] or levelTime - last_kick[p] >= KICK_COOLDOWN_MS then
							for _, pl in ipairs(players) do
								local dx = pos[1] - pl.origin[1]
								local dy = pos[2] - pl.origin[2]
								local dz = pos[3] - (pl.origin[3] + 8)
								if dx*dx + dy*dy + dz*dz <= KICK_RANGE_SQ and pl.speed2 <= KICK_STATIONARY_SQ and kick_looking_at(pl, pos) then
									do_kick(p, pos, pl, levelTime)
									break
								end
							end
						end
					end
				end
			end
		end)
		if not ok then err_once("kick_frame", err) end
	end

	-- no-combat-selfkill stillness tracking
	if NOKILL_ENABLE then
		local ok, err = pcall(function()
			for c = 0, get_client_slots() - 1 do
				if has_client(c) and team_of(c) and is_alive(c) then
					local o = client_get(c, "ps.origin")
					if o then
						local prev = last_origin[c]
						if prev and prev[1] == o[1] and prev[2] == o[2] and prev[3] == o[3] then
							if not still_since[c] then still_since[c] = levelTime end
						else
							still_since[c] = nil
						end
						last_origin[c] = { o[1], o[2], o[3] }
					end
				else
					still_since[c] = nil
					last_origin[c] = nil
				end
			end
		end)
		if not ok then err_once("nokill_frame", err) end
	end

	-- poison ticks
	if POISON_ENABLE then
		local ok, err = pcall(function()
			for target, p in pairs(poisoned) do
				if not has_client(target) or not is_alive(target) or team_of(target) == nil then
					poisoned[target] = nil
				elseif levelTime >= p.expires then
					poisoned[target] = nil
					if POISON_NOTIFY_VICTIM then cp(target, "^2the poison wears off") end
				elseif levelTime >= p.next_tick then
					p.next_tick = levelTime + POISON_TICK_MS
					local attacker = p.attacker
					if not has_client(attacker) then attacker = target end
					pcall(et.G_Damage, target, attacker, attacker, POISON_TICK_DAMAGE, DAMAGE_NO_KNOCKBACK, MOD_SYRINGE)
				end
			end
		end)
		if not ok then err_once("poison_frame", err) end
	end

	-- throwable knife flight / pickup
	if KNIFE_ENABLE then
		local ok, err = pcall(function()
			for ent, k in pairs(knives) do
				local ok2, inuse = pcall(et.gentity_get, ent, "inuse")
				local ok3, cls   = pcall(et.gentity_get, ent, "classname")
				local mine = ok2 and inuse == 1
					and (not ok3 or cls == KNIFE_SPAWN_CLASS)
				if not mine then
					-- the engine gave this slot up (a map script, another mod)
					-- and something else moved in: drop the record and never
					-- free an entity that is not ours
					knives[ent] = nil
				elseif k.landed then
					knife.pickup(ent, k, levelTime)
				elseif levelTime - (k.spawned or levelTime) >= KNIFE_LIFETIME_MS then
					-- flew out of the world without ever hitting anything
					knife.free(ent)
				else
					knife.fly(ent, k, levelTime)
				end
			end
		end)
		if not ok then err_once("knife_frame", err) end
	end
end

-- player spawn (revived==0 means fresh spawn; also called after revive per
-- main.lua but only with revived=0 -- we still run on every spawn the engine
-- reports, which is safer for weapon grants)
local function on_player_spawn(clientId, revived)
	-- reset per-life state
	clear_no_client(clientId)
	last_combat[clientId] = nil
	still_since[clientId] = nil
	last_origin[clientId]  = nil
	last_weapon[clientId]  = nil
	poison_cure(clientId, "spawn")
	next_throw[clientId]   = nil
	-- NOTE: thrown knives that landed stay in the world across spawns;
	-- only the thrower's own clip is reset below.

	if not enabled then return end
	if not is_on_team(clientId) then return end
	local cls = class_of(clientId)

	if ADRENALINE_ENABLE then
		if cls == PC_MEDIC then
			adrenaline_strip(clientId)
		else
			adrenaline_grant(clientId)
		end
	end

	if POISON_ENABLE then
		-- A spawn / revive / full-heal always clears poison.
		poison_cure(clientId, "spawn")
		syringe_grant(clientId)
	end

	if KNIFE_ENABLE then
		knife.grant_clip(clientId)
	end

	if SMG_SLOT2_ENABLE and GRANT_TEAM_SMG and cls == PC_SOLDIER then
		if not smg_of(clientId) then
			local s = TEAM_SMG[team_of(clientId)]
			if s then pcall(et.AddWeaponToPlayer, clientId, s, GRANT_SMG_AMMO, GRANT_SMG_CLIP, 0) end
		end
	end
end

local function on_client_connect(clientId)
	clear_no_client(clientId)
end

local function on_client_begin(clientId)
	clear_no_client(clientId)
end

local function on_client_disconnect(clientId)
	no_client[clientId]     = nil
	last_combat[clientId]   = nil
	still_since[clientId]   = nil
	last_origin[clientId]   = nil
	last_weapon[clientId]   = nil
	next_throw[clientId]    = nil
	poison_cure(clientId, "disconnect")
	for target, p in pairs(poisoned) do
		if p.attacker == clientId then p.attacker = target end
	end
	-- Knives thrown by a disconnected player remain pickup-able in the world.
end

-- client command (weapon-slot toggles + /kill block)
local function on_client_command(clientId, command)
	if type(command) ~= "string" then return 0 end
	clear_no_client(clientId)
	if not enabled then return 0 end

	-- --- slot 7 (landmine <-> adrenaline) ---
	if ADRENALINE_ENABLE and is_slot7_command(command) then
		if is_on_team(clientId) then
			local w = pick_bank7(clientId)
			if w and w ~= client_get(clientId, "ps.weapon") then
				if bank7_select(clientId, w) then return 1 end
			end
		end
		return 0
	end

	-- --- slot 5 (syringe toggle) ---
	if POISON_ENABLE and SLOT5_TOGGLE and is_slot5_command(command) then
		if is_on_team(clientId) and has_weapon(clientId, WP_MEDIC_SYRINGE) then
			local w = pick_bank5(clientId)
			if w and w ~= client_get(clientId, "ps.weapon") then
				if bank5_select(clientId, w) then return 1 end
			end
		end
		return 0
	end

	-- --- slot 2 (soldier SMG) ---
	if SMG_SLOT2_ENABLE and is_slot2_command(command) then
		if is_on_team(clientId) and class_of(clientId) == PC_SOLDIER then
			local smg = smg_of(clientId)
			if smg then
				local pistol = pistol_of(clientId)
				local cur    = client_get(clientId, "ps.weapon")
				local want
				if cur == smg then
					want = pistol
				elseif smg_has_ammo(clientId, smg) then
					want = smg
				else
					want = pistol
				end
				if want and want ~= cur then
					if smg_select(clientId, want) then return 1 end
				end
			end
		end
		return 0
	end

	-- --- no-combat-selfkill ---
	if NOKILL_ENABLE and is_selfkill_cmd(command:lower()) then
		if team_of(clientId) and is_alive(clientId) then
			if NOKILL_LOW_HEALTH then
				local h = client_get(clientId, "ps.stats", STAT_HEALTH)
				if h and h <= NOKILL_LOW_HEALTH_VAL then return 0 end
			end
			if is_stuck(clientId, now_ms()) then return 0 end
			local now = now_ms()
			local lc  = last_combat[clientId]
			if lc and (now - lc) < COMBAT_WINDOW_MS then
				local left = math.ceil((COMBAT_WINDOW_MS - (now - lc)) / 1000)
				cp(clientId, "^1you cannot ^7/kill ^1in a fire fight^7\n^3wait "
					.. left .. " second" .. (left == 1 and "" or "s"))
				return 1
			end
			local w = seen_by_enemy(clientId)
			if w then
				cp(clientId, "^1you cannot ^7/kill ^1while an enemy can see you")
				return 1
			end
		end
		return 0
	end

	return 0
end

-- damage event (poison syringe hit + combat tracking)
local function on_damage(target, attacker, damage, damageFlags, meansOfDeath)
	if not enabled then return 0 end
	if type(target) == "number" then clear_no_client(target) end
	if type(attacker) == "number" then clear_no_client(attacker) end
	-- no-combat-selfkill combat timer
	if NOKILL_ENABLE then
		local ok, err = pcall(function()
			local tt = team_of(target); local at = team_of(attacker)
			if tt and at and tt ~= at and target ~= attacker then
				local now = now_ms()
				last_combat[target]   = now
				last_combat[attacker] = now
			end
		end)
		if not ok then err_once("nokill_damage", err) end
	end

	-- poison: MOD_SYRINGE on a live enemy applies poison
	if POISON_ENABLE and meansOfDeath == MOD_SYRINGE then
		local ok, err = pcall(function()
			poison_do(target, attacker, now_ms())
		end)
		if not ok then err_once("poison_damage", err) end
	end

	return 0
end

-- weapon fire event (poison syringe trace + throwable knife + medic block)
local function on_weapon_fire(clientId, weapon)
	if not enabled then return 0 end
	clear_no_client(clientId)
	-- adrenaline: medics must not fire it (defense in depth)
	if ADRENALINE_ENABLE and weapon == WP_MEDIC_ADRENALINE
		and is_on_team(clientId) and class_of(clientId) == PC_MEDIC then
		adrenaline_strip(clientId)
		return 1
	end

	-- poison needle: trace-based stab (for builds where syringe hits do 0 dmg)
	-- and adrenaline-cures-poison
	if POISON_ENABLE then
		local ok, err = pcall(function()
			if weapon == WP_MEDIC_ADRENALINE and POISON_CURE_ADRENALINE then
				poison_cure(clientId, "adrenaline")
				return
			end
			if weapon == WP_MEDIC_SYRINGE then
				local tgt = syringe_trace_target(clientId)
				if tgt then poison_do(tgt, clientId, now_ms()) end
			end
		end)
		if not ok then err_once("poison_fire", err) end
	end

	-- throwable knife
	if KNIFE_ENABLE and KNIVES[weapon] then
		local intercepted = 0
		local ok, res = pcall(function()
			if not (team_of(clientId) and is_alive(clientId)) then return 0 end
			local now = now_ms()
			if next_throw[clientId] and now < next_throw[clientId] then return 0 end

			-- Require at least one throw in the clip; if empty, let the
			-- engine do the normal melee stab (return 0).
			if knife.clip(clientId, weapon) <= 0 then return 0 end

			if not knife.spawn(clientId, weapon, now) then return 0 end
			next_throw[clientId] = now + THROW_COOLDOWN_MS
			knife.consume(clientId, weapon)
			return 1   -- swallow the melee stab; the thrown knife is the attack
		end)
		if ok then intercepted = res else err_once("knife_fire", res) end
		return intercepted
	end

	return 0
end

local function on_game_init(levelTime, randomSeed, isRestart)
	no_client = {}
	reported_errors = {}
	refresh_client_slots()
	fields.probe()

	-- the clock starts at this map's level.time; every later reading comes
	-- from onGameFrame()
	frame_time = tonumber(levelTime) or 0

	last_kick = {}; kick_sound_index = 0; last_kick_debug = 0
	last_weapon = {}
	last_combat = {}; still_since = {}; last_origin = {}
	poisoned = {}
	knives = {}; next_throw = {}

	enabled = is_gameplay_enabled()

	if not enabled then
		log("disabled via g_gameplay 0 - all gameplay tweaks off")
		return
	end

	if KICK_ENABLE and KICK_SOUND and type(et.G_SoundIndex) == "function" then
		local ok, idx = pcall(et.G_SoundIndex, KICK_SOUND_FILE)
		if ok and idx and idx ~= 0 then kick_sound_index = idx end
	end

	if KNIFE_ENABLE then knife.register_models() end

	log("loaded (client slots: " .. get_client_slots() .. ")")
	local feats = {}
	if ADRENALINE_ENABLE  then feats[#feats+1] = "adrenaline+slot7" end
	if DISGUISE_BREAK_ENABLE then feats[#feats+1] = "disguise-break" end
	if KICK_ENABLE        then feats[#feats+1] = "kick-projectiles" end
	if NOKILL_ENABLE      then feats[#feats+1] = "no-combat-selfkill" end
	if POISON_ENABLE      then feats[#feats+1] = "poison-needle" end
	if SMG_SLOT2_ENABLE   then feats[#feats+1] = "smg-slot2" end
	if KNIFE_ENABLE       then feats[#feats+1] = "throwable-knife" end
	log("features: " .. table.concat(feats, ", "))
	log("ready - set g_gameplay 0 to disable, 1 to enable")

	if type(et.AddWeaponToPlayer) ~= "function" then
		log("WARNING: et.AddWeaponToPlayer missing - some features will not work")
	end
	-- et.G_Spawn() does not exist in ET:Legacy's Lua API (the etlib[] table in
	-- g_lua.c); entities come from et.G_CreateEntity("<spawn vars>")
	if type(et.G_CreateEntity) ~= "function" then
		log("WARNING: et.G_CreateEntity missing - throwable knife disabled")
	end
	if KNIFE_ENABLE and type(et.G_ModelIndex) ~= "function" then
		log("WARNING: et.G_ModelIndex missing - thrown knives will be invisible")
	end
end

-- ========================== REGISTRATION =================================

-- Register handlers with WolfAdmin's event bus. Return values are respected
-- by events.trigger, so onClientCommand returning 1 properly swallows
-- intercepted weapon-slot / /kill commands.
events.handle("onGameInit",        on_game_init)
events.handle("onGameFrame",       on_game_frame)
events.handle("onPlayerSpawn",     on_player_spawn)
events.handle("onClientConnect",   on_client_connect)
events.handle("onClientBegin",     on_client_begin)
events.handle("onClientDisconnect",on_client_disconnect)
events.handle("onClientCommand",   on_client_command)

-- onDamage / onWeaponFire are custom events fired from additions to main.lua
-- (see below); if they aren't added yet, add them.
if not events.get("onDamage") then       events.add("onDamage")       end
if not events.get("onWeaponFire") then  events.add("onWeaponFire")  end
events.handle("onDamage",      on_damage)
events.handle("onWeaponFire",  on_weapon_fire)

return gameplay
