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

Two features. `/kill` needed two fixes: one is the reason it never worked at
all, the other is a defect that breaks it - and the poison needle with it - on
any server whose clock is not the default one. The knife needed a rewrite,
because it was built on an engine function that does not exist.

Neither was reachable from the existing specs, and both were hidden by the test
harness rather than by the module: `tests/gameplay_spec.lua` loaded
`game/gameplay.lua` on its own, and `tests/et_stub.lua` answered "yes" to two
engine calls that decide everything.

### 8.1 `/kill`: the reason it never worked, plus a second defect

**(a) `events.trigger()` kept the first non-nil answer.** `main.lua` requires
`commands.commands` (line 137) before `game.gameplay` (line 143), so
`commands.onClientCommand()` is handler #1 on the bus - and it ends in an
unconditional `return 0` (`commands/commands.lua:349`). `et_ClientCommand()`
returns whatever `events.trigger()` returns (`main.lua:191`), so that 0 went
straight back to `ClientCommand()`, which runs `G_LuaHook_ClientCommand()`
*before* its dispatch table (`g_cmds_ext.c`) and then calls `Cmd_Kill_f()`
(registered as `"kill"` in `g_cmds.c`) as usual. The gameplay module's
`return 1` was computed correctly and thrown away.

`events.trigger()` now prefers a *blocking* answer (non-nil, not `false`, not
`0`) over a non-blocking one, and walks handlers with `ipairs()` so registration
order is guaranteed (`events.handle()` uses `table.insert`; `pairs()` left the
order to the implementation). This is what makes every interception in this
module work - slot 7, slot 5, slot 2 and `/kill` alike.

**(b) A second defect in the same handler: two clocks.** `still_since[]` was
written from `levelTime` (the argument `et_RunFrame()` passes) but `is_stuck()`
compared it against `now_ms()`, which read `et.trap_Milliseconds()`. Those two
readings are equal only by coincidence:

| reading | source | when it resets |
| --- | --- | --- |
| `level.time` | `sv.time`, handed to `GAME_INIT`/`GAME_RUN_FRAME` (`sv_game.c:788`, `sv_main.c:1580`) | carried across map changes (`sv_init.c:656`); reset to 0 only with `sv_serverTimeReset 1` (`sv_init.c:812`, default `0`) or on the 23-day wraparound (`sv_main.c:1694`) |
| `et.trap_Milliseconds()` | `Sys_Milliseconds()` (`sv_game.c:447`) | never - wall clock since the server process started |

On a stock server the two track each other, so this is **not** what made `/kill`
fail - (a) did, on every server. It is a live bug on any server that sets
`sv_serverTimeReset 1`, where `level.time` starts again at 0 on every map while
`trap_Milliseconds()` is already hours ahead. There, `now - still_since >=
STUCK_GRACE_MS` is true for every player who stands still for a single frame,
and `is_stuck()` answering true means "let them `/kill`", so the handler
returned `0` before the combat window was ever looked at. The same mix-up the
other way round made the poison needle's `expires`/`next_tick` unreachable:
poison was applied, then never ticked and never wore off.

The module now keeps one clock: `frame_time`, set at the top of
`on_game_frame()`, with `now_ms()` returning it. Nothing in `game/gameplay.lua`
reads `et.trap_Milliseconds()` any more, so no comparison depends on the two
readings happening to agree.

The rule itself is unchanged: blocked for `COMBAT_WINDOW_MS` after damage
between enemies, or while an enemy within `SIGHT_RANGE` and inside the cone has
line of sight; free for a player who has not moved for `STUCK_GRACE_MS`, who is
dead, or who is not on a team.

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
stuck grace period, the frame clock against a process clock nine minutes ahead - the
`sv_serverTimeReset 1` case - including poison ticking on schedule, the throw itself and every field the
client needs to see it, the flight against `BG_EvaluateTrajectory()`, body and
headshot damage with the right MOD per team, teammates and corpses, landing,
pickup, a full clip, the lifetime, the cooldown, an empty clip falling through
to the melee stab, the `KNIFE_MAX_LIVE` cap, and a slot the engine took back.

Each cause was verified by mutating the fixed code and re-running; every
mutation reports a clean failure list rather than a crash:

| mutation (the pre-fix behaviour) | failing checks |
| --- | --- |
| `events.trigger()` keeps the first non-nil return | 8 (+9 in `gameplay_spec`) |
| `now_ms()` = `et.trap_Milliseconds()`, clocks apart (`sv_serverTimeReset 1`) | 26 |
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

### 8.5 The same mix-up elsewhere in the tree (audited, not changed here)

Two admin commands write a timestamp that the *engine* compares against
`level.time`, and they take it from `et.trap_Milliseconds()`:

- `commands/admin/burn.lua:83-84` - `s.onFireStart` / `s.onFireEnd`
- `commands/admin/firegod.lua:85,103-104` - the same two fields; its toggle-off
  writes `s.onFireEnd = now` to extinguish the player

`ClientThink()` burns a player while `ent->s.onFireEnd > level.time`
(`g_active.c:206`) and `CopyClientBody()` makes the same comparison
(`g_client.c:686`). On a stock server (`sv_serverTimeReset 0`) the readings agree
and both commands behave. With `sv_serverTimeReset 1`, `!burn` writes an
`onFireEnd` that is hours ahead of `level.time`, so the victim keeps taking
flamethrower damage for the rest of the server's uptime instead of six seconds -
and `!firegod`'s "extinguish" leaves the flames on, because the value it writes
is still larger than `level.time`.

The fix has the same shape as the one in this module: keep `level.time` in one
place (`main.lua:201` already hands it to `onGameFrame`, and `util/timers.lua:87`
already receives it) and use that for anything the engine reads back. It was not
part of that change, which was confined to `game/gameplay.lua`, `util/events.lua`
and the tests - it is done now, in section 9.1, together with three more defects
the same audit turned up.

Checked and **not** affected: `util/timers.lua` (its start and its comparison
both come from `trap_Milliseconds()`, so the interval is a duration inside one
clock) and `game/honors.lua:463` (the same, for its snapshot interval).
`util/logs.lua:85` labels log lines with `trap_Milliseconds() / 1000` as though
it were map time - cosmetic, and only wrong under the same cvar.

## 9. Follow-up: "double check the others and fix"

Section 8.5 named two commands that mixed the engine's two clocks and left them
alone. This is the rest of that audit: every `et.gentity_set()`, `et.G_Damage()`
and timestamp write in `commands/`, `game/`, `admin/`, `players/`, `auth/` and
`util/`, read against the field tables and the setter in `g_lua.c` rather than
against what the code intends. Four defects came out of it, all of them silent on a
running server. A fifth suspicion - that the chat commands WolfAdmin sends its
messages through do not exist in ET:Legacy at all - turned out to be wrong, and is
written up in 9.5 anyway, because it looks wrong at first glance and cost a while to
settle.

| # | defect | files | effect before the fix |
|---|--------|-------|-----------------------|
| 9.1 | timestamps written from the process clock into fields the engine compares against `level.time` | `commands/admin/burn.lua`, `commands/admin/firegod.lua` | fire that does not stop when it should |
| 9.2 | `FIELD_VEC3` written as three calls with a component index | `commands/admin/freeze.lua`, `throw.lua`, `throwall.lua` | an uncaught Lua error; `!freeze`, `!throw`, `!fling`, `!launch`, `!throwa`, `!flinga`, `!launcha` did nothing at all |
| 9.3 | `!freeze` had no way to stop a player even with 9.2 fixed | `commands/admin/freeze.lua` | a "frozen" player walked away |
| 9.4 | `et.G_Damage()` called with entity number 1024 as "nobody" | `commands/admin/burn.lua`, `gib.lua`, `giba.lua`, `lol.lua`, `nade.lua`, `poison.lua` | a pointer one `gentity_t` past the end of `g_entities[]` |

### 9.1 Two clocks: `level.time` and `Sys_Milliseconds()`

`et_RunFrame(levelTime)` is `G_RunFrame(int levelTime)` (`g_main.c:4594`), which
does `level.time = levelTime` (`g_main.c:4635`) and reaches the game module
through `vmMain`'s `GAME_RUN_FRAME` case (`g_main.c:216-220`). The number the
server passes is its own `svs.time`, which `sv_serverTimeReset` restarts at every
map change (`sv_init.c:656`, `:812`, cvar registered at `:1232`, default `"0"`)
and which the same code restarts once `sv.time` passes `0x70000000` - about
23 days of uptime - even when the cvar is 0.

`et.trap_Milliseconds()` is `Sys_Milliseconds()`: the process clock. On a stock
server the two readings agree, which is why nothing looked broken. With
`sv_serverTimeReset 1` the level clock starts again at each map while the process
clock keeps counting, so a value stamped from `trap_Milliseconds()` lands hours
ahead of `level.time`.

That matters for the two fields `!burn` and `!firegod` write, because the engine
reads them back against `level.time` in its own flamethrower burn loop
(`g_active.c:196-212`): every `MIN_BURN_INTERVAL` of 399 ms (`g_active.c:113`)
a client with a non-zero `s.onFireEnd` takes `WP_FLAMETHROWER` damage with
`MOD_FLAMETHROWER` for as long as `s.onFireEnd > level.time`, from
`g_entities[ent->flameBurnEnt]`. `CopyClientBody()` makes the same comparison
(`g_client.c:686`). So with the process clock ahead, `!burn` did not stop after
six seconds - it kept burning the victim for the rest of the server's uptime,
through every respawn - and `!firegod`'s toggle-off, which writes
`s.onFireEnd = now` to put the flames out, left them on.

`util/timers.lua` now carries the level clock:

```lua
local levelTime = 0

function timers.getLevelTime()
    return levelTime
end

function timers.oninit(initLevelTime)          -- et_InitGame(levelTime, ...)
    levelTime = tonumber(initLevelTime) or 0
end

function timers.ongameframe(frameLevelTime)    -- et_RunFrame(levelTime)
    levelTime = tonumber(frameLevelTime) or levelTime
    ...
end
```

`main.lua` loads `util.timers` at line 121, before every `game/` module at 139
and after, so its `onGameFrame` handler is the first one on the bus and the
reading is never a frame stale for the modules that ask for it. A command that
runs between frames - which is all of them - gets the value from the last frame,
which is the same value the engine is comparing against.

`commands/admin/burn.lua` and `commands/admin/firegod.lua` stamp
`s.onFireStart`/`s.onFireEnd` from `timers.getLevelTime()`. Nothing else changed:
`util/timers.lua`'s own intervals and `game/honors.lua`'s snapshot interval still
use `trap_Milliseconds()`, correctly, because both ends of an interval come from
the same clock and only the duration is used.

One consequence worth knowing: with the window on the right clock, the engine's
own burn loop now runs for exactly the six seconds `!burn` intends, on top of the
five 25-damage ticks the command schedules itself. Before, on a server with
`sv_serverTimeReset 1`, it ran for hours.

### 9.2 A `FIELD_VEC3` takes one table, not three calls

`_et_gentity_set()` dispatches on the field's type, and for a vector it calls
`_etH_gentity_setvec3(L, (vec3_t *)addr)`, which pushes the keys 1, 2 and 3 and
does `lua_gettable(L, -2)` - the value has to be a table with those keys. Hand it
a number instead and Lua raises `attempt to index a number value`. Reads are the
mirror image (`_etH_gentity_getvec3()` fills a table with `lua_rawseti` 1..3), and
so are `trap_Trace`'s vector arguments (`_etH_toVec3()`) and the `endpos` it
returns (`_etH_gettrace()`).

The vector fields are `ps.origin`, `ps.viewangles`, `ps.velocity`, `dl_color`,
`r.absmin`, `r.absmax`, `r.currentAngles`, `r.currentOrigin`, `r.mins`, `r.maxs`,
`rotate`, `s.angles`, `s.angles2`, `s.origin`, `s.origin2`, `TargetAngles` and the
`origin` alias (`g_lua.c:1293-1488`).

Three commands wrote `ps.velocity` a component at a time:

```lua
et.gentity_set(clientId, "ps.velocity", 0, 0)   -- raises: 0 is not a table
et.gentity_set(clientId, "ps.velocity", 1, 0)
et.gentity_set(clientId, "ps.velocity", 2, 0)
```

`freeze.lua:42-44` did that on every 100 ms tick for every frozen player, and
`throw.lua:39-41` and `throwall.lua:45-47` did it once per target - none of them
inside a `pcall`, so the error escaped into the command handler. `!freeze`,
`!throw`, `!fling`, `!launch`, `!throwa`, `!flinga` and `!launcha` therefore did
nothing on ET:Legacy except write a Lua error to the server console.

They now send one table, as the engine reads it:

```lua
et.gentity_set(clientId, "ps.velocity", { 0, 0, 0 })
et.gentity_set(cmdClient, "ps.velocity", { velocityX, velocityY, upVelocity })
```

The four-argument form is not wrong in general - `ps.stats`, `ps.persistant`,
`ps.powerups`, `ps.ammo`, `ps.ammoclip` and `sess.skill` are `FIELD_INT_ARRAY`
and take `(index, value)`, which is what `glow.lua`, `pants.lua`, `disguise.lua`
and `resetxp.lua` already send them. The mistake was using the array shape on a
vector field. `tests/et_stub.lua` now models both: a vector field raises on
anything but a table, an array field raises on anything but two numbers.

### 9.3 `!freeze` had nothing that could hold a player

With 9.2 fixed, `!freeze` cancelled momentum - which is worth having, since a
thrown or knocked-back player otherwise slides out of it - but it still did not
freeze anybody: the player move rebuilds `ps.velocity` from the usercmd every
frame, so a player who walks has a velocity again 50 ms later. The command's own
header has always claimed "frozen players cannot move until they are unfrozen".

ET:Legacy exposes the flag the engine uses for exactly this. `freezed` is a
writable `FIELD_INT` on the client (`g_lua.c:1239`), and `ClientThink()` turns it
into `client->ps.pm_type = PM_FREEZE` (`g_active.c:1380`), which `bg_public.h:495`
describes as "stuck in place with no control" and `bg_pmove.c:5246` as "no
movement at all". `!freeze` sets it, `!unfreeze` clears it, and the velocity reset
stays for the momentum.

One trap comes with it: nothing in the engine ever clears `client.freezed` again -
`g_active.c:1380` is its only reader, and `ClientSpawn()` does not touch it - so a
frozen player who disconnects would hand a frozen slot to whoever connects next.
Both the tick, when it notices a client is gone, and the disconnect handler now
clear the flag for a slot being given up. (The engine also has `freeze` and
`unfreeze` console commands of its own, `g_svcmds.c:2624-2625`.)

### 9.4 `et.G_Damage()` with entity number 1024

`_et_G_Damage()` takes the three entity numbers and does `g_entities + target`,
`g_entities + inflictor` and `g_entities + attacker` with no bounds check at all
before calling `G_Damage()`. `MAX_GENTITIES` is `1 << GENTITYNUM_BITS` with
`GENTITYNUM_BITS` 10 (`q_shared.h:1241-1242`), so the valid range is 0 to 1023 and
`ENTITYNUM_NONE` is 1023 (`q_shared.h:1247`).

Six commands passed 1024 where they meant "nobody":

```lua
et.G_Damage(cmdClient, 0, 1024, 25, 0, 0)   -- burn, and the same in gib, giba,
                                            -- lol, nade and poison
```

`g_entities + 1024` is one `gentity_t` past the end of the array. What happens
next depends on whatever the linker placed after `g_entities[]`: if those bytes
read as a NULL `client` pointer, `G_Damage()` skips every attacker branch and the
damage lands unattributed, which is the behaviour these commands have appeared to
have; if they read as anything else, the engine dereferences it. It is
out-of-bounds either way, and it is not something a module should rely on.

They now pass `constants.ENTITYNUM_NONE`, added to `util/constants.lua` next to
`MAX_GENTITIES` and `ENTITYNUM_WORLD` with the range documented. `ENTITYNUM_NONE`
is the right "nobody" here for a second reason: with no attacker client,
`G_Damage()` runs no team check, which is what lets an admin gib, burn or poison a
teammate at all. `gib.lua` and `giba.lua` also carried a three-line note about
these constants that gave `ENTITYNUM_WORLD` as 18; it is 1022, and the note is
gone.

The stub now raises for an entity number outside the range in `G_Damage()`, which
is how the six came out of the tests rather than out of a crash report.

### 9.5 `csay`, `cchat` and `ccp`: not engine commands, and working anyway

The engine's console command table (`g_svcmds.c:2600-2638`) holds `makeReferee`,
`removeReferee`, `makeShoutcaster`, `removeShoutcaster`, `mute`, `unmute`, `ban`,
`campaign`, `listcampaigns`, `revive`, `kick`, `clientkick`, `bot` (omnibot builds
only), `cp`, `reloadConfig`, `loadConfig`, `sv_cvarempty`, `sv_cvar`, `playsound`,
`playsound_env`, `gib`, `die`, `freeze`, `unfreeze`, `burn`, `pip`, `throw`, `ref`,
`passvote`, `cancelvote`, `qsay`, `gLoadLua` and, in debug builds, `ae`. There is no
`csay`, no `cchat` and no `ccp` in it - those names belong to etpub and silEnT, which
is where WolfAdmin's chat commands came from - and 565 call sites in 108 files send
their messages that way. Read against the table alone, every one of them is a message
nobody receives.

They are received. `ConsoleCommand()` (`g_svcmds.c:2645`) does not stop at its table:
after the `lua_*` built-ins it hands the command to `G_LuaHook_ConsoleCommand(cmd)`
(`g_svcmds.c:2679`, `g_lua.c:3969`) and only then walks `consoleCommandTable[]`
(`g_svcmds.c:2694`). WolfAdmin implements the missing commands on that hook:

```
et.trap_SendConsoleCommand(EXEC_APPEND, "csay 3 \"text\";")
  -> ConsoleCommand()                       g_svcmds.c:2645
  -> G_LuaHook_ConsoleCommand("csay")       g_svcmds.c:2679
  -> et_ConsoleCommand(cmdText)             main.lua:170
  -> events "onServerCommand"               commands/commands.lua:204
  -> servercmds["csay"]                     commands/commands.lua:208
  -> commandClientConsolePrint()            commands/server/csay.lua
  -> et.trap_SendServerCommand(3, "print \"text\n\"")
```

`commands/server/` holds eight of them - `csay`, `cchat`, `ccp`, `ccpm`, `cbp`,
`cannounce`, `cmusic`, `acl` - registered with `commands.addserver()`, and each one
translates to the `print`/`cp`/`cpm`/`chat` client commands the engine does have. The
arguments come from `et.trap_Argc()`/`et.trap_Argv()` on the Lua side
(`commands/commands.lua:209-212`), which is why a handler's signature is
`(command, firstArg, ...)`.

Two things follow, both worth knowing before adding a command:

- A Lua server command **shadows** an engine builtin of the same name, because the hook
  runs first. None of the eight collide with the table above, but `csay` is one
  `addserver("burn", ...)` away from taking over the engine's `burn`.
- The round trip goes through the console command buffer, so a message sent this way is
  one frame behind and costs a `trap_Argv` parse per argument. For a per-client message
  sent every frame - the double jump's "your jump is ready" in section 10, the vote
  announcements in section 11 - the modules call `et.trap_SendServerCommand()` directly
  with the same string `csay`/`ccp` would have produced. `game/honors.lua` already does
  this for `cpm`.

### 9.6 Checked and correct

The rest of the audit, so the next reader does not repeat it:

- `ps.powerups` written as `2147483647` (`glow.lua`, `pants.lua`, `disguise.lua`)
  is a powerup expiry the engine compares against `level.time`; the maximum
  integer means "forever" on either clock, so 9.1 does not apply to it.
- `ps.delta_angles` is not in `g_lua.c`'s field table at all, so `disorient.lua`'s
  `pcall` plus its `isWritable` answer is the right shape: the command reports
  that the engine will not do it instead of failing quietly.
- `noclip` is a client field with `FIELD_FLAG_READONLY` (`g_lua.c:1221`);
  `firegod.lua` already `pcall`s the write and tells the admin when it is refused.
- `playsound` does exist (`g_svcmds.c:2620`), so the sounds in `burn`, `throw`,
  `lol`, `nade` and `poison` are heard.
- `health` and `takedamage` are writable gentity fields (`g_lua.c:1393`, `:1471`),
  which is what `!firegod`'s toggle and the healing commands rely on.
- `s.onFireStart`/`s.onFireEnd` are writable (`g_lua.c:1448-1449`) - the fields are
  fine, only the clock they were stamped from was not.

### 9.7 Tests

`tests/audit_fix_spec.lua`, 70 checks. It moves the two clocks an hour apart the
way `sv_serverTimeReset 1` does, and it loads the eleven command modules against
stand-ins for `commands.commands`, `auth.auth`, `players.players` and
`util.settings`, so the handlers are called as the command dispatcher calls them.

Every fix in this section is mutation-tested: putting `et.trap_Milliseconds()`
back into `burn.lua` or `firegod.lua`, putting the component form back into any of
`throw.lua`, `throwall.lua` or `freeze.lua`, dropping the `freezed` write, and
putting 1024 back into any of the six `G_Damage()` calls each fail the suite.

## 10. Double jump, as in jaymod

New: `game/doublejump.lua`, `commands/admin/doublejump.lua`,
`tests/doublejump_spec.lua` (64 checks). One extra jump in the air, with jaymod's
numbers - a second of airtime to use it in and a little more height than the first
jump - toggleable per server and per round.

### 10.1 What jaymod does

`PM_CheckDoubleJump()` (`bg_pmove.cpp:816-868`, called from `PM_AirMove()`):

```cpp
if (ps->eFlags & EF_PRONE) return;
if ((pm->serverTime - ps->jumpTime) < 850) return;      // PM_JUMP_DELAY
if (ps->pm_flags & PMF_RESPAWNED) return;
if (pm->cmd.upmove < 10) return;
if (ps->pm_flags & PMF_JUMP_HELD) return;
ps->pm_flags |= PMF_DOUBLEJUMPING;
ps->velocity[2] = (int)(ps->velocity[2] + JUMP_VELOCITY * 1.4);
G_AddEvent(ps, EV_JUMP, 0);                             // animation + sound
ps->pm_flags |= PMF_JUMP_HELD;
ps->jumpTime = pm->serverTime;
```

and `PM_WalkMove()` clears `PMF_DOUBLEJUMPING` on landing. `MISC_DOUBLEJUMP` is
the cvar that enables it. The numbers are `JUMP_VELOCITY` 270 (`bg_local.h:53`) and
850 ms, which is the engine's own `PM_JUMP_DELAY` - the gap `PM_Jump()` insists on
between two jumps (`bg_pmove.c:72`).

### 10.2 What a Lua module cannot see, and what stands in for it

Three things jaymod uses are not available to a Lua module on ET:Legacy:

1. **There is no usercmd access.** `etlib[]` registers no `trap_GetUsercmd`, so
   `pm->cmd.upmove` - jaymod's trigger - cannot be read at all.
2. **The engine ignores upmove in the air.** `PM_AirMove()` (`bg_pmove.c:1253-1296`)
   never looks at it and never calls `PM_CheckJump()`; that call is only in
   `PM_WalkMove()` (`bg_pmove.c:1306`). `PM_Jump()` even says so: "don't allow jump
   until we run a frame of gravity".
3. **A jump in the air leaves no trace.** `PmoveSingle()` clears `PMF_JUMP_HELD` on
   every frame in which `cmd.upmove < 10` (`bg_pmove.c:5212`), so by the time the
   Lua module sees the client, the flag is already back to what it was. The same is
   true of `ps.jumpTime`: the field is not in `g_lua.c`'s table, so neither the last
   jump nor the 850 ms gap can be read - only re-created.

`game/doublejump.lua` therefore works out a take-off from the state it *can* read,
once per frame (`onGameFrame`):

- **the engine's own flag**, when it is still there: a rising edge of `PMF_JUMP_HELD`
  (`pm_flags & 2`, `bg_public.h:531`) means the player jumped this frame. It is
  visible for the frame the jump was accepted from the ground.
- **the impulse it leaves behind**: `ps.velocity[3]` back up to `JUMP_VELOCITY`
  (270, with a 60-unit tolerance for the frame the client is read in). This is the
  signal that survives an airborne press, where the flag has been cleared again. A
  player only reaches that speed by jumping, by a launch pad, or by `!throw`/`!fling`,
  all of which are take-offs from the ground anyway.

The impulse is latched with `seenBelow`: the velocity has to have been below the
threshold first, so the boost this module applies - 270 x 1.4 = 378, well above the
threshold - cannot be read back as a second take-off and grant a third jump.

Airborne or not is worked out the same way the engine's own stuck-in-air checks do
it, with a masked trace down from the feet
(`MASK_SOLID`, `CONTENTS_SOLID` - the two integer constants `g_lua.c` registers),
because `ps.groundEntityNum` is not exposed to Lua and the client field of that
name is only written by `ClientSpawn()` (`g_client.c:3210`), never during play.

The rest of jaymod's conditions are reproduced from exposed state: the 850 ms window
(re-created, not read), `PMF_RESPAWNED` (`pm_flags & 512`), `EF_PRONE`
(`eFlags & 0x80000`), `EF_DEAD` (`0x1`), `pm_type ~= PM_NORMAL`, the team check
(`TEAM_AXIS`/`TEAM_ALLIES` - the engine's own `PM_CheckJump` has none), health
above zero, and one jump per airtime. `jumps` is reset by the landing test, by
touching the ground again after a spawn, and on `onPlayerSpawn`, and the whole
state table is dropped when a client disconnects, so a slot handed to the next
player starts clean.

The boost writes the vertical component and keeps the horizontal momentum the
player already has:

```lua
local ok, err = pcall(et.gentity_set, clientId, "ps.velocity",
    { tonumber(velocity[1]), tonumber(velocity[2]), JUMP_VELOCITY * boost })
```

`g_doublejump_boost` is the 1.4, so a server can dial it anywhere from "a hop" to
"rocket jump". Every read of exposed state that the engine may refuse is `pcall`ed,
since `noclip`-style refusals are a documented behaviour of `gentity_get`/`_set`
(`FIELD_FLAG_READONLY`, section 9.6).

### 10.3 Three ways to trigger it

The engine cannot hand a Lua module a key press, so what counts as "the player
pressed jump again" is configurable - `g_doublejump_mode`:

| mode | what arms the second jump | note |
|------|---------------------------|------|
| `command` (default) | the client command `djump` | jaymod's, as closely as ET:Legacy's Lua allows: no client-side prediction, no extra key needed. The player binds it: `bind SPACE "+moveup;djump"` puts it on the jump key |
| `crouch` | a rising edge of `PMF_DUCKED` (`pm_flags & 1`) while airborne | no binding needed, and `eFlags & EF_CROUCHING` confirms it from the other side; the price is that crouching in mid-air to look down also uses the jump |
| `auto` | nothing - the second jump is applied on take-off | the `g_maxFlight 2` feel: two jumps' worth of height per jump |

`mode` decides, but the live centre print that tells the player the jump is ready
is only sent from the `onClientCommand` path (`command` mode), because a message
per frame per client would be noise on a full server.

### 10.4 Toggling

Two cvars and one command:

```
g_doublejump          0/1        master switch, default 1
g_doublejump_mode     command|crouch|auto
g_doublejump_window   ms         default 850, jaymod's PM_JUMP_DELAY
g_doublejump_boost    factor     default 1.4
g_doublejump_sound    ""         optional "sound/player/land.wav" on the jump
g_doublejump_announce 0/1        tell players the jump is available when they spawn
```

`onGameInit` registers only the ones that are empty, so a `server.cfg` value wins
over the default - the same rule `game/settings.lua` follows. Reading them is a
direct `trap_Cvar_Get` per frame rather than through `settings`, because `settings`
caches and a toggle mid-round should take effect on the next frame.

`!doublejump` (`PERM_CHEATS`, `commands/admin/doublejump.lua`) is the runtime half:

```
!doublejump                    - report the current state
!doublejump on|off             - flip g_doublejump
!doublejump status             - as above, plus every cvar
!doublejump mode command|crouch|auto
!doublejump window <ms>        - capped at 10000
!doublejump boost <factor>     - must be > 0
```

The branches that answer only the admin - `status` and the two refusals - answer with
`csay`, and the ones that change the server - `on`, `off`, `mode`, `window`, `boost` -
announce with `cchat -1` so everybody hears the change, both of them reaching clients
the way section 9.5 describes. The command is registered with
`disabled = (settings.get("g_standalone") == 0)`, the convention 91 of the admin
commands follow: as an add-on to another mod, the host mod owns the cheats.

### 10.5 Known limits

- **Client-side prediction.** The engine runs the player move on the client too,
  and the client has no double jump, so the second jump arrives as a correction:
  the player sinks for a moment and is then put back up. It is the reason jaymod
  does this in `bg_pmove.cpp`, which both sides share, and no Lua module can match
  it. The window and the boost are server-side only.
- **No animation, no jump sound.** `G_AddEvent(ps, EV_JUMP, 0)` needs the `EV_*`
  constants, and `g_lua.c` registers none of them. `g_doublejump_sound` plus the
  engine's own `playsound` console command (`g_svcmds.c:2620`) is the only feedback
  available; it is off by default so the module is silent unless a server asks.
- **Cost.** Two `gentity_get`s per connected client per frame, on the `onGameFrame`
  handler. On a 64-slot server that is 128 field reads per 50 ms, which is what the
  engine itself does for its own `ClientThink`s.
- **The engine can refuse a jump the module cannot see.** A sprinting player, or one
  on a ladder, gets no `PMF_JUMP_HELD` and no impulse, so no take-off is recorded
  and no second jump is armed. jaymod has the same blind spot for different reasons.
- **Launch pads and `!throw` count as take-offs.** Anything that puts a player in the
  air at 270+ units/s arms the window, which is a superset of jaymod's. `seenBelow`
  keeps it to one extra jump per airtime regardless.

### 10.6 Tests

`tests/doublejump_spec.lua`, 64 checks: the rising-edge take-off, the impulse
take-off, the 850 ms window opening and closing, `seenBelow` refusing to re-arm on
the module's own boost, the landing reset, one jump per airtime, the spawn reset,
the disconnect cleanup, each of the three modes, every refusal (prone, dead,
respawned, spectator, wrong `pm_type`, no health), the boost arithmetic and its
`pcall` refusal, the cvar registration not overwriting a `server.cfg` value, and
each branch of `!doublejump` including its two caps.

Mutation-tested: the window comparison, the `seenBelow` latch, the jump counter, the
`PMF_JUMP_HELD` mask, the `PMF_DUCKED` mask, the boost multiplication, the team
check and the `enabled` gate each fail the suite when broken.

## 11. A callvote for the bots

New: `game/botvote.lua`, `tests/botvote_spec.lua` (184 checks). Changed:
`game/voting.lua`, `util/constants.lua`.

### 11.1 Why this cannot be an engine vote type

The engine's vote table is a fixed array, `aVoteInfo[]` in `g_vote.c:70-98`, with 27
entries (`gametype`, `kick`, `mute`, `unmute`, `map`, `campaign`, `maprestart`,
`matchreset`, `mutespecs`, `nextmap`, `referee`, `shuffleteams`,
`shuffleteams_norestart`, `startmatch`, `swapteams`, `friendlyfire`, `timelimit`,
`unreferee`, `warmupdamage`, `antilag`, `balancedteams`, `surrender`,
`restartcampaign`, `nextcampaign`, `poll`, `config`, `cointoss`) each with a
`vote_allow_<name>` cvar and a `G_<name>Vote()` executor. No `bots`, no row for a
module to add: `Cmd_CallVote_f()` looks the type up and answers an unknown one with
`"Unknown vote command."` plus `G_voteHelp()` (`g_cmds.c:3380-3388`), and nothing in
`g_lua.c` lets a script extend the table. `vote_allow_bots` would be a cvar with no
command behind it.

So the vote is run in Lua, and `callvote bots ...` is claimed on the
`onClientCommand` bus before the engine can reject it. That bus is the mechanism
section 8.1 fixed: `et_ClientCommand()` is `G_LuaHook_ClientCommand()`
(`g_cmds.c:5320-5350`), which runs first and blocks the command on any non-zero
return. A referee's `callvote` would otherwise execute at once with no vote
(`g_cmds.c:3396`), and the engine's own `poll` does not let the caller vote yes on
their own poll - both behaviours are handled explicitly below.

### 11.2 What was there before

`game/voting.lua` accepted three poll strings - `needbots`, `kickbots`, `putbots` -
that no engine version has ever had, and mapped them onto the omnibot wrappers:

- `needbots` called `bots.put(bots.TEAM_AXIS_SC, bots.get(BOTS_AXIS), ...)` with
  **zero** bots requested, so even where the wrapper existed the vote was a no-op;
- `kickbots` called `bots.enable(false, true)`;
- `putbots` passed `bots.TEAM_AXIS_SC` (the string `"r"`, an omnibot side
  identifier) where `bots.put()` wants a team number.

`bots.enable()` and `bots.put()` do exist in ET:Legacy's omnibot interface and are
the right calls; the console side of it is the engine's own `bot` command
(`g_svcmds.c:2613`, `Bot_Interface_ConsoleCommand()`), which takes `maxbots`,
`difficulty`, `add`, `delete`, `debug`, `report` and `usage` - and prints
`"Omni-bot not loaded."` (`g_etbot_interface.cpp:5994`) when the library is absent.

`game/voting.lua` now routes a finished poll through the same parser the new vote
uses, so all three legacy strings still work and `putbots` sends a team number:

```lua
function voting.onPollFinish(passed, poll)
    if not passed then
        return
    end

    local action, value = botvote.parse(poll)

    if not action then
        return
    end

    botvote.execute(action, value)

    -- the engine has already announced the poll itself; say what it changed
    et.trap_SendServerCommand(-1, "print \"^dbots^7: "..botvote.describe(action, value).."\n\"")
end
```

The 60-line `elseif` chain that mapped `"enable bots"` to `needbots`, `"disable
bots"` to `kickbots`, `"put bots axis"` to `putbots r` and the two `set bot ...`
strings to `bot difficulty`/`bot maxbots` is gone; `botvote.parse()` and
`botvote.execute()` hold that knowledge once, for both entry points. `main.lua`
requires `game.botvote` at line 140, before `game.voting` at 148, so the require at
the top of `voting.lua` resolves.

`util/constants.lua`'s `VOTE_TYPES` was also mangled - it listed `et` and
`constants`, which are module names, not vote types, and omitted half the real
ones. It is now the engine's 27 in table order, which is what `G_voteHelp()`
prints. `muting` stays as a separate alias because it is the cvar name
(`vote_allow_muting` covers both `mute` and `unmute`), with a note saying so.

### 11.3 The vote itself

`callvote bots <action>` starts one, and `game/botvote.lua` owns every step, so the
arithmetic matches `G_CheckVote()` (`g_main.c:3725-3850`) rather than approximating
it:

- the 30 second lifetime, `VOTE_TIME` (`bg_public.h:70`);
- `vote_percent` clamped to 1..99, as the engine clamps it;
- `threshold = floor(pcnt * eligible / 100)`, with `eligible` the connected,
  non-bot, non-spectator clients - the engine counts the same set in
  `numVotingClients` (and, after `VOTE_TIME`, the total that voted when
  `VOTEF_USE_TOTAL_VOTERS` is set);
- pass on `yes > threshold`;
- fail on `no > 1 and no >= threshold`, which is the engine's rule and means a lone
  "no" on a full server does not kill a vote by itself;
- timeout otherwise;
- a referee's `callvote` skips the vote and executes at once (`g_cmds.c:3396`);
- `vote_limit` and the per-map counter, with the engine's `"You have already called
  the maximum number of votes (%d)."` (`g_cmds.c:3334-3336`);
- one vote at a time, with the engine's `"A vote is already in progress."`
  (`g_cmds.c:3319`) - sent from exactly one handler, since two of them see the
  command;
- the caller disconnecting cancels it, as the engine cancels a vote whose caller
  left;
- and, unlike the engine's `poll`, **the caller votes yes automatically**, so an
  admin alone on an empty server still gets their bots. That is the one deliberate
  difference, and it is documented in the module.

The announcements use the engine's own `cpm` strings byte for byte, sent with
`et.trap_SendServerCommand(-1, ...)` rather than through the `csay`/`ccp` console round
trip (section 9.5), because a vote can announce several times in the same frame:

```
^5Vote passed! ^7(^2Y:%d^7-^1N:%d^7) ^7(%s)\n
^1Vote FAILED! ^7(^1Y:%d^7-^2N:%d^7) ^7(%s)\n
^1Vote TIMEOUT! Not enough voters to pass vote ^7(^1%d^7/^2%d^7) ^7(%s)\n
^1Vote CANCELED!\n
[lof]%s^7 [lon]called a vote.[lof] Voting for: %s\n
```

(`g_main.c:3805`, `:3816`, `:3826`, `:3835`; the callvote line is
`g_cmds.c:3424-3430`, which also sends the `cp` centre print.)

The actions, all of them the engine's omnibot console command or the Lua wrapper
that calls it:

| `callvote bots ...` | what runs |
|---------------------|-----------|
| `on` / `enable` / `need bots` / `needbots` | `bots.enable(true, true)` |
| `off` / `disable` / `kick bots` / `kickbots` | `bots.enable(false, true)` |
| `axis [n]` / `allies [n]` / `put axis n` / `putbots` | `bots.put(TEAM_AXIS or TEAM_ALLIES, n, true)` |
| `max n` / `maxbots n` / `set bot max n` | `settings.set("omnibot_maxbots", n)` + `bot maxbots n` |
| `difficulty poorest..uber` or `0..6` | `bot difficulty n` |
| `?` / `help` | the usage line, no vote |

`parse()` is deliberately strict about what it claims. It accepts the poll wording
`game/voting.lua` has always taken ("enable bots", "disable bots", "kick bots",
"need bots", "put bots axis 4", "set bot max 8", "set bot difficulty hard") and the
short forms, but it returns `nil` for anything with an extra argument on the end -
`on 3`, `off now`, `axis 2 extra`, `enable all the things` - and for a bare `kick` or
`need`, which in an engine poll means a player, not a bot. Returning `nil` leaves the
command to the engine, which answers it with "Unknown vote command." and its help
list; claiming it would silently swallow a `kick` vote.

An admin with `PERM_BOTADMIN` gets the action at once, no vote, as `commands/bots.lua`
already does for `!bots`. `onCallvote` returns 1 for a claimed type and 0 for
everything else, `onClientCommand` returns 1 only for the `vote yes|no` and
`callvote` commands it owns - every other command on the bus is untouched.

`g_botVote` (default 1) is the server-side switch, registered through
`game/settings.lua` like the rest; with it 0, `callvote bots` falls through to the
engine and is refused there.

### 11.4 What a server needs for this to do anything

The omnibot library has to be loaded. ET:Legacy builds the `bot` console command only
with `FEATURE_OMNIBOT`, and without the library `Bot_Interface_ConsoleCommand()`
prints `"Omni-bot not loaded."` (`g_etbot_interface.cpp:5994`). The vote then passes,
the announcement is correct, and no bots appear - which is the engine's behaviour, not
the module's, so the module does not second-guess it.

### 11.5 Tests

`tests/botvote_spec.lua`, 184 checks, over a stub server that models
`trap_Cvar_Get/Set`, `trap_Argv`, `trap_SendServerCommand`, `trap_Milliseconds` and
the client fields the vote reads. It covers: every accepted wording and every
rejected one; the threshold arithmetic at the engine's boundary cases (a single
voter, a bare majority, exactly the threshold, one "no" among many); the timeout;
the referee bypass; `vote_limit` and the per-map counter; one vote at a time, said
once; the caller's automatic yes; the caller disconnecting; the map changing;
`g_botVote 0`; the admin bypass; and the poll strings from `game/voting.lua`
reaching `bots.put` with a team number rather than `"r"`.

Mutation-tested: 16 mutations - the threshold comparison, the `no > 1` rule, the
`VOTE_TIME` constant, the percent clamp, the auto-yes, the referee check, the
`vote_limit` comparison, the alias table, the strictness rejections, the
`TEAM_AXIS_SC`-to-number mapping - each fail the suite.
