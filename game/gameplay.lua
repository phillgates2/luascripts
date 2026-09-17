
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
local THROW_SPEED           = 1400
local THROW_UP              = 40
local THROW_DAMAGE          = 45
local THROW_DAMAGE_HEAD     = 100
local THROW_COOLDOWN_MS     = 800
local KNIFE_LIFETIME_MS     = 30000
local KNIFE_PICKUP_RANGE    = 48
local THROW_KEEP_KNIFE      = false
local THROW_RETURN_AFTER_MS = 30000
local KNIFE_HEAD_HEIGHT     = 46

-- misc
local DEBUG                 = false
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

local ET_MISSILE = 3
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
local KNIVES = { [WP_KNIFE] = true, [WP_KNIFE_KABAR] = true }
local KICKABLE_WEAPONS = {
	[WP_GRENADE_LAUNCHER] = true,
	[WP_GRENADE_PINEAPPLE] = true,
	[WP_SMOKE_MARKER] = true,
	[WP_SMOKE_BOMB] = true,
}

local DEG2RAD = math.pi / 180

local MODULE_TAG = "[wolfadmin:gameplay]"

-- ============================== state ====================================
local client_slots
local no_client = {}
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

local knives = {}              -- throwable_knife [ent] = { owner, weapon, last, landed }
local next_throw = {}
local owed_knife = {}

-- ============================== helpers ==================================

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

-- protected client-field read that never aborts the callback
local function client_get(num, field, index)
	if no_client[num] then return nil end
	if num < 0 or num >= get_client_slots() then return nil end
	local ok, val = pcall(et.gentity_get, num, field, index)
	if not ok then
		no_client[num] = true
		log("warning: client slot " .. num .. " has no client fields ("
			.. tostring(val) .. ") - skipping it for this map")
		return nil
	end
	return val
end

local function has_client(num)
	if type(num) ~= "number" or num < 0 or num >= get_client_slots()
		or no_client[num] then
		return false
	end
	return et.gentity_get(num, "inuse") == 1
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

-- ps.weapons is two 32-bit words; weapon w is bit (w%32) of word floor(w/32)
local function has_weapon(num, w)
	local mask = client_get(num, "ps.weapons", math.floor(w / 32))
	if type(mask) ~= "number" then return false end
	return math.floor(mask / (2 ^ (w % 32))) % 2 == 1
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
	if type(et.trap_Milliseconds) == "function" then
		return et.trap_Milliseconds() or 0
	end
	return 0
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
	local ammo, clip = ADRENALINE_AMMO, ADRENALINE_AMMOCLIP
	if has_weapon(clientNum, WP_MEDIC_SYRINGE) then
		ammo  = client_get(clientNum, "ps.ammo",  WP_MEDIC_SYRINGE) or 0
		clip  = (client_get(clientNum, "ps.ammoclip", WP_MEDIC_SYRINGE) or 0)
			+ ADRENALINE_AMMOCLIP
	end
	et.AddWeaponToPlayer(clientNum, WP_MEDIC_ADRENALINE, ammo, clip, 0)
end

local function adrenaline_strip(clientNum)
	pcall(et.RemoveWeaponFromPlayer, clientNum, WP_MEDIC_ADRENALINE)
end

-- slot 7 helpers
local function bank7_has_ammo(num, w)
	local pool = (w == WP_MEDIC_ADRENALINE) and WP_MEDIC_SYRINGE or w
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
	local pool = (w == WP_MEDIC_ADRENALINE) and WP_MEDIC_SYRINGE or w
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
	if c == SLOT7_TOGGLE_COMMAND or c == "slot7" then return true end
	if c == "weaponbank" or c == "weaponslot" then
		if type(et.trap_Argv) == "function" then
			return tonumber(et.trap_Argv(1) or "") == 7
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

local KICK_CONE_COS = math.cos(KICK_CONE_HALF_ANGLE * DEG2RAD)
local KICK_RANGE_SQ = KICK_RANGE * KICK_RANGE
local KICK_STATIONARY_SQ = KICK_STATIONARY_SPEED * KICK_STATIONARY_SPEED

local function kick_collect_players(players)
	for i = 0, get_client_slots() - 1 do
		if et.gentity_get(i, "inuse") == 1 then
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
	local tr = et.gentity_get(p, "s.pos")
	if not tr then return end
	tr.trType = TR_GRAVITY; tr.trTime = levelTime
	tr.trBase = nb; tr.trDelta = {vx, vy, vz}
	et.gentity_set(p, "s.pos", tr)
	et.gentity_set(p, "r.currentOrigin", nb)
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
	if has_weapon(num, WP_MEDIC_SYRINGE) then return end
	local ammo, clip = SYRINGE_AMMO, SYRINGE_AMMOCLIP
	if has_weapon(num, WP_MEDIC_ADRENALINE) then
		ammo = client_get(num, "ps.ammo", WP_MEDIC_SYRINGE) or 0
		clip = (client_get(num, "ps.ammoclip", WP_MEDIC_SYRINGE) or 0) + SYRINGE_AMMOCLIP
	end
	if type(et.AddWeaponToPlayer) == "function" then
		et.AddWeaponToPlayer(num, WP_MEDIC_SYRINGE, ammo, clip, 0)
	end
end

local function bank5_has_ammo(num, w)
	if w ~= WP_MEDIC_SYRINGE and w ~= WP_MEDIC_ADRENALINE then return true end
	local clip = client_get(num, "ps.ammoclip", WP_MEDIC_SYRINGE)
	local ammo = client_get(num, "ps.ammo", WP_MEDIC_SYRINGE)
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

local function bank5_select(num, w)
	local pool = (w == WP_MEDIC_ADRENALINE) and WP_MEDIC_SYRINGE or w
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

local function is_slot5_command(command)
	if type(command) ~= "string" then return false end
	local c = command:lower()
	if c == SLOT5_TOGGLE_COMMAND or c == "slot5" then return true end
	if c == "weaponbank" or c == "weaponslot" then
		if type(et.trap_Argv) == "function" then
			return tonumber(et.trap_Argv(1) or "") == 5
		end
	end
	return false
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
	local chosen = client_get(num, "sess.playerWeapon")
	if chosen and SMG_WEAPONS[chosen] and has_weapon(num, chosen) then return chosen end
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
	local pool = PISTOL_POOL[w] or w
	local clip = client_get(num, "ps.ammoclip", pool)
	local ammo = client_get(num, "ps.ammo", pool)
	if clip == nil and ammo == nil then return true end
	return (clip or 0) > 0 or (ammo or 0) > 0
end

local function smg_select(num, w)
	pcall(et.gentity_set, num, "ps.weapon", w)
	pcall(et.gentity_set, num, "ps.weaponstate", 0)
	return true
end

local function is_slot2_command(command)
	if type(command) ~= "string" then return false end
	local c = command:lower()
	if c == "slot2" then return true end
	if c == "weaponbank" or c == "weaponslot" then
		if type(et.trap_Argv) == "function" then
			return tonumber(et.trap_Argv(1) or "") == 2
		end
	end
	return false
end

-- =========================== THROWABLE KNIFE =============================

local function knife_spawn(num, weapon, levelTime)
	if type(et.G_Spawn) ~= "function" then return nil end
	local o = client_get(num, "ps.origin")
	local v = client_get(num, "ps.viewangles")
	if not o or not v then return nil end
	local vh = client_get(num, "ps.viewheight") or 32
	local f = view_forward_pitch_yaw(v)
	if not f then return nil end
	local muzzle = { o[1]+f[1]*16, o[2]+f[2]*16, o[3]+vh+f[3]*16 }
	local ok, ent = pcall(et.G_Spawn)
	if not ok or type(ent) ~= "number" then return nil end
	pcall(et.gentity_set, ent, "classname", "thrown_knife")
	pcall(et.gentity_set, ent, "s.eType", ET_MISSILE)
	pcall(et.gentity_set, ent, "s.weapon", weapon)
	pcall(et.gentity_set, ent, "r.ownerNum", num)
	pcall(et.gentity_set, ent, "s.pos", {
		trType = TR_GRAVITY, trTime = levelTime, trBase = muzzle,
		trDelta = { f[1]*THROW_SPEED, f[2]*THROW_SPEED, f[3]*THROW_SPEED + THROW_UP },
	})
	pcall(et.gentity_set, ent, "r.currentOrigin", muzzle)
	if type(et.trap_LinkEntity) == "function" then pcall(et.trap_LinkEntity, ent) end
	knives[ent] = { owner = num, weapon = weapon, last = muzzle, landed = nil }
	return ent
end

local function knife_give_back(num, weapon)
	pcall(et.AddWeaponToPlayer, num, weapon, 0, 1, 0)
	owed_knife[num] = nil
end

local function knife_free(ent)
	knives[ent] = nil
	if type(et.G_FreeEntity) == "function" then pcall(et.G_FreeEntity, ent) end
end

local function knife_hit_player(ent, k, victim, hitpos)
	local vo = client_get(victim, "ps.origin")
	local dmg = THROW_DAMAGE
	if vo and hitpos and hitpos[3] - vo[3] >= KNIFE_HEAD_HEIGHT then
		dmg = THROW_DAMAGE_HEAD
	end
	pcall(et.G_Damage, victim, k.owner, k.owner, dmg, 0, MOD_KNIFE)
end

-- ========================= EVENT HANDLERS ================================

-- runs every server frame
local function on_game_frame(levelTime)
	-- combine all per-frame work in one pcall so one feature's error
	-- doesn't kill the whole callback
	local ok, err = pcall(function()

	-- --- adrenaline: strip medics ---
	if ADRENALINE_ENABLE then
		for i = 0, get_client_slots() - 1 do
			if is_on_team(i) and class_of(i) == PC_MEDIC then
				adrenaline_strip(i)
			end
		end
	end

	-- --- disguise break ---
	if DISGUISE_BREAK_ENABLE then
		for i = 0, get_client_slots() - 1 do
			if not has_client(i) then
				last_weapon[i] = nil
			else
				local team = client_get(i, "sess.sessionTeam")
				local h    = client_get(i, "ps.stats", STAT_HEALTH)
				local wp   = client_get(i, "ps.weapon")
				if not team or team == TEAM_SPECTATOR or not wp
					or not h or h <= 0 then
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
							-- NOTE: covert_disguise_break uses yaw/pitch order
							if disguise_enemy_in_front(i, eye, view_forward_yaw_pitch(va)) then
								break_disguise(i)
							end
						end
					end
				end
			end
		end
	end

	-- --- kick projectiles ---
	if KICK_ENABLE then
		local nades, missiles, top_ent = {}, 0, -1
		for e = MAX_CLIENTS, MAX_ENTITIES - 1 do
			if et.gentity_get(e, "inuse") == 1 then
				top_ent = e
				if et.gentity_get(e, "s.eType") == ET_MISSILE then
					missiles = missiles + 1
					local wp = et.gentity_get(e, "s.weapon")
					if wp and KICKABLE_WEAPONS[wp] then
						local pos = et.gentity_get(e, "origin")
						if pos then nades[#nades+1] = { e, pos } end
					end
				end
			end
		end
		if DEBUG and (not last_kick_debug or levelTime - last_kick_debug >= 2000) then
			last_kick_debug = levelTime
			local pl = {}
			kick_collect_players(pl)
			log("debug kickables=" .. #nades .. " missiles=" .. missiles
				.. " top=" .. top_ent .. " players=" .. #pl)
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
							if dx*dx + dy*dy + dz*dz <= KICK_RANGE_SQ
								and pl.speed2 <= KICK_STATIONARY_SQ
								and kick_looking_at(pl, pos) then
								do_kick(p, pos, pl, levelTime)
								break
							end
						end
					end
				end
			end
		end
	end

	-- --- no-combat-selfkill: stillness tracking ---
	if NOKILL_ENABLE then
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
	end

	-- --- poison ticks ---
	if POISON_ENABLE then
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
				pcall(et.G_Damage, target, attacker, attacker,
					POISON_TICK_DAMAGE, DAMAGE_NO_KNOCKBACK, MOD_SYRINGE)
			end
		end
	end

	-- --- throwable knife flight / pickup ---
	if KNIFE_ENABLE then
		for ent, k in pairs(knives) do
			if et.gentity_get(ent, "inuse") ~= 1 then
				knives[ent] = nil
			elseif k.landed then
				if levelTime - k.landed >= KNIFE_LIFETIME_MS then
					knife_free(ent)
				else
					local pos = et.gentity_get(ent, "r.currentOrigin")
						or et.gentity_get(ent, "origin")
					if pos then
						for c = 0, get_client_slots() - 1 do
							if has_client(c) and is_alive(c) and team_of(c) then
								local o = client_get(c, "ps.origin")
								if o and dist2(o, pos) <= KNIFE_PICKUP_RANGE*KNIFE_PICKUP_RANGE then
									knife_give_back(c, k.weapon)
									knife_free(ent)
									break
								end
							end
						end
					end
				end
			else
				local pos = et.gentity_get(ent, "r.currentOrigin")
					or et.gentity_get(ent, "origin")
				if pos then
					local tr
					if type(et.trap_Trace) == "function" then
						local ok, t = pcall(et.trap_Trace, k.last, nil, nil, pos, ent, MASK_SHOT)
						if ok and type(t) == "table" then tr = t end
					end
					if tr then
						local hitent = tr.entityNum
						local frac   = tr.fraction or 1
						if type(hitent) == "number" and hitent < get_client_slots()
							and has_client(hitent) and is_alive(hitent)
							and hitent ~= k.owner then
							knife_hit_player(ent, k, hitent, tr.endpos or pos)
							knife_free(ent)
						elseif frac < 1 then
							local endpos = tr.endpos or pos
							pcall(et.gentity_set, ent, "s.pos", {
								trType = TR_STATIONARY, trTime = levelTime,
								trBase = endpos, trDelta = {0,0,0},
							})
							pcall(et.gentity_set, ent, "r.currentOrigin", endpos)
							k.landed = levelTime
						end
					end
					k.last = pos
				end
			end
		end
		for c, o in pairs(owed_knife) do
			if not has_client(c) then
				owed_knife[c] = nil
			elseif levelTime >= o.at then
				knife_give_back(c, o.weapon)
			end
		end
	end

	end)
	if not ok then err_once("runframe", err) end
end

-- player spawn (revived==0 means fresh spawn; also called after revive per
-- main.lua but only with revived=0 -- we still run on every spawn the engine
-- reports, which is safer for weapon grants)
local function on_player_spawn(clientId, revived)
	-- reset per-life state
	last_combat[clientId] = nil
	still_since[clientId] = nil
	last_origin[clientId]  = nil
	last_weapon[clientId]  = nil
	poison_cure(clientId, "spawn")
	owed_knife[clientId]   = nil
	next_throw[clientId]   = nil

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

	if SMG_SLOT2_ENABLE and GRANT_TEAM_SMG and cls == PC_SOLDIER then
		if not smg_of(clientId) then
			local s = TEAM_SMG[team_of(clientId)]
			if s then pcall(et.AddWeaponToPlayer, clientId, s, GRANT_SMG_AMMO, GRANT_SMG_CLIP, 0) end
		end
	end
end

local function on_client_disconnect(clientId)
	no_client[clientId]     = nil
	last_combat[clientId]   = nil
	still_since[clientId]   = nil
	last_origin[clientId]   = nil
	last_weapon[clientId]   = nil
	owed_knife[clientId]    = nil
	next_throw[clientId]    = nil
	poison_cure(clientId, "disconnect")
	for target, p in pairs(poisoned) do
		if p.attacker == clientId then p.attacker = target end
	end
end

-- client command (weapon-slot toggles + /kill block)
local function on_client_command(clientId, command)
	if type(command) ~= "string" then return 0 end

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
			if not knife_spawn(clientId, weapon, now) then return 0 end
			next_throw[clientId] = now + THROW_COOLDOWN_MS
			if not THROW_KEEP_KNIFE then
				pcall(et.RemoveWeaponFromPlayer, clientId, weapon)
				owed_knife[clientId] = { weapon = weapon, at = now + THROW_RETURN_AFTER_MS }
			end
			return 1
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

	last_kick = {}; kick_sound_index = 0; last_kick_debug = 0
	last_weapon = {}
	last_combat = {}; still_since = {}; last_origin = {}
	poisoned = {}
	knives = {}; owed_knife = {}; next_throw = {}

	if KICK_ENABLE and KICK_SOUND and type(et.G_SoundIndex) == "function" then
		local idx = et.G_SoundIndex(KICK_SOUND_FILE)
		if idx and idx ~= 0 then kick_sound_index = idx end
	end

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
end

-- ========================== REGISTRATION =================================

-- Register handlers with WolfAdmin's event bus. Return values are respected
-- by events.trigger, so onClientCommand returning 1 properly swallows
-- intercepted weapon-slot / /kill commands.
events.handle("onGameInit",        on_game_init)
events.handle("onGameFrame",       on_game_frame)
events.handle("onPlayerSpawn",     on_player_spawn)
events.handle("onClientDisconnect",on_client_disconnect)
events.handle("onClientCommand",   on_client_command)

-- onDamage / onWeaponFire are custom events fired from additions to main.lua
-- (see below); if they aren't added yet, add them.
if not events.get("onDamage") then       events.add("onDamage")       end
if not events.get("onWeaponFire") then  events.add("onWeaponFire")  end
events.handle("onDamage",      on_damage)
events.handle("onWeaponFire",  on_weapon_fire)

return gameplay
