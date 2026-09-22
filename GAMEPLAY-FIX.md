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

## 8. Follow-up: "throw knife and /kill in combat not working"

Two features, five distinct causes. Neither was reachable from the existing
specs, and both were partly hidden by the test harness rather than by the
module: `tests/gameplay_spec.lua` loaded `game/gameplay.lua` on its own, and
`tests/et_stub.lua` answered "yes" to two engine calls that decide everything.

### 8.1 `/kill`: three causes stacked on top of each other

**(a) `events.trigger()` kept the first non-nil answer.** `main.lua` requires
`commands.commands` (line 138) before `game.gameplay` (line 143), so
`commands.onClientCommand()` is handler #1 on the bus - and it ends in an
unconditional `return 0` (`commands/commands.lua:349`). `et_ClientCommand()`
returns whatever `events.trigger()` returns (`main.lua:189`), so that 0 went
straight back to `ClientCommand()`, which runs `G_LuaHook_ClientCommand()`
*before* its dispatch table (`g_cmds_ext.c`) and then calls `Cmd_Kill_f()`
(registered as `"kill"` in `g_cmds.c`) as usual. The gameplay module's
`return 1` was computed correctly and thrown away.

`events.trigger()` now prefers a *blocking* answer (non-nil, not `false`, not
`0`) over a non-blocking one, and walks handlers with `ipairs()` so registration
order is guaranteed (`events.handle()` uses `table.insert`; `pairs()` left the
order to the implementation). This is what makes every interception in this
module work - slot 7, slot 5, slot 2 and `/kill` alike.

**(b) Two clocks.** `still_since[]` was written from `levelTime` (the argument
`et_RunFrame()` passes) but `is_stuck()` compared it against `now_ms()`, which
read `et.trap_Milliseconds()` - the *process* uptime, minutes ahead of level
time on a live server. So `now - still_since >= STUCK_GRACE_MS` was true for
anyone who stood still for a moment, and `is_stuck()` returning true means
"let them `/kill`": the handler bailed out with `return 0` before the combat
window was ever looked at. The same mixing broke the poison needle - `expires`
and `next_tick` came from `now_ms()` while `on_game_frame()` compares them
against `levelTime`, so poison was applied and then never ticked.

The module now keeps one clock: `frame_time`, set at the top of
`on_game_frame()`, and `now_ms()` returns it. The two clocks are only ever
equal inside the test stub, which is why the suite never saw this.

**(c)** Only after (a) and (b) does the rule itself run. The rule is unchanged:
blocked for `COMBAT_WINDOW_MS` after damage between enemies, or while an enemy
within `SIGHT_RANGE` and inside the cone has line of sight; free for a player
who has not moved for `STUCK_GRACE_MS`, who is dead, or who is not on a team.

### 8.2 The throwable knife: `et.G_Spawn()` does not exist

`g_lua.c`'s `etlib[]` table has no `G_Spawn`. The module called it anyway, the
call raised, the `pcall` swallowed it, and the throw silently did nothing -
while `tests/et_stub.lua` invented an `et.G_Spawn()`, so the feature looked
implemented and tested. The only entity constructor Lua gets is
`et.G_CreateEntity("<spawn vars>")`, which feeds the string to
`G_SpawnGEntityFromSpawnVars()`. Rewriting the feature around it meant working
out, from the engine sources, everything the API does *not* do for you:

- **classname.** An unknown one makes `G_CallSpawn()` fail and the entity is
  freed again - but `G_CreateEntity()` still returns the number. The knife uses
  `target_position`, whose spawn function is a single `G_SetOrigin()`
  (`g_target.c`), so it comes back inert: no think function, no model, no
  contents. `knife.create()` checks `inuse` before tracking the entity, and
  `on_game_frame()` re-checks `inuse` *and* the classname every frame, so a slot
  the engine gave up (a map script, another mod) is dropped instead of being
  freed a second time.
- **movement.** Lua cannot install a think function, so the module has to be
  the knife's `G_RunMissile()` (`g_missile.c`): evaluate the trajectory, trace
  from the last position to the new one, write `r.currentOrigin`,
  `trap_LinkEntity()`. `SV_LinkEntity()` reads `r.currentOrigin` only, so an
  entity Lua links once and never touches again does not move.
- **the arc.** `s.pos` is written as `TR_GRAVITY` and mirrored in
  `knife.position()`: `base + delta*t - 0.5*800*t^2`. `BG_EvaluateTrajectory()`
  uses a fixed `DEFAULT_GRAVITY` for `TR_GRAVITY` ("FIXME: local gravity..." in
  `bg_misc.c`), *not* `g_gravity`, so the client's `CG_CalcEntityLerpPositions()`
  draws exactly where the server traces.
- **visibility.** `s.weapon` is `FIELD_FLAG_READONLY`, so the old `ET_MISSILE`
  write always failed (inside a `pcall`) and the knife in flight was invisible:
  `CG_Missile()` picks its model from `s.weapon`. It is `ET_GENERAL` (0) with
  `s.modelindex` from `et.G_ModelIndex()` on the `itemTable[]` paths
  (`models/multiplayer/knife/knife.md3`, `models/multiplayer/knife_kbar/knife.md3`),
  which is what `CG_General()` draws out of `cgs.gameModels[]`. Orientation goes
  to `s.apos`, because `CG_CalcEntityLerpPositions()` evaluates `s.pos`/`s.apos`
  and never looks at `s.angles`.
- **collision.** `et.trap_Trace(last, mins, maxs, new, passent, mask)` with
  `passent` = **the thrower** and `MASK_MISSILESHOT`. Passing the knife entity
  made the trace start inside the thrower's bounding box (`startsolid`) and the
  knife land on the spot it was thrown from.
- **damage.** `et.G_Damage(victim, thrower, thrower, damage, 0, mod)` with
  `MOD_KNIFE` (5) for the axis knife and `MOD_KNIFE_KABAR` (61) for the allies'.
- **headshots.** The engine's head box (`G_BuildHead()`, `g_combat.c`) sits at
  `origin + ps.viewheight` - 40 standing, `DEFAULT_VIEWHEIGHT` - with mins z -2,
  so it starts 38 units above the origin. `KNIFE_HEAD_HEIGHT` was 46, i.e. the
  top two units of the 72-unit player box: headshots were effectively
  unreachable. The victim's own `ps.viewheight - 2` is now used when it can be
  read (so a crouching player is still headshottable, `CROUCH_VIEWHEIGHT` 16),
  with 38 as the fallback.
- **ammo.** `weaponTable[]` gives both knives `useAmmo`/`useClip = qfalse` and
  `CG_WeaponHasAmmo()` exempts `WEAPON_TYPE_MELEE`, so neither the engine nor
  the client ever looks at the knife's `ps.ammo`/`ps.ammoclip` - it is free to
  count throws with. `knife.grant_clip()` preserves the class load-out's reserve
  (`bg_classes.c`: startingAmmo 1, startingClip 0) instead of zeroing it,
  because `et.AddWeaponToPlayer()` *assigns* both pools.
- **entity slots.** `G_Spawn()` calls `G_Error()` - the server goes down - when
  the pool is empty, so live knives are capped at `KNIFE_MAX_LIVE` (the oldest
  is freed to make room) and every knife is freed on hit, on landing timeout, on
  pickup and on lifetime, in flight as well as landed. The old code leaked every
  knife that never hit anything.
- **teammates.** `G_Damage()` refuses a same-team target unless the server
  turned `g_friendlyFire` on (`g_combat.c:1627`), so hitting a friendly would
  spend the knife for nothing and make throwing it in a group useless. A trace
  that stops on a body which is not a target is continued from the hit point
  with that body as the new `passent`: the knife flies through teammates,
  corpses and spectators, and never sticks in one.
- **Lua versions.** `math.atan2` is gone in 5.3+ and `math.atan(y, x)` does not
  exist in the LuaJIT/5.1 builds ET:Legacy can be compiled with;
  `knife.angles_of()` supports both.
- **200 locals.** Lua allows 200 local variables per function, main chunk
  included, and `game/gameplay.lua` is at that limit - which is why the whole
  feature (ten constants and twenty functions) hangs off a single `knife` table,
  the same trick the `fields` table in section 2.1 uses.

### 8.3 The harness had to stop lying first

`tests/et_stub.lua`:

- `et.G_Spawn()` is gone. Modelled instead: `et.G_CreateEntity()` (real
  spawn-var parsing, slot reuse from `MAX_CLIENTS` like `G_Spawn()`, and
  `G_CallSpawn()` freeing an entity whose classname has no spawn function),
  `et.G_ModelIndex()` (CS_MODELS allocation), `et.G_FreeEntity()` (memset,
  `classname = "freed"`), `et.trap_LinkEntity()`.
- `et.trap_Trace()` was "hit nothing" for every call. It now sweeps the segment
  against `engine.world` (`stub.add_wall()`) and every live client's
  `playerMins`/`playerMaxs` box, expanding the target by the trace extents the
  way `CM_BoxTrace()` does, honouring the mask (CONTENTS_BODY alive,
  CONTENTS_CORPSE dead) and skipping the `passent`. The invented
  `MASK_SHOT = 0x100000` is replaced by the real
  `CONTENTS_SOLID|CONTENTS_BODY|CONTENTS_CORPSE`, and `MASK_MISSILESHOT` is
  exposed so the module stops falling back to its own default.
- `ps.viewheight` is `DEFAULT_VIEWHEIGHT` (40), not 32; `s.modelindex`,
  `s.angles`, `s.apos`, `r.mins`, `r.maxs`, `r.contents`, `clipmask` are in the
  field table, with `s.number`/`r.linked` read-only to Lua as in `g_lua.c`.
- `stub.wolfadmin_client_command()` stands in for `commands.onClientCommand()`
  and is registered first, like `main.lua` does. The real module cannot be
  loaded in a unit test: it needs `wolfa_requireLib("toml")` from the engine's
  lua lib path, the admin settings files and a sqlite database.
- `tests/gameplay_spec.lua`'s `new_server()` registers that handler too, so the
  existing 38 checks now also guard the return-value fix - 9 of them fail on an
  `events.trigger()` that keeps the first non-nil answer.

### 8.4 Tests

`tests/knife_kill_spec.lua` - 126 checks over ten tests: `/kill` in the combat
window and after it, the sight rule with and without a wall in the way, the
stuck grace period, the frame clock against a process clock nine minutes ahead
(including poison ticking on schedule), the throw itself and every field the
client needs to see it, the flight against `BG_EvaluateTrajectory()`, body and
headshot damage with the right MOD per team, teammates and corpses, landing,
pickup, a full clip, the lifetime, the cooldown, an empty clip falling through
to the melee stab, the `KNIFE_MAX_LIVE` cap, and a slot the engine took back.

Each cause was verified by mutating the fixed code and re-running; every
mutation reports a clean failure list rather than a crash:

| mutation (the pre-fix behaviour) | failing checks |
| --- | --- |
| `events.trigger()` keeps the first non-nil return | 8 (+9 in `gameplay_spec`) |
| `now_ms()` = `et.trap_Milliseconds()` | 26 |
| stub provides `et.G_Spawn()` instead of `et.G_CreateEntity()` | 71 |
| `KNIFE_HEAD_HEIGHT = 46`, no `ps.viewheight` | 1 |
| no pass-through trace (knife hits teammates) | 2 |
| no `inuse`/classname check on a created entity | 1 |
| no `KNIFE_MAX_LIVE` cap | 2 |
| trace `passent` = the knife entity | 1 |
| no `s.apos` (nothing animates client-side) | 1 |
| no `s.modelindex` (invisible in flight) | 1 |
| `knife.grant_clip()` zeroes the reserve pool | 1 |

Full suite: `gameplay_spec` 38, `slot5_engine_spec` 20, `honors_spec` 34,
`knife_kill_spec` 126 - 218 checks, all passing.
