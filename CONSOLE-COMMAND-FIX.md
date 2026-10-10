# Fix: `et_ConsoleCommand error running lua script: ...:171: attempt to index a nil value (upvalue 'events')`

Symptom from the live server (Lua 5.4 API build of ET:Legacy):

```
Lua 5.4 API: et_ConsoleCommand error running lua script:
'[string "luascripts/wolfadmin/main.lua"]:171: attempt to index a nil value (upvalue 'events')'
```

Line 171 is `return events.trigger("onServerCommand", cmdText)`, the body of
`et_ConsoleCommand()` (line 263 after the fix).
`events` is a file-local of `main.lua` and it is only assigned inside
`et_InitGame()`. The engine called the console-command callback on a VM that
had `main.lua` loaded but had never run `et_InitGame()` - so every command the
engine forwarded raised a Lua error, and the command itself was then run by the
engine anyway (a failed hook is not fatal: `G_LuaCall()` prints the error,
counts it in `vm->err` and the hook moves on).

## 1. Why the engine can call a callback before `et_InitGame()`

ET:Legacy splits "load the Lua scripts" from "initialize the module", and the
two are not neighbours:

| what | where |
| ---- | ----- |
| `G_LuaInit()` - creates the VMs, reads `lua_modules` / `g_luaModuleList`, runs every script through `G_LuaRunIsolated()` | `G_InitGame()`, g_main.c |
| `et_SpawnEntitiesFromString()` | right after, g_main.c |
| `G_LuaHook_InitGame()` - the **only** caller of `et_InitGame()` | the end of `G_InitGame()`, g_main.c |

and three console commands create a VM **without** running the init hook:

| command | path | why the module stays uninitialized |
| ------- | ---- | --------------------------------- |
| `lua_init` | g_svcmds.c `ConsoleCommand()` -> `G_LuaInit()` | no `G_LuaHook_InitGame()` call |
| `lua_restart` | `G_LuaRestart()` = `G_LuaShutdown()` + `G_LuaInit()` | no `G_LuaHook_InitGame()` call |
| `gLoadLua` | `Svcmd_LoadLua_f()` -> `G_LuaRunIsolated()` | the new VM only gets `et_InitGame()` on the *next* map load |

After any of those, the server is already running a map, so the engine happily
keeps calling the newly registered callbacks:

* every console **and rcon** command goes `Cmd_ExecuteString()` (qcommon/cmd.c)
  -> `SV_GameCommand()` (sv_game.c) -> `GAME_CONSOLE_COMMAND` -> `ConsoleCommand()`
  (g_svcmds.c) -> `G_LuaHook_ConsoleCommand()` -> `et_ConsoleCommand()`. That is
  the reported line. `cmd.c` reaches this for any command the engine does not
  own itself, and `SV_RemoteCommand()` executes rcon text with
  `Cmd_ExecuteString()` directly;
* `et_RunFrame()` is called by `G_RunFrame()` every frame (line 197 of the old
  `main.lua` raised `attempt to index a nil value (upvalue 'game')` from the
  same cause);
* `et_Print()` is reached by `G_Printf()` during `G_InitGame()` itself, i.e.
  *before* `G_LuaHook_InitGame()` runs - the one window where every map load
  has a loaded-but-uninitialized VM.

The same broken state exists when `et_InitGame()` itself fails half way
through: a syntax error, a missing lua library, a bad database setting - the
engine prints that error once from `G_LuaCall()`, and the module stays
uninitialized forever after.

ET:Legacy's position on this is that the module has to check
([etlegacy/etlegacy#1426](https://github.com/etlegacy/etlegacy/issues/1426)):

> proper checks must be done to prevent the lua error if [the hook] was called
> before `et_InitGame`

Upstream WolfAdmin only guards `et_ShutdownGame()` (`if events then`), which is
why the same traceback can be seen with `et_ShutdownGame`, `et_RunFrame`,
`et_Print` or `et_ConsoleCommand` on top - depending on which hook fired first.

## 2. The fix

`main.lua` now tracks whether the module tree is loaded and every engine
callback goes through one guard:

* `local initialized = false` is set at the **end** of `et_InitGame()`, after
  the modules (and their `events.handle()` registrations) are in place. A
  half-loaded tree therefore stays inert instead of producing a traceback per
  command and per frame;
* `ready(hook)` returns false while `initialized` is false and reports the
  first such call once - with the two different causes:

  ```
  [WolfAdmin] warning: et_ConsoleCommand() called on an uninitialized module;
  the scripts were loaded outside a map load (lua_init, lua_restart and gLoadLua
  do not call et_InitGame()) - load a map to activate WolfAdmin
  ```

  or, when `et_InitGame()` started and failed: `... et_InitGame() did not finish
  loading the modules - fix the error printed above and load a map`;
* the guarded callbacks answer with the engine's own "not handled" value, so a
  dormant module behaves exactly like a module that returned nothing. The
  engine only treats the integer **1** as an interception and only a **string**
  as a client rejection (`G_LuaHook_ConsoleCommand()`, `G_LuaHook_ClientCommand()`,
  `G_LuaHook_Damage()`, `G_LuaHook_WeaponFire()`, `G_LuaHook_ClientConnect()` in
  g_lua.c - `et_WeaponFire()` gets two result slots, so a single `0` is safe):

  | callback | while uninitialized |
  | -------- | ------------------- |
  | `et_ConsoleCommand` | `0` (engine runs the command) |
  | `et_ClientCommand` | `0` (engine runs the command) |
  | `et_ClientConnect` | `nil` (no rejection) |
  | `et_Damage`, `et_WeaponFire` | `0` (damage/weapon fire not intercepted) |
  | `et_ClientBegin`, `et_ClientDisconnect`, `et_ClientUserinfoChanged`, `et_ClientSpawn`, `et_Obituary`, `et_RunFrame`, `et_Print` | `nil`, no event |
  | `et_ShutdownGame` | unchanged: fires `onGameShutdown` whenever the event bus exists, so a half-loaded tree still gets its cleanup |

* `et_SpawnEntitiesFromString()` is not guarded: it is the one callback that is
  *meant* to run before `et_InitGame()` (the throwable-knife reserve built while
  the map ents are parsed, see `CRASH-REPORT.md`) and it is dependency-free by
  design. `tests/init_guard_spec.lua` checks it still builds the reserve while
  the rest of the module is dormant.

## 3. On a running server

* The message itself is harmless - the command still runs - but a VM that
  reports it was loaded without a map load, so **WolfAdmin is dormant**: no
  `!` commands, no admin chat, no db/gameplay features, until the next map.
  `map_restart` (or any map change) initializes it; that is also why the error
  can go away "by itself" after a rotation.
* Reload scripts with `lua_restart`/`gLoadLua` only if a map load follows, or
  accept that the module is idle until then. Since this fix it says so once,
  instead of repeating the traceback for every command and frame.
* If the log shows `et_InitGame error running lua script: '...'` before the
  console-command errors, that line - not this one - is the bug: the module
  could not load (missing `lualibs/toml.lua`, missing sqlite/mysql lua library,
  database settings, a file left over from an older version...).

## 4. Verification

`tests/init_guard_spec.lua` (61 checks) loads the **real** `main.lua` the way
the engine does - the chunk name is `luascripts/wolfadmin/main.lua` without the
`@` that `loadfile()` adds, because `et_InitGame()` derives `luamodspath` from
`debug.getinfo(1).source` - installs `tests/et_stub.lua` as the engine, and then
drives every callback in both states:

```
$ lua tests/init_guard_spec.lua
== the reported error: a console command before et_InitGame()
== every engine callback survives the pre-init window
== after et_InitGame() the callbacks reach the module tree
== a failed et_InitGame() leaves the callbacks inert, not broken

61 checks passed
```

Against the unfixed `main.lua` the same spec fails with the reported message on
the first check:

```
  FAIL et_ConsoleCommand('status') does not raise: [string "luascripts/wolfadmin/main.lua"]:171:
       attempt to index a nil value (upvalue 'events')
  ... et_ClientCommand() ... :191: ... (upvalue 'events')
  ... et_RunFrame()     ... :197: ... (upvalue 'game')
  ... et_Print()        ... :262: ... (upvalue 'events')
```

`tests/et_stub.lua` gained the two engine functions `main.lua`'s init path
needs that it did not model before: `et.RegisterModname()` (copies into
`vm->mod_name`, g_lua.c) and the `et.EXEC_NOW/EXEC_INSERT/EXEC_APPEND`
constants (`cbufExec_t`, q_shared.h) - with a wrong value the module now fails
the spec instead of passing silently.

The whole suite passes on both Lua versions ET:Legacy ships (5.3.6) and the
Lua 5.4 API build from the report (5.4.9): `audit_fix_spec` 70, `gameplay_spec`
38, `knife_kill_spec` 182, `live_sim` 26, `botvote_spec` 184, `doublejump_spec`
67, `honors_spec` 34, `slot5_engine_spec` 20, `init_guard_spec` 61 checks.
