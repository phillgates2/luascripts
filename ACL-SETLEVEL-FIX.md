# `!setlevel` / `acl` errors: diagnosis and fix

The report: *"still getting errors for setlevel and acl"* after the runtime
audit (`RUNTIME-AUDIT.md`). That audit drove the whole tree through an engine
replica, but with a **database stand-in** - and every remaining error lives in
the seam the stand-in hid: the real `db/sqlite3.lua`, the stock schema and the
console/player command paths running together.

## 1. How it was found

`tests/wolfadmin_server.lua` boots the **real `main.lua` and the real module
tree** against `tests/et_stub.lua` as the engine and the real `db/sqlite3.lua`
on a real SQLite database created from the stock WolfAdmin schema
(`tests/schema/sqlite.sql`). `tests/luasql_sqlite3_fake.lua` is a
LuaSQL-compatible `luasql.sqlite3` on top of Python's sqlite3 (the sandbox's
`lua` is lupa), faithful in the two ways that matter: `con:execute()` answers
`nil, err` on a SQL error so `assert()` raises like on a server, and column
values can be typed three ways - integers (LuaSQL sqlite3), **every column a
string (LuaSQL mysql)**, every number a float (LuaSQL < 2.4 on Lua 5.3+).

Then every admin command (106) was run from the console, in chat, silently,
by a Server Owner, an Admin and a Guest, with eight argument shapes each; and
the `acl`/`!setlevel`/`!acl` scenarios by hand. Everything below came out of
that; the same run is now `tests/acl_setlevel_spec.lua` (217 checks).

## 2. What was wrong

| # | Where | Symptom on the server | Cause |
|---|-------|----------------------|-------|
| 1 | `commands/server/acl.lua` + `commands/admin/acl.lua` | **every** console `acl ...` action: `commands/admin/acl.lua:46: attempt to concatenate a nil value (local 'clientId')`, `:104 (local 'levelId')`, `:124 (local 'permission')`, `db/sqlite3.lua:192: attempt to concatenate a nil value` | both files defined **global** `commandAcl`, `commandAclListLevels`, `commandAclAddLevelPermission`, ... Command files load into one global table, `admin/` after `server/`, so the in-game functions (`(clientId, levelId, permission)`) silently replaced the console ones (`(levelId, permission)`). |
| 2 | `auth/acl.lua`, `commands/admin/setlevel.lua` | with **MySQL**: `!setlevel` → `setlevel.lua:95: attempt to compare string with number`; `!acl listpermissions 3` → "has no permissions", `!acl addpermission` → `table.insert` on nil; levels with a numeric id never matched | LuaSQL's mysql driver returns every column as a string. The permission cache was keyed by `"3"` while commands looked up `3`; `getPlayerLevel()` returned `"3"` and `!setlevel` compared it with a number. |
| 3 | `commands/admin/setlevel.lua` | `!setlevel Alice admin` (or any typo in the level) **demoted the player to level 0** silently | `level = tonumber(level) or 0` |
| 4 | `auth/acl.lua`, `admin/history.lua`, `db/*.lua` | on a database without the console's player row (not created from the stock schema): console `!setlevel` answered "victim has a higher admin level than you" / "may not setlevel higher than your current level" - the first owner could never be made; where it got further, `history.add()` → `escape()` on a nil IP / `addHistory(nil, ...)` concatenated nil into SQL | the console (clientId `-1337`) got level 0 without its row; `getPlayerId(-1337)` tried to insert a row with a nil IP |
| 5 | `db/sqlite3.lua` | `!resetsprees all` → `near "TRUNCATE": syntax error` | SQLite has no `TRUNCATE` |
| 6 | `admin/admin.lua`, `commands/admin/setlevel.lua` | a victim with no database record: `UPDATE player ... WHERE id='nil'` | `setPlayerLevel()` did not check `getPlayerId()` |
| 7 | `db/sqlite3.lua`, `db/mysql.lua` | after `close()` a second `start()` (VM kept across a map change, `lua_restart`): `attempt to index a nil value (upvalue 'env')` | `close()` drops the environment and `start()` never recreated it |
| 8 | `commands/admin/finger.lua`, `stats.lua` | `attempt to compare number with nil` when `sv_privateClients` is unset | `tonumber("")` |

## 3. The fix

* **`auth/acl.lua`**: every level id goes through `toLevelId()` (number,
  integer when exact) - cache keys, lookups, `getPlayerLevel()`, `isLevel()`,
  add/remove/copy. The cache entry for a level is created on demand
  (`levelCache()`), a permission row for a level missing from the `level`
  table no longer throws, duplicates are not cached twice, removal walks
  backwards. The **console outranks every level** (`max(own row, highest
  level id)`): `commands.onServerCommand()` already runs its commands without
  a permission check, so this only removes the contradiction.
* **`commands/admin/setlevel.lua`**: the level must match `^%d+$` ("'abc' is
  not a level number, see !acl listlevels"), both levels are compared as
  numbers, a missing level argument prints the usage, and a level that could
  not be stored says so instead of announcing it.
* **`commands/server/acl.lua` / `commands/admin/acl.lua`**: every helper is
  `local`. `acl listpermissions` tolerates a level with none, `acl addlevel`
  needs a name, the usage line ends in a newline.
* **`admin/admin.lua`**, **`admin/history.lua`**: a missing player id is a
  logged no-op (return `false`) instead of SQL with `nil` in it.
* **`db/sqlite3.lua`**, **`db/mysql.lua`**: `getPlayerId()` returns nil for a
  slot without a GUID and uses `0.0.0.0` when there is no IP (the console);
  `getPlayer(nil)` / `getLevel("x")` return nil instead of raising;
  `start()` recreates the environment, `close()` tolerates no connection;
  `TRUNCATE` → `DELETE FROM`.
* `sv_privateClients` read as `or 0` in `finger` / `stats`.

## 4. Verification

```
$ lua tests/acl_setlevel_spec.lua
== [sqlite3 (integers)] the console's `acl` command is the server command, not the in-game one
== [sqlite3 (integers)] !setlevel from the console
== [sqlite3 (integers)] !setlevel and !acl by players, level checks compare as numbers
== [sqlite3 (integers)] a permission granted in game takes effect at once and survives a map change
== [sqlite3 (integers)] a database without the console's player row
== [sqlite3 (integers)] a client without a GUID
== [sqlite3 (integers)] !resetsprees all on SQLite
== [mysql (every column a string)] ...   (the same seven)
== [old sqlite3 (every number a float)] ...   (the same seven)
== every admin command, from the console and from players, raises nothing
217 checks passed
```

Against the tree before this fix the same spec fails 79 checks with exactly
the messages in the table above (`acl.lua:46 ... (local 'clientId')`,
`setlevel.lua:95: attempt to compare string with number`, `near "TRUNCATE"`,
`upvalue 'env'`, "Alice is still level 5, not demoted to 0", ...).

The sweep at the end runs 106 admin commands × 8 argument shapes × 5 invokers
(4240 invocations) and fails on any raised error; it is clean in all three
driver modes. The rest of the suite is unchanged: `audit_fix_spec` 70,
`botvote_spec` 184, `command_target_spec` 48, `doublejump_spec` 67,
`gameplay_spec` 38, `honors_spec` 34, `init_guard_spec` 61, `knife_kill_spec`
182, `slot5_engine_spec` 20, `live_sim` 26.

## 5. If it still errors on your server

The first line of the traceback names the file. With this tree:

* `commands/admin/acl.lua:NN` from a **console** `acl` command means an old
  `commands/server/acl.lua` is still deployed (it must contain
  `local function commandAcl`).
* "permission denied (setlevel)" is not an error: the stock schema gives
  `setlevel` to level 5 only. `!acl addpermission 4 setlevel` from a level 5
  player or the console grants it to Senior Admins.
* The console counts as the highest level in the `level` table, so
  `!setlevel <you> 5` from rcon always works for the first owner.
