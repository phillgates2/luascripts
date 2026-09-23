# Crash report: server dies the instant a knife is thrown (throwable knife)

Symptom from the live server: **the whole server dies the instant the throwable
knife is thrown**, with nothing in the console and nothing in the log. Engine:
a current ET: Legacy master / 2.83-dev build. Feature: `throwable_knife` in
`game/gameplay.lua`.

## 1. What the audit found

The whole throw path was verified call by call against the engine's own sources
(`src/game/g_lua.c`, `g_weapon.c`, `g_spawn.c`, `g_target.c`, `g_main.c`,
`sv_world.c` on master):

* every Lua-visible call the knife makes exists in `etlib[]` and is called with
  the signature the engine expects (`G_CreateEntity(string)`, `trap_Trace`
  with 6 table/number arguments - so its `minsPtr`/`maxsPtr` NULL-deref hazard
  is not reachable, the trajectory field writes, `G_Damage` with client-slot
  bounds checked on both ends, `AddWeaponToPlayer` with valid weapons);
* the Lua side is `pcall`-guarded everywhere - and a Lua error cannot kill the
  server anyway, the engine runs every callback through `lua_pcall`;
* the `et_WeaponFire` override contract (added in 2.83-dev,
  `G_LuaHook_WeaponFire(clientNum, weapon, &pFiredShot)`) is safe the way
  `main.lua` answers it: a single return value is padded with `nil`, the
  `pFiredShot` out-parameter stays `NULL` at the call site and is only read
  behind an Omni-bot guard;
* `G_RunEntity()` treats an `ET_GENERAL` as inert, `SP_target_position()` is
  `G_SetOrigin()` and nothing else, and the snapshot encoder bit-packs any
  `entityState_t` - no crash vector in the resulting entity either.

**Conclusion: the crash is a native (C) fault inside one of the `pcall`'d
engine calls, and no amount of Lua guarding can catch a segfault.** `pcall()`
only protects against the C glue *raising a Lua error*; when the C side dies,
the process dies with it - silently, exactly as reported. There are two
server-killers reachable on this path that the source *does* show, and one
class of unknown native fault that can only be identified from the outside.

## 2. What changed in `game/gameplay.lua`

### 2.1 The throw path is now bracketed call by call (`g_knifeDebug 1`)

A native crash cannot be caught from Lua, but it can be **bracketed**: every
engine call on the throw and flight path now announces itself to the console
**and** `games.log` (`G_LogPrint`, which reaches both - `log()`/`G_Print()`
only reach the console) *before* it runs, so the last line in the log names the
exact call that died. It is off by default and costs nothing when off (the
flag is read once per frame and once per throw, never per engine call):

```
set g_knifeDebug 1
```

then throw once. The log will look like:

```
[wolfadmin:gameplay] knife: et_WeaponFire client=3 weapon=1 clip=5
[wolfadmin:gameplay] knife: G_EntitiesFree -> ok=true free=512
[wolfadmin:gameplay] knife: G_CreateEntity("classname target_position origin "12.0 76.0 -3.2"")
[wolfadmin:gameplay] knife: G_CreateEntity -> ok=true ent=214
...
```

**The line after the last one that made it to disk is the call that killed the
server.** That is a finding for the engine (please send it upstream to
etlegacy with the line attached), and it tells us which part of the feature to
rework around it.

### 2.2 The entity pool is checked before every spawn (`G_EntitiesFree`)

`G_Spawn()` - reached through `et.G_CreateEntity()` - answers a full entity
pool with `G_Error("G_Spawn: no free entities")`, and `G_Error` takes the
whole server down with nothing Lua can catch. This is the one documented
server-killer the knife can reach, so the spawn is now refused while fewer
than `KNIFE_MIN_FREE_ENTITIES` (8) slots remain free. A refused throw spends
no clip and sets no cooldown: the engine falls through to the normal melee
stab, and the very next throw with a healthy pool works again.

### 2.3 The `G_CreateEntity` answer is validated before any field access

`_et_gentity_get`, `_et_gentity_set`, `_et_G_FreeEntity` and
`_et_trap_LinkEntity` all compute `g_entities + n` **with no range check** in
the C glue - a number outside the array is not a Lua error, it is a segfault
on the very next access (the same class of bug as `util/constants.lua`'s
`ENTITYNUM_NONE` note, and the same shape as etlegacy issue #2324). A thrown
knife now refuses any `G_CreateEntity` answer outside
`g_entities[MAX_CLIENTS .. MAX_GENTITIES-1]` and logs
`ERROR (knife_create_range)` once per map instead of touching the slot.

### 2.4 Flight/hit/pickup are bracketed too

`knife.fly` (trace + relink), `knife.land`, `knife.pickup` (via
`knife.free`), and the `G_Damage` on a player hit all announce themselves
under the same flag, so a crash that only happens on hit or pickup brackets
the same way.

## 3. Tests

Four blocks in `tests/knife_kill_spec.lua`, all running against the engine
stub's real spawn/trace model:

| test | asserts |
| ---- | ------- |
| `g_knifeDebug off` | no stage lines anywhere without the cvar |
| `g_knifeDebug 1` | the throw still works, every call bracketed, call logged before its answer |
| empty entity pool | throw refused (passed through to the melee stab), clip not spent, no entity created, next throw works |
| insane entity number | out-of-range and negative `G_CreateEntity` answers are refused before any field access or link |

`lua tests/knife_kill_spec.lua` - all 126 checks pass.

## 4. If the crash still happens with this build

Run with `g_knifeDebug 1`, reproduce, and take the last `knife:` lines from
the console/`games.log` to the tracker here (and ideally to
github.com/etlegacy/etlegacy - if the fault is inside `G_CreateEntity` or the
`gentity_set` glue it is an engine bug no Lua module can work around, only
avoid). The bracket converts "server just dies, no output" into an exact call,
which is the difference between guessing and fixing.
