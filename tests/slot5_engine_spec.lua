-- Slot-5 (poison needle <-> pliers) engine-fidelity tests.
--
-- tests/gameplay_spec.lua checks the *module's* bookkeeping: it asserts that
-- after "poisonneedle" the server-side ps.weapon reads 11 and then 21. That is
-- necessary but not sufficient - it never models what the ET engine does with
-- ps.weapon afterwards, so a toggle that the engine immediately undoes still
-- looks green.
--
-- This file adds the two engine pieces that decide whether slot 5 actually
-- changes weapon on a live server:
--
--   1. PM_Weapon()          (src/game/bg_pmove.c)
--      Every movement frame:
--          if ((weaponTime <= 0 || (!firing && weaponDelay <= 0)) && !delayedFire)
--              if (ps->weapon != cmd.weapon)
--                  PM_BeginWeaponChange(ps->weapon, cmd.weapon, qfalse);
--      cmd.weapon is the *client's* selection. So a server that writes
--      ps.weapon without the client agreeing gets reverted on the next frame.
--
--   2. CG_WeaponBank_f()    (src/cgame/cg_weapons.c)
--      The "weaponbank 5" key is a cgame console command (it is in the cgame
--      commands[] table, so it is consumed client-side and never forwarded to
--      the server). It cycles the owned+selectable weapons of bank 5 and sets
--      cg.weaponSelect, which is what feeds cmd.weapon.
--      Selectability is CG_WeaponSelectable(): the weapon bit must be set in
--      ps.weapons, and CG_WeaponHasAmmo() must pass - which is automatic for
--      WP_PLIERS but *not* for WP_MEDIC_SYRINGE, which needs a non-zero
--      ps.ammo[11] or ps.ammoclip[11].
--
-- Run with:   lua tests/slot5_engine_spec.lua [--verbose]

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

local cache = {}
function wolfa_requireModule(name)
	if cache[name] then return cache[name] end
	local chunk = assert(loadfile(ROOT .. name:gsub("%.", "/") .. ".lua"))
	local result = chunk()
	cache[name] = result or true
	return result
end

local function new_server(opts)
	cache = {}
	local engine = stub.new(opts)
	engine.install()
	local events = wolfa_requireModule("util.events")
	wolfa_requireModule("game.gameplay")
	events.trigger("onGameInit", 0, 0, false)
	return engine, events
end

local function client_command(engine, events, num, command)
	engine.parse_command(command)
	return events.trigger("onClientCommand", num, command)
end

-- ============================ engine model ================================

local WP_MEDIC_SYRINGE, WP_PLIERS = 11, 21
local WP_SMOKE_MARKER, WP_SMOKE_BOMB = 22, 29

-- weapBanksMultiPlayer[5] from src/cgame/cg_weapons.c
local BANK5 = { WP_MEDIC_SYRINGE, WP_PLIERS, WP_SMOKE_MARKER, WP_SMOKE_BOMB }

-- ammoIndex / clipIndex from the weaponTable[] rows in src/game/bg_misc.c.
-- Every bank-5 weapon self-references, and WP_MEDIC_ADRENALINE (44) shares the
-- syringe's pool.
local function pool_of(w) return w end

-- CG_WeaponHasAmmo(): WP_PLIERS is exempt from the ammo test, the syringe is
-- not (it is WEAPON_TYPE_SYRINGUE, not WEAPON_TYPE_MELEE).
local function cg_weapon_has_ammo(client, w)
	if w == WP_PLIERS then return true end
	local p = pool_of(w)
	return (client.ps.ammo[p] or 0) ~= 0 or (client.ps.ammoclip[p] or 0) ~= 0
end

-- CG_WeaponSelectable()
local function cg_weapon_selectable(engine, num, w)
	if not engine.has_weapon(num, w) then return false end
	return cg_weapon_has_ammo(engine.client(num), w)
end

-- A client, as far as weapon selection is concerned: cg.weaponSelect is the
-- only state, and it is what gets copied into every usercmd_t.
local function new_client_model(engine, num)
	local cl = { num = num, weaponSelect = engine.client(num).ps.weapon }

	-- CG_Respawn(): "cg.weaponSelect = cg.snap->ps.weapon"
	function cl.respawn()
		cl.weaponSelect = engine.client(num).ps.weapon
	end

	-- CG_WeaponBank_f() for bank 5: cycle the selectable weapons of the bank.
	function cl.press_bank5()
		local sel = {}
		for _, w in ipairs(BANK5) do
			if cg_weapon_selectable(engine, num, w) then sel[#sel + 1] = w end
		end
		if #sel == 0 then return false end
		for i, w in ipairs(sel) do
			if w == cl.weaponSelect then
				cl.weaponSelect = sel[(i % #sel) + 1]
				return true
			end
		end
		cl.weaponSelect = sel[1]
		return true
	end

	-- PmoveSingle()/PM_Weapon(): reconcile ps.weapon with the client's request.
	-- PM_FinishWeaponChange() refuses weapons the player does not own.
	function cl.pmove()
		local c = engine.client(num)
		if c.ps.weapon ~= cl.weaponSelect then
			if engine.has_weapon(num, cl.weaponSelect) then
				c.ps.weapon = cl.weaponSelect
			else
				c.ps.weapon = 0
			end
		end
	end

	return cl
end

-- --------------------------------- tests ---------------------------------

test("engineer spawn grants a needle the client can actually select", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	local cv = engine.client

	engine.connect(13, 1, 2)                  -- axis engineer
	engine.spawn(13)
	events.trigger("onPlayerSpawn", 13, false)

	check(engine.has_weapon(13, WP_PLIERS), "engineer owns the pliers")
	check(engine.has_weapon(13, WP_MEDIC_SYRINGE), "engineer was granted the needle")

	-- bg_classes.c gives the pliers startingAmmo 0 / startingClip 1, so an
	-- ammo-only ownership test would miss them. CG_WeaponHasAmmo() exempts the
	-- pliers anyway, but the syringe has no such exemption.
	check(cv(13).ps.ammo[WP_PLIERS] == 0, "pliers ship with 0 reserve ammo")
	check(cv(13).ps.ammoclip[WP_PLIERS] == 1, "pliers ship with a clip of 1")

	check(cg_weapon_selectable(engine, 13, WP_PLIERS),
		"CG_WeaponSelectable() accepts the pliers")
	check(cg_weapon_selectable(engine, 13, WP_MEDIC_SYRINGE),
		"CG_WeaponSelectable() accepts the granted needle (non-zero ammo/clip)")
end)

test("native slot-5 key cycles needle <-> pliers", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	local cv = engine.client

	engine.connect(13, 1, 2)
	engine.spawn(13)
	events.trigger("onPlayerSpawn", 13, false)

	local cl = new_client_model(engine, 13)
	cl.respawn()
	cl.pmove()
	check(cv(13).ps.weapon == 3, "engineer starts with the MP40 in hand")

	cl.press_bank5(); cl.pmove()
	check(cv(13).ps.weapon == WP_MEDIC_SYRINGE,
		"first slot-5 press selects the poison needle")

	cl.press_bank5(); cl.pmove()
	check(cv(13).ps.weapon == WP_PLIERS,
		"second slot-5 press selects the pliers")

	cl.press_bank5(); cl.pmove()
	check(cv(13).ps.weapon == WP_MEDIC_SYRINGE,
		"third slot-5 press cycles back to the needle")
end)

test("server-forced switch does not survive a movement frame", function()
	local engine, events = new_server({ sv_maxclients = 16 })
	local cv = engine.client

	engine.connect(13, 1, 2)
	engine.spawn(13)
	events.trigger("onPlayerSpawn", 13, false)

	local cl = new_client_model(engine, 13)
	cl.respawn()
	cl.pmove()
	local held = cv(13).ps.weapon

	check(client_command(engine, events, 13, "poisonneedle") == 1,
		"the poisonneedle command is intercepted")
	check(cv(13).ps.weapon == WP_MEDIC_SYRINGE,
		"ps.weapon reads as the needle immediately after the command")

	-- ...but the client never changed cg.weaponSelect, because "poisonneedle"
	-- is a custom verb: cgame forwarded it to the server and did not touch its
	-- own selection. PM_Weapon() reconciles ps.weapon back to cmd.weapon.
	cl.pmove()
	check(cv(13).ps.weapon == held,
		"PM_Weapon() reverts the forced switch to the client's selection")
end)

test("granting a weapon twice does not corrupt the load-out", function()
	-- COM_BitSet() is "|=". A stub that used "+" would carry into the next bit
	-- the second time a weapon was granted, which silently rewrote the whole
	-- load-out: the engineer lost the MP40/knife/pistol and gained phantom
	-- weapons. Every spawn re-grants weapons the player already owns, so this
	-- has to be idempotent.
	local engine, events = new_server({ sv_maxclients = 16 })

	engine.connect(13, 1, 2)
	engine.spawn(13)

	local before = {}
	for w = 0, 63 do before[w] = engine.has_weapon(13, w) end

	-- re-grant everything the player already has
	for w = 0, 63 do
		if before[w] then engine.add_weapon(13, w, 10, 1, 0) end
	end

	local same = true
	for w = 0, 63 do
		if engine.has_weapon(13, w) ~= before[w] then same = false end
	end
	check(same, "re-granting owned weapons leaves the load-out unchanged")

	-- and the spawn hook, which re-grants on top of the class load-out, must
	-- not drop anything the engine handed out
	events.trigger("onPlayerSpawn", 13, false)
	check(engine.has_weapon(13, 3), "engineer still has the MP40 after the spawn hook")
	check(engine.has_weapon(13, 1), "engineer still has the knife after the spawn hook")
	check(engine.has_weapon(13, WP_PLIERS), "engineer still has the pliers after the spawn hook")
end)

test("a needle with an empty pool would be unreachable", function()
	-- Regression guard for the selectability rule: if the grant ever leaves
	-- both pools at zero, CG_WeaponSelectable() rejects the needle and the
	-- slot-5 key cycles straight past it - the exact "poison doesn't come up
	-- on 5" symptom. The module must never produce that state.
	local engine, events = new_server({ sv_maxclients = 16 })
	local cv = engine.client

	engine.connect(13, 1, 2)
	engine.spawn(13)
	events.trigger("onPlayerSpawn", 13, false)

	local ammo = cv(13).ps.ammo[WP_MEDIC_SYRINGE] or 0
	local clip = cv(13).ps.ammoclip[WP_MEDIC_SYRINGE] or 0
	check(ammo > 0 or clip > 0,
		"the granted needle has a non-zero syringe pool")

	-- prove the negative case really is unreachable, so the guard has teeth
	cv(13).ps.ammo[WP_MEDIC_SYRINGE] = 0
	cv(13).ps.ammoclip[WP_MEDIC_SYRINGE] = 0
	check(not cg_weapon_selectable(engine, 13, WP_MEDIC_SYRINGE),
		"an empty needle is rejected by CG_WeaponSelectable()")

	local cl = new_client_model(engine, 13)
	cl.respawn()
	cl.press_bank5(); cl.pmove()
	check(cv(13).ps.weapon == WP_PLIERS,
		"with an empty needle the slot-5 key only ever finds the pliers")
end)

-- --------------------------------- report --------------------------------

print()
if #failures == 0 then
	print(checks .. " checks passed")
	os.exit(0)
end
print(#failures .. " of " .. checks .. " checks FAILED")
for _, f in ipairs(failures) do print("  - " .. f) end
os.exit(1)
