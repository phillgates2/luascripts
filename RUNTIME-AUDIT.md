# Runtime audit: every script, every mode (11 October 2026)

Scope: the whole `luascripts/wolfadmin` tree, on the engine the live server
runs (ET:Legacy, Lua 5.4 API build), in all five configurations the module can
boot in:

| mode | engine | flags source |
| ---- | ------ | ------------ |
| standalone | ET:Legacy (`fs_game legacy`, `g_standalone 1`) | SQLite/MySQL admin database |
| add-on `silent` | silEnT (`g_standalone 0`) | `shrubbot.cfg` via `G_shrubbot_*` |
| add-on `nq` | NoQuarter (`g_standalone 0`) | idem |
| add-on `etpub` | ETPro/ETPub (`g_standalone 0`) | idem |
| misconfigured | ET:Legacy with `[main] standalone = 0` | none - see 1.3 |

Method and results first, then the findings.

## 0. Result

* **92 runtime Lua errors across 8 distinct sites** were reproduced on the
  pre-fix tree by driving all 106 admin / 22 client / 8 server commands and
  the full lifecycle through a live replica of the engine.
* **0 errors** afterwards, in all five configurations above
  (`tests/` specs: 730 checks green, incl. the new `command_target_spec.lua`).
* The original live-server symptom (`et_ConsoleCommand ... main.lua:171`)
  cannot be produced by the code in this repository any more; section 1 tells
  you how to verify that on the server and what is left that can still make
  the module dormant.

## 1. The error from the live server

```
Lua 5.4 API: et_ConsoleCommand error running lua script:
'[string "luascripts/wolfadmin/main.lua"]:171: attempt to index a nil value (upvalue 'events')'
```

`CONSOLE-COMMAND-FIX.md` has the full diagnosis: line 171 is the body of
`et_ConsoleCommand()`, and `events` is only assigned by `et_InitGame()`. The
engine calls the callback on any VM whose scripts were loaded *outside* a map
load (`lua_init`, `lua_restart`, `gLoadLua`) or when `et_InitGame()` itself
failed half way. In this tree every callback starts with

```lua
function et_ConsoleCommand(cmdText)
    if not ready("et_ConsoleCommand") then
        return 0        -- the engine's own "not handled" value
    end

    return events.trigger("onServerCommand", cmdText)
end
```

so the traceback is impossible; `tests/init_guard_spec.lua` (61 checks) drives
every callback in both states on the real `main.lua`. If a server still prints
it, it is running an older copy of the file.

### 1.1 Verify the deployed copy

```sh
grep -n 'ready("et_ConsoleCommand")' luascripts/wolfadmin/main.lua   # must match
sed -n '171p' luascripts/wolfadmin/main.lua                          # must NOT be events.trigger
```

### 1.2 Read the log line before it

Once the guard is in place the same condition prints once, instead of a
traceback per command:

```
[WolfAdmin] warning: et_ConsoleCommand() called on an uninitialized module;
the scripts were loaded outside a map load (lua_init, lua_restart and gLoadLua
do not call et_InitGame()) - load a map to activate WolfAdmin
```

or, if `et_InitGame()` failed:

```
[WolfAdmin] warning: ... et_InitGame() did not finish loading the modules -
fix the error printed above and load a map
```

That "error printed above" is the engine's `et_InitGame error running lua
script: '...'` line - *that* is the bug to fix (a missing `lualibs/toml.lua`, a
missing sqlite/mysql Lua library, a bad database path, a file from an older
version). Nothing in this tree raises there any more, including the case below.

### 1.3 New: `standalone = 0` on ET:Legacy no longer aborts the map load

`auth/auth.lua` selected the shrubbot backend when `g_standalone` was 0 and
then required `auth.shrubbot.<fs_game>`, a flags table that only exists for
silent / nq / etpub. On an ET:Legacy server with a stale `[main] standalone = 0`
in `wolfadmin.toml` (or `set g_standalone 0`) that require raised *inside*
`et_InitGame()`, so the module tree never finished loading - every command then
failed (before the fix) or answered "uninitialized" (after). It now degrades
the way the missing-database case already did:

* one `outputDebug` line saying the mode has no flag table and how to fix it,
* every command denied (`auth.isPlayerAllowed` -> false, levels -> 0),
* `et_InitGame()` completes.

ET:Legacy and ETPro belong in standalone mode, which
`settings.determineMode()` already picks automatically.

## 2. How the tree was driven

The harness is a live replica of the engine, not a mock:

* the **real** `main.lua` is loaded with the chunk name the engine uses
  (`luascripts/wolfadmin/main.lua`), plus the real module tree;
* `tests/et_stub.lua` supplies the `et.*` engine surface, extended with the
  API the stub deliberately does not model (filesystem, userinfo, config
  strings, `ClientNumberFromString`, `ClientUserinfoChanged`, the `G_Say` /
  `G_TempEntity` / `G_XP_*` families, and - per mode - `G_shrubbot_level` /
  `G_shrubbot_permission`);
* a LuaSQL-compatible shim over a real SQLite database with the stock WolfAdmin
  schema (levels, permissions, players, aliases, bans, mutes, history, maps,
  records);
* `lualibs/toml.lua` is the real parser, so `wolfadmin.toml`, banners,
  greetings, rules and sprees are parsed for real;
* every registered command is driven with ten argument sets (`""`, `1`, `0`,
  `5 600 nit`, `3 0`, `-1`, `Player1`, `999`, `0 0 0 0`, `1 1 1 1 1`) through
  the console/rcon path, the silent `!` client path and the chat paths;
* the lifecycle is driven too: connect/begin/spawn for four clients (one bot),
  team changes, twenty frames, a map restart, reconnects, damage, obituary,
  weapon fire, vote and revive prints, disconnects.

```sh
cd <harness>            # Python 3 + lupa (Lua 5.4), sqlite3
python run.py                            # standalone (legacy) sweep
HARNESS_MODE=silent python run.py        # add-on modes: silent / nq / etpub
HARNESS_MODE=legacy0 python run.py       # legacy forced into add-on mode
```

The durable regression coverage for the bugs below lives in the repository as
`tests/command_target_spec.lua` (48 checks, `lua tests/command_target_spec.lua`),
which reproduces the same inputs on the plain test stub.

## 3. Bugs found and fixed

### 3.1 "Is anybody in that slot?" - 45 broken guards, 43 files

Every player-targeting command resolved its victim to a slot number and then
asked

```lua
elseif not et.gentity_get(cmdClient, "pers.netname") then   -- never true
```

`G_InitGame()` points `g_entities[i].client` at `level.clients[i]` for every
slot below `level.maxclients` (g_main.c) and that `gclient_t` is memset to
zero, so the engine returns **`""`** - truthy in Lua - for a slot nobody
occupies. The command then walked into `players.getGUID()`/`getIP()` with
`data[slot] == nil`:

```
!ban 5 600 nit        -> players.lua:43: attempt to index a nil value (field '?')
!country 5 600 nit    -> players.lua:47: attempt to index a nil value (field '?')
!plock 5 600 nit      -> players.lua:107: attempt to index a nil value (field '?')
```

45 call sites in 43 files now use the module's own predicate:

```lua
elseif not players.isConnected(cmdClient) then
```

Seven of the files (`ban`, `kick`, `listaliases`, `put`, `setlevel`,
`showhistory`, `stats`) did not require `players` at all; the require was added.

### 3.2 `players` accessors threw on any unknown slot

`getGUID`, `getIP`, `getProtocol`, `isBot`, `getLastPMSender`, the mute
accessors and `isTeamLocked` indexed `data[clientId]` unconditionally, and
`acl.getPlayerLevel()` (which runs inside **every** permission check) fed the
result straight into `db.getPlayer()`. They now return nil for a slot that is
not connected, `setMuted`/`setTeamLocked`/`setLastPMSender` are no-ops there,
`onClientBegin`/`onClientInfoChange` ignore a slot without data, and
`acl.getPlayerLevel()` treats a missing GUID as guest level 0.

### 3.3 Bots and untracked teams in `teams.lua` / `balancer.lua`

`teams.onconnect()`/`ondisconnect()`/`onclientteamchange()` and the balancer's
`lastJoined` table are keyed by the three team constants, but
`client->sess.sessionTeam` is not always one of them: g_client.c forces
`TEAM_SPECTATOR` only for a first-time **human**, so a bot connects with
`TEAM_FREE` (0), and the engine sets `TEAM_FREE` again at the very end of
`ClientDisconnect()` - after the hook. Both modules indexed the nil list:

```
et_ClientConnect(3)   -> tables.lua:77: bad argument #1 to 'for iterator' (table expected, got nil)
et_ClientDisconnect(3)-> tables.lua:89: idem
```

Untracked team values are now skipped (a team change into one of the three
still tracks the player).

### 3.4 `!baninfo` with a non-numeric ban number

`bans.get(tonumber(banId))` handed `nil` to the database layer, which
concatenated it into the SQL string:

```
!baninfo Player1 -> db/sqlite3.lua:468: attempt to concatenate a nil value
```

The command validates the number now (`!unban` and `!bans` already did), and
`getBan()` in both backends returns nil for a non-numeric id instead of
building a broken statement.

### 3.5 `et.TEAM_SPECTATORS` does not exist

The engine registers `TEAM_SPECTATOR` (singular); the repo's own constant is
`constants.TEAM_SPECTATORS`. Two sites compared against the non-existent
field, so the condition was always true:

* `commands/commands.lua:324` - `say_team` from a spectator was treated as a
  team command,
* `commands/admin/stats.lua:100` - `!stats` printed class/health for
  spectators.

Both use `constants.TEAM_SPECTATORS` now.

### 3.6 Test double fidelity (why the sweep was worth running)

The harness and `tests/et_stub.lua` were also made to match the engine where
they had been hiding or inventing errors:

* `ps.ping`, `sess.team_damage_given`, `sess.team_damage_received`,
  `sess.team_gibs` and the `sess.team_damage` / `sess.team_received` aliases
  were missing from the client field table - the repo's reads are legal
  (g_lua.c registers all of them, `ps.ping` read-only).
* `FIELD_INT`/`FIELD_INT_ARRAY` reads now return **0**, not nil, for a slot
  that was never written - the C structs are zero-filled. That is what
  `howfair.lua` / `listteams.lua` sum over `ps.persistant`, and what
  `stats.lua` compares (`health < 0`).
* `et.ClientUserinfoChanged()` was missing; it re-reads the userinfo into the
  client fields and fires the `et_ClientUserinfoChanged` hook, which is what
  `rename.lua` relies on.
* the driver models the connect order (spectator team for a first-time human,
  free for a bot) and the engine-side state of a spawn (`inuse`, `health`,
  `takedamage`), so bot/team bugs reproduce instead of being masked.

## 4. Verification

| what | before | after |
| ---- | ------ | ----- |
| standalone sweep (106/22/8 commands) | 92 errors / 8 sites | **0** |
| silent / nq / etpub sweeps | (add-on bugs, see DEBUG-REPORT.md) | **0** |
| ET:Legacy forced to `standalone = 0` | `et_InitGame` aborted | **0** (degrades, one message) |
| `tests/` specs | 9 specs, 682 checks | **10 specs, 730 checks**, all green |

## 5. Reported and checked, not bugs

* `ps.persistant` sums in `howfair.lua`/`listteams.lua` - the engine's int
  arrays are always 0+, never nil; the nil came from the test double (fixed in
  3.6).
* `!disorient` - ET:Legacy's Lua API has no `ps.delta_angles` field, so
  `disorient.lua`'s `pcall(et.gentity_set, ...)` probe is false and the command
  tells the admin it is unsupported. Dead feature, not an error; it cannot be
  implemented through this API (view angles are read-only to Lua).
* `et.MAX_GENTITIES` (`main.lua:357`) - guarded with `or 1024`.
* `et.EXEC_*` - exists; a source-scan false positive.
* The permission/schema gaps (`lockplayer` vs `lockplayers`, permissions never
  granted to a level) are the subject of `DEBUG-REPORT.md` and the SQL files in
  `database/upgrade/permissions/`; they produce denials, not Lua errors.

## 6. Files changed

* `players/players.lua`, `auth/acl.lua`, `auth/auth.lua`,
  `game/teams.lua`, `admin/balancer.lua` - the module-level fixes (3.2, 3.3,
  1.3).
* 43 files under `commands/` - the guard rewrite (3.1); `commands/admin/baninfo.lua`
  and `db/sqlite3.lua`/`db/mysql.lua` (3.4); `commands/commands.lua` and
  `commands/admin/stats.lua` (3.5).
* `tests/et_stub.lua` - engine fidelity (3.6).
* `tests/command_target_spec.lua` - the new regression spec (48 checks).
