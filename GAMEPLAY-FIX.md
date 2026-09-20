# Fix: `client slot N has no client fields (tried to get invalid gentity field "ps.weapons")`

The server log repeated, for one player after another:

```
[wolfadmin:gameplay] warning: client slot 3 has no client fields
  (tried to get invalid gentity field "ps.weapons") - skipping it for this map
```

Slots 3, 5, 11 and 13 were named one after the other, and every gameplay
feature of the module stopped working for those players: no throwable knife, no
poison needle, no slot-2 SMG switch, no slot-5/slot-7 toggles, no
disguise-break, no no-combat-selfkill protection.

## 1. Root cause: `ps.weapons` does not exist in ET:Legacy's Lua field table

`et.gentity_get()` resolves field names against the engine's own tables in
`src/game/g_lua.c` (`gclient_fields` / `gentity_fields`). A full inventory of
that file shows **126 client fields and 108 gentity fields**. `ps.weapon` and
`ps.weaponstate` are there; **`ps.weapons` is not** - on any release from v2.76
through v2.82 and master. Every `"ps.weapons"` occurrence in the engine sources
is an internal `COM_BitSet`/`COM_BitClear` call on the C struct, and one is a
substring match inside `ps.weaponstate`.

An unknown name makes the lookup raise
`tried to get invalid gentity field "ps.weapons"` - **the exact same error a
slot with no `gclient_t` produces**, because the field table is only scanned
while `ent->client` is set. The module could not tell the two situations apart,
so one failed weapon-mask read was enough to mark that player as an empty slot
and skip them for the rest of the map.

The fix reads what ET:Legacy actually exposes; nothing in the gameplay features
was dropped.

## 2. What changed in `game/gameplay.lua`

### 2.1 The engine's field table is probed once per map (`fields.probe()`)

All 17 field names the module uses are read once on slot 0, which always owns
a `gclient_t`: `G_InitGame()` assigns `g_entities[i].client = level.clients + i`
for `i < level.maxclients` and calls the Lua init hook (`G_LuaHook_InitGame`)
only near the end of the same function, so the clients are in place long before
`onGameInit` fires. The result is kept in `fields.ok`.

- A field the engine does not have is now dropped for the whole map and logged
  as **one** informational line, instead of being mistaken for an empty slot:
  `client fields not exposed by this engine: ps.weapons, ...` - and the module
  says which mechanism replaces it.
- `client_get()` returns `nil` for such a field instead of aborting.
- A slot is only reported as empty when the engine really has no client data
  for it (`pers.connected` unreadable, `inuse` invalid, no `gclient_t` ...).

The per-slot `no_client` suppression semantics are unchanged otherwise: it is
set once, the slot is skipped while it is empty, the message is logged once per
slot per map, and connect/begin/spawn/disconnect, client commands and damage
clear it again. `on_game_init` still resets `no_client`, `reported_errors` and
re-probes the fields.

### 2.2 Weapon ownership without a weapon bitmask

`has_weapon()` now works in two modes. When the engine exposes `ps.weapons`
(hypothetically - none of the checked releases do), the bitmask is used, exactly
as before. Otherwise ownership is decided by, in order:

1. `ps.weapon` - the weapon the player has in hand right now;
2. the class load-out fields - `sess.playerWeapon`, `sess.playerWeapon2`,
   `sess.latchPlayerWeapon`, `sess.latchPlayerWeapon2`. These are the weapons
   the player picked in the limbo menu and `SetWolfSpawnWeapons()`
   (`g_client.c`) grants exactly that load-out, so no extra ownership check is
   needed;
3. a non-empty ammo pool - `SetWolfSpawnWeapons()` adds every owned weapon
   through `AddWeaponToPlayer()`, which fills `ps.ammo[ammoIndex]` and
   `ps.ammoclip[clipIndex]`, and `bg_classes.c` gives even the weapons that use
   no ammo (knife, pliers, mines...) a starting clip of 1.

The only false negative is a weapon that is completely out of ammo **and** not
part of the load-out - and such a weapon cannot be used by any of the toggles
anyway.

### 2.3 Ammo pools are indexed the way the engine indexes them (`AMMO_POOL`)

`ps.ammo`/`ps.ammoclip` are indexed by `ammoIndex`/`clipIndex` from the weapon
table (`bg_misc.c`), not by weapon number: the side arms share the base
weapon's pool, and **the adrenaline shot shares the medic syringe's pool**. All
pistol-pool reads and both "does this weapon still have ammo" checks now go
through `AMMO_POOL`.

This was a second, independent bug: with the old code the adrenaline shot
(`WP_MEDIC_ADRENALINE`, 44) and the poison needle (`WP_MEDIC_SYRINGE`, 11)
were read from different pool indices, so an engineer holding the adrenaline
could appear to have a needle and vice versa.

### 2.4 `syringe_grant()` no longer trusts an occupied pool

Because adrenaline and syringe share a pool, "the syringe pool is not empty" is
not proof that the player has a needle - and `adrenaline_grant()` runs before
`syringe_grant()` on every spawn. Medics, who carry the needle as a class
weapon, are now skipped by class (`PC_MEDIC`) and everyone else gets the
needle, with the existing pool values kept when the player already had one.

### 2.5 SMG slot 2 with the light-weapons skill

`sess.playerWeapon2` is the SMG when a soldier buys light weapons
(`classSecondaryWeapons` in `bg_classes.c`). `smg_of()` now scans all four
load-out fields instead of only `sess.playerWeapon`.

### 2.6 `smg_select()`: the slot-2 switch never actually switched the weapon

`ps.weapon` and `ps.weaponstate` are `FIELD_FLAG_READONLY` in `g_lua.c`, so
`et.gentity_set()` refuses both with `tried to set read-only gentity field`.
The old code wrapped the writes in `pcall`, which silently swallowed that error
- the SMG slot-2 command answered and did nothing. It now uses the engine's own
helper, `et.AddWeaponToPlayer(num, w, ammo, clip, 1)`, feeding it the pools the
player already has (that helper *assigns* the pools, so current values are
passed back unchanged) and `setcurrent = 1` to put the weapon in hand.
`ps.weaponstate` needs no write; the engine raises the weapon itself.

## 3. Related fix: `commands/admin/stats.lua`

The non-legacy stat branch read `sess.suicides`, which is not a registered
field either (the module and the legacy branch use `sess.self_kills`). Changed
to `sess.self_kills`. On ET:Legacy the legacy branch normally runs, but a
server with a `fs_game` outside the legacy list would have hit the same
"invalid gentity field" error.

## 4. Regression tests

New in `tests/`:

- `tests/et_stub.lua` - an engine stub that follows the real code paths:
  `g_lua.c` field lookup (unknown field or no `gclient_t` => the exact engine
  error messages), the read-only flags, ammo/clip indices from `bg_misc.c`,
  starting load-outs from `bg_classes.c`, `ps.weapons` exposed only via the
  `expose_weapon_mask` option, and the Lua-side semantics of
  `et.AddWeaponToPlayer` (assignment, not addition; refuses clientless slots).
  Also models `G_InitGame()`: every slot below `level.maxclients` owns a
  `gclient_t` from map start.
- `tests/gameplay_spec.lua` - 38 checks in three groups:
  - ET:Legacy field table (no `ps.weapons`): the reported symptom itself - four
    clients spawn in one frame, no slot is reported empty, no field errors, and
    the throwable knife, poison needle, togglemine and poisonneedle features
    all keep working for them, including a reconnect.
  - Engine with `ps.weapons` bitmask: the bitmask path still wins over the
    fallback (removing the landmine while leaving its ammo pool filled).
  - Slots without client data: reported exactly once per map, never per frame,
    and the other players are unaffected.

Results: **38/38 pass on the fixed code; 24/38 fail on the previous code**, so
the suite really covers this bug. Run it from the repository root with
`lua tests/gameplay_spec.lua` (add `--verbose` for per-check output);
Lua 5.3 and Lua 5.4 both work. All 153 Lua files in the tree still
compile.

## 5. What the server log will look like now

Once per map, in place of the repeating warnings:

```
[wolfadmin:gameplay] client fields not exposed by this engine: ps.weapons
[wolfadmin:gameplay] ps.weapons is not exposed by this engine - weapon ownership
  is read from the load-out and the ammo pools instead
```

A slot without client data still produces the "has no client data" line, once
per slot per map, with the engine's own reason.

## 6. Known limitation, unrelated to this report but found while auditing

`knife_spawn()` still tries `et.gentity_set(ent, "s.weapon", weapon)` on the
thrown-knife entity. Like `ps.weapon`, `s.weapon` is `FIELD_FLAG_READONLY` in
`g_lua.c`, so that write is refused and the surrounding `pcall` hides the
error. Everything else about the thrown knife works - the entity is spawned,
linked, tracked, damages on hit and is picked back up through the `knives`
table - but a client picks the missile's model from `s.weapon`, so the knife in
flight may not be drawn (not verified live; the same line exists in the
pre-fix code).

Giving it a visible model would mean a field the engine does allow Lua to write
(`s.modelindex` with `s.eType = ET_GENERAL`) or a new engine helper. Both change
rendering behaviour and need a live test, so they were left out of this fix.

## 7. Follow-up: "the engineer's poison needle and pliers don't change on slot 5"

Reported separately. Verified against the ET:Legacy sources; there are three
distinct issues, only one of which is a bug in the module.

### 7.1 `weaponbank 5` never reaches the server

`weaponbank` is in the cgame `consoleCommand_t commands[]` table
(`src/cgame/cg_consolecmds.c`), alongside `weapon`, `weapnext`, `weapprev`,
`weapalt` and friends. `CG_ConsoleCommand()` walks that table and returns
`qtrue` on a match, so the command is consumed **client-side** and is never
forwarded to qagame. `et_ClientCommand()` therefore never sees it.

So the `weaponbank`/`weaponslot` branches in `is_slot5_command()` (and the
slot-2/slot-7 twins) could only ever fire for a hand-typed `\weaponbank 5` -
and cgame eats even that. The earlier note in section 5 claiming a working
"weaponbank-2 feature" was wrong; that line has been corrected. The dead
matching has been removed from `is_slot5_command()` and replaced with a comment
recording why.

The real slot-5 keypress is handled entirely inside `CG_WeaponBank_f()`, which
cycles the bank locally and sets `cg.weaponSelect`. Nothing is sent to the
server.

### 7.2 A server-forced weapon switch does not survive one movement frame

`ps.weapon` is `FIELD_FLAG_READONLY` to Lua, so the only way to force a switch
is `et.AddWeaponToPlayer(..., setcurrent = 1)`. That write does not hold.
`PM_Weapon()` in `src/game/bg_pmove.c` runs, every frame:

```c
if ((pm->ps->weaponTime <= 0 || (!weaponstateFiring && pm->ps->weaponDelay <= 0)) && !delayedFire)
{
    pm->ps->viewlocked = VIEWLOCK_NONE;
    if (pm->ps->weapon != pm->cmd.weapon)
    {
        PM_BeginWeaponChange(pm->ps->weapon, pm->cmd.weapon, qfalse);
    }
}
```

`cmd.weapon` is the client's own selection. The Q3/ET protocol has no
"stufftext" and no cgame server-command that sets it, so a server cannot move
`cg.weaponSelect`; the forced switch is reverted as soon as the next usercmd
arrives. `tests/slot5_engine_spec.lua` models this and asserts the revert.

This is why a Lua-side toggle can look correct in a server-side test (the value
of `ps.weapon` really does change) and still do nothing visible in game.

### 7.3 The actual bug: a needle the client refuses to select

`CG_WeaponSelectable()` rejects a weapon unless the bit is set in `ps.weapons`
**and** `CG_WeaponHasAmmo()` passes:

```c
if ((GetWeaponTableData(weapon)->type & WEAPON_TYPE_MELEE) || weapon == WP_PLIERS)
    return qtrue;
if (!ps->ammo[GetWeaponTableData(weapon)->ammoIndex] &&
    !ps->ammoclip[GetWeaponTableData(weapon)->clipIndex])
    return qfalse;
```

`WP_PLIERS` is exempt. `WP_MEDIC_SYRINGE` is **not** - it is
`WEAPON_TYPE_SYRINGUE`, not `WEAPON_TYPE_MELEE`. So a needle granted with both
pools at zero is owned but unselectable, and the slot-5 key cycles straight
past it: the engineer presses 5 and only ever gets the pliers. That is exactly
the reported symptom.

`syringe_grant()` now guarantees at least one charge before granting, so the
needle is always reachable regardless of how `SYRINGE_AMMO` /
`SYRINGE_AMMOCLIP` are configured. `bank5_has_ammo()` was also rewritten to
mirror `CG_WeaponHasAmmo()` exactly (pliers exempt, pool looked up through
`AMMO_POOL`) instead of special-casing the syringe and adrenaline.

Note that the bank-5 items other than the medic's own syringe ship with
`startingAmmo 0, startingClip 1` (`bg_classes.c`), so any "does the player have
this?" test based on `ps.ammo[pool] > 0` alone reports them missing - the
signal is in `ps.ammoclip`.

### 7.4 A bug in the test harness that was hiding all of this

`tests/et_stub.lua` implemented `COM_BitSet` with `+` instead of `|=`. Granting
a weapon the player already owned carried into the neighbouring bit and
silently rewrote the load-out: an axis engineer who should own
`1 2 3 4 16 21 26` came out of the spawn hook owning `5 11 16 21 26 44` - no
MP40, no knife, no pistol, plus a phantom weapon 5. Since every spawn re-grants
weapons the player already has, this corrupted essentially every load-out in
the suite while still reporting 38/38 green.

Fixed to be idempotent, like the engine macro. `tests/slot5_engine_spec.lua`
covers it directly.

### 7.5 Tests

`tests/slot5_engine_spec.lua` - 20 checks. It models the two engine pieces that
decide the outcome (`PM_Weapon()`'s reconciliation and `CG_WeaponBank_f()`'s
bank cycling via `CG_WeaponSelectable()`), then asserts that a stock slot-5
keypress cycles needle -> pliers -> needle for an engineer. Verified to fail on
the pre-fix code: 3/20 fail with the old `bit_set`, and 6/20 fail if the
zero-pool guard in `syringe_grant()` is removed.
