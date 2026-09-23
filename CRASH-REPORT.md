# Crash report: server dies the instant a knife is thrown (throwable knife)

Symptom from the live server: **the whole server dies the instant the throwable
knife is thrown**, with nothing in the console and nothing in the log. Engine:
a current ET: Legacy master / 2.83-dev build (Lua 5.4 API). Feature:
`throwable_knife` in `game/gameplay.lua`.

## 1. Root cause - confirmed from the crash log

The server log names it exactly:

```
ERROR: G_SpawnString() called while not spawning, file /code/src/game/g_spawn.c, line 805
----- Server Shutdown (Server crashed: G_SpawnString() called while not spawning ...) -----
```

`et.G_CreateEntity()` is the only entity constructor in ET:Legacy's Lua API,
and it works by feeding the spawn-var string through the engine's own
`G_SpawnGEntityFromSpawnVars()` (g_spawn.c). On current master that function
runs

```c
G_SpawnInt("notteam", "0", &i);        // -> G_SpawnString()
G_SpawnString("allowteams", "", &str); // -> G_SpawnString()
```

and `G_SpawnString()` answers with

```c
G_Error("G_SpawnString() called while not spawning, file %s, line %i", ...)
```

whenever `level.spawning` is false. `level.spawning` is true **only while the
map's entity definition is being parsed** - which means **`et.G_CreateEntity()`
cannot be called at runtime at all on this engine build**: the first call
G_Errors, and `G_Error` shuts the whole server down ("Server crashed: ...").
`pcall()` cannot catch it - the C side never raises a Lua error, it kills the
process from inside the call.

The throwable knife was the only thing in this tree creating entities at
runtime, and it did so inside `et_WeaponFire` - hence "crash the instant a
knife is thrown" (bots included: the reported crash came right after bot
activity). This is an engine-side regression for every Lua module that uses
`et.G_CreateEntity()` at runtime; the engine-side fix would be for
`G_Lua_CreateEntity()` (g_lua.c) to set `level.spawning = qtrue` around its
`G_SpawnGEntityFromSpawnVars()` call and clear it afterwards. Worth reporting
upstream - but the module no longer depends on it:

## 2. The fix - a knife reserve built during map load

`G_InitGame()` (g_main.c, master) does this, in order:

```c
G_LuaInit();                  // the Lua VMs are started first
G_SpawnEntitiesFromString();  // parses the map ents; level.spawning == qtrue
                              // fires G_LuaHook_SpawnEntitiesFromString()
                              // BEFORE it clears level.spawning again
...                           // much later:
G_LuaHook_InitGame(...);      // <- et_InitGame(), the modules load HERE
```

Two consequences:

1. `et_SpawnEntitiesFromString()` - not `et_InitGame` - is the one moment
   `et.G_CreateEntity()` is legal with Lua listening;
2. it is also the engine's **first** Lua callback: the modules and the event
   bus do not exist yet while it runs, so the reserve cannot be built through
   the bus.

The design therefore is:

* **`main.lua` `et_SpawnEntitiesFromString()`** builds the reserve itself,
  dependency-free: up to `KNIFE_MAX_LIVE` (12) `target_position` entities,
  every number range-checked (`g_entities + n` is done raw in the C glue),
  every slot verified `inuse` before it is kept, `G_EntitiesFree()` keeping
  `KNIFE_MIN_FREE_ENTITIES` (8) slots away from `G_Spawn()`'s "no free
  entities" `G_Error`, and each fresh entity immediately unlinked (the Lua
  glue links it). The result is handed over in the `wolfa_knife_reserve`
  global.
* **`knife.build_pool()`** (game/gameplay.lua) runs in `onGameInit` and
  *adopts* that global - re-verifying every slot (`inuse`) before it enters
  the reserve, reporting a poisoned slot once per map (`knife_pool_range`),
  and logging what it got: `knife reserve: 12 of 12 entities`.
* **`knife.acquire()`** hands the next parked slot to a throw. A dry reserve
  refuses the throw, which costs no clip and falls through to the normal
  melee stab.
* **`knife.release()`** returns a slot (on hit, pickup, lifetime expiry):
  unlink, park, re-use. **No `G_FreeEntity` is ever called at runtime** - the
  slots stay ours until the map ends, and the reserve is the cap on knives in
  the world.
* `acquire()` re-checks every slot (`inuse`, classname) before handing it out:
  a map script that took a slot over shrinks the reserve instead of handing
  out somebody else's entity.

Nothing else about the knife changed: same trajectory, same hit/land/pickup
logic, same config knobs. The whole feature degrades safely on engines
without the `et_SpawnEntitiesFromString` hook or with a failed reserve: the
reserve stays empty and every throw falls through to its melee stab, with one
warning in the log.

## 3. Diagnostics kept (`g_knifeDebug 1`)

The stage bracket from the first fix stays: with `set g_knifeDebug 1`, every
engine call on the reserve build and the throw/flight path is announced to
console **and** `games.log` (`G_LogPrint`) *before* it runs, so any future
hard death leaves the name of the call that died as the last log line.

## 4. Tests

`tests/knife_kill_spec.lua`, 133 checks, all passing against the engine stub's
real spawn/trace model. The harness now reproduces the engine's init order
(`onSpawnEntitiesFromString` before `onGameInit`) and the knife tests assert
the reserve semantics:

| test | asserts |
| ---- | ------- |
| reserve built at map load | 12 slots, parked unlinked, and **not one `G_CreateEntity` at throw time** - the regression test for this crash |
| g_knifeDebug off | silent without the cvar |
| g_knifeDebug on (adoption) | every reserve slot verified under the flag, nothing linked |
| g_knifeDebug on (throw) | hand-out and relink bracketed, no spawn |
| starved entity pool | smaller/empty reserve at load, throws refused, clip unspent, melee stab intact |
| insane entity number | out-of-range and negative answers refused before any field access, reported once per map |
| throw/flight/hit/land/pickup | as before, plus released slots re-used by the next throw |
| reserve exhaustion | 13th concurrent throw refused, slots released after the lifetime, throwing works again |
| taken-over slot | never touched, never handed out again |

Run: `lua tests/knife_kill_spec.lua`

## 5. If a crash ever happens again

`set g_knifeDebug 1`, reproduce, and take the last `knife:` line to the
tracker here - it names the exact engine call. And consider reporting the
`G_SpawnString()` runtime `G_Error` to github.com/etlegacy/etlegacy: any Lua
module that calls `et.G_CreateEntity()` outside map load takes a current
master server down.
