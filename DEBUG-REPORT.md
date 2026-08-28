# WolfAdmin full debug report

Date: 2026-08-28 · tree: `arena/01a04718-luascripts` @ `c9a06da` · engine: ET: Legacy (`g_standalone 1`)
Scope: every module loaded, every registered command driven, all three add-on mods, Lua 5.3.6 (ET: Legacy's version) and Lua 5.4.7.

## 1. Headline (carried over from PR #4)

Your original "permission denied" symptom is a **schema** problem, not a code
problem: 21 `auth.PERM_*` strings are granted to no level in a stock WolfAdmin
database, so `acl.isPlayerAllowed` denies them at every level, and `lockplayer`
(fork) vs `lockplayers` (schema) denies `!plock`/`!punlock` outright. PR #4 adds
the diagnostics, the SQL upgrade and `!acl addpermission`. Upstream master's
permission rows are byte-identical, so this is not fixed upstream.

## 2. Bugs found in this debug pass

Every item below was reproduced at runtime against the real WolfAdmin source
loaded on a stubbed engine, except where marked *(static)*. All of them also
exist in upstream 1.2.1 (`eb39bef`) — this fork did not introduce them.

**All of #1-#9 are fixed in the follow-up commit on this branch** (see §6 for the
verification).

| # | Sev | Bug | Trigger |
|---|-----|-----|---------|
| 1 | **High** | `commands/admin/vunmute.lua:55` uses `mutes`, which is never required in that file (it is a `local` in `main.lua`, not a global) | every `!vunmute` on a muted player |
| 2 | **High** (add-on modes only) | `auth/shrubbot.lua:58` calls `auth.isPlayerAllowed`, but `auth` is a `local` in `main.lua` → nil | `!incognito` (granting) on silent / nq / etpub |
| 3 | **High** | `admin/bans.lua:49` concatenates `duration`, which `commands/admin/ban.lua:63-66` leaves `nil` for a permanent ban | `!ban <player>` with no duration (admin has `perma` + `noreason`) |
| 4 | **High** (silent failure) | a ban with `duration = 0` is stored as `expires = issued`, and every read path requires `expires > os.time()` → permanent bans never block anyone | `!banguid`, `!banip`, and `!ban` once #3 is fixed |
| 5 | **Med** | `commands/admin/listplayers.lua:72` indexes the result of `db.getMostUsedAlias(...)` with no nil guard | any player with no row in `alias` (bots) |
| 6 | **Med** | same class: `commands/admin/showbans.lua:46`, `commands/admin/showhistory.lua:66` | ban/history row whose player has no alias |
| 7 | **Med** | `auth/acl.lua:227` indexes the result of `db.getPlayer(...)` with no nil guard; this runs inside **every** permission check | a player with no row in `player` (DB write failed, row deleted, client with no `cl_guid`) → every command they type throws |
| 8 | Low | `commands/server/c*.lua` (`csay`, `ccp`, `cchat`, `cmusic`, `ccpm`, `cannounce`, `cbp`) concatenate the `text` argument with no guard | `csay 3` with no text, from rcon/console |
| 9 | Low | `admin/{admin,bans,history,mutes}.lua` + `commands/admin/listaliases.lua:66` index `db.getPlayer(...)["id"]` with no guard | missing player row (same trigger as #7) |
| 10 | Info | `game/sprees.lua:107`, `commands/admin/sprees.lua:40`, `commands/admin/spreerecord.lua:45` — same unguarded-alias class as #5/#6 | *(static, not reproduced)* |
| 11 | Info | `db/sqlite3.lua:341` / `db/mysql.lua:341` do `tonumber(issued + duration)` — Lua-level arithmetic on a possibly-nil `duration` | *(static)* mutes with nil duration |

### Details, with reproductions

**#1 `!vunmute` is broken for everyone**

```
!vmute 5     -> cchat -1 "^dvmute: ^7Player5 ^9has been voicemuted for 600 seconds"
!vunmute 5   -> ERROR ./luascripts/wolfadmin/commands/admin/vunmute.lua:55: read of undefined global 'mutes'
```
The "has been unvoicemuted" message is sent *before* line 55, so the server
announces a successful unmute that never happened and the mute is never
removed. The file requires `auth`, `commands` and `players` but not
`admin.mutes`, and main.lua keeps its module handles in `local`s, so the bare
name `mutes` is nil.

**#2 `!incognito` crashes on add-on mods**

```
silent/nq/etpub:  !incognito -> ERROR ./luascripts/wolfadmin/auth/shrubbot.lua:58: read of undefined global 'auth'
```
Only `shrubbot.addPlayerPermission` (the "grant" branch) is affected; the
"revoke" branch is clean. **Does not affect your standalone setup.**

**#3 permanent `!ban` throws**

```
!ban 5  (admin has perma + noreason)
  -> ERROR ./luascripts/wolfadmin/admin/bans.lua:49: attempt to concatenate a nil value (local 'duration')
```
`commands/admin/ban.lua:63-66` sets `reason` but never `duration`. Note
`ban.lua:85-88` already handles a nil duration correctly for the chat message
(`durationText = "permanently"`), so only `bans.add` is wrong. The ban is left
half-applied: the history row is written, the player is never dropped, and the
ban row is never inserted.

**#4 permanent bans never actually ban anyone**

`sqlite3.addBan` / `mysql.addBan` store `expires = issued + duration`, and every
reader requires `expires > os.time()`:

- `db.getBanByPlayer` → `SELECT * FROM ban WHERE victim_id=X AND expires>os.time()` (used by `admin/admin.lua:56`, the reconnect check)
- `db.removeExpiredBans` → `DELETE FROM ban WHERE expires<=os.time()`

With the convention `duration = 0` for permanent (`commands/admin/banguid.lua:62`,
`commands/admin/banip.lua:97,100`), `expires == issued`, so the row is expired
from the moment it is written: the chat says "permanent" but the player rejoins
immediately. So `!banguid` and `!banip` are currently cosmetic.

**#5/#6 unguarded alias lookups**

```
!list          -> ERROR commands/admin/listplayers.lua:72: attempt to index a nil value   (24x in the sweep)
!showbans      -> ERROR commands/admin/showbans.lua:46: attempt to index a nil value
!showhistory 5 -> ERROR commands/admin/showhistory.lua:66: attempt to index a nil value
```
`commands/admin/baninfo.lua` already gets this right and is the pattern to copy:
```lua
local victim = db.getLastAlias(ban["victim_id"])
... victim and victim["alias"] or "unknown"
```

**#7 one missing player row breaks every command for that player**

With no row for a client in the `player` table, the sweep shows:
```
!ban 5 / !vmute 5 / !vunmute 5 / !warn 5 test / !listaliases 5
  -> ERROR auth/acl.lua:227: attempt to index a nil value (local 'player')
```
`acl.isPlayerAllowed` → `acl.getPlayerLevel` → `db.getPlayer(guid)["level_id"]`.
Any command that player types throws before it can do anything, which presents
to the user as "commands don't work".

## 3. Patches applied

**#1** `commands/admin/vunmute.lua` — add the missing require:
```lua
local mutes = wolfa_requireModule("admin.mutes")
```

**#2** `auth/shrubbot.lua:58` — use the same idiom the file already uses on line 30:
```lua
-            if not auth.isPlayerAllowed(clientId, flags[permission]) then
+            if et.G_shrubbot_permission(clientId, flags[permission]) ~= 1 then
```

**#3 + #4** permanent bans, fixed at the layer that owns `expires`:

`db/sqlite3.lua:399` and `db/mysql.lua:399`:
```lua
function sqlite3.addBan(victimId, invokerId, issued, duration, reason)
    local duration = tonumber(duration) or 0
    -- a ban without a duration is permanent. expires must stay in the future:
    -- every reader selects `expires > os.time()`, and removeExpiredBans deletes
    -- the rest. 2147483647 is the largest timestamp MySQL's INT column can hold.
    local expires = (duration > 0) and (tonumber(issued) + duration) or 2147483647

    cur = assert(con:execute("INSERT INTO `ban` (`victim_id`, `invoker_id`, `issued`, `expires`, `duration`, `reason`) VALUES ("..tonumber(victimId)..", "..tonumber(invokerId)..", "..tonumber(issued)..", "..expires..", "..duration..", '"..con:escape(reason).."')"))
end
```

`admin/bans.lua:41`:
```lua
    db.addBan(victimPlayerId, invokerPlayerId, os.time(), duration, reason)

-    et.trap_DropClient(victimId, "You have been banned for "..duration.." seconds, Reason: "..reason, 0)
+    local durationText = (duration and duration > 0) and ("for "..duration.." seconds") or "permanently"
+
+    et.trap_DropClient(victimId, "You have been banned "..durationText..", Reason: "..reason, 0)
```

`admin/admin.lua:58` (the message a banned player sees on reconnect):
```lua
-                if ban then
-                    return "\n\nYou have been banned for "..ban["duration"].." seconds, Reason: "..ban["reason"]
-                end
+                if ban then
+                    local durationText = ((tonumber(ban["duration"]) or 0) > 0) and ("for "..ban["duration"].." seconds") or "permanently"
+
+                    return "\n\nYou have been banned "..durationText..", Reason: "..ban["reason"]
+                end
```

**#5** `commands/admin/listplayers.lua:72`:
```lua
-        local mostUsedAlias = db.getMostUsedAlias(db.getPlayerId(player))["alias"]
+        local alias = db.getMostUsedAlias(db.getPlayerId(player))
+        local mostUsedAlias = alias and alias["alias"] or players.getName(player)
```

**#6** `commands/admin/showbans.lua:46` and `commands/admin/showhistory.lua:66` —
split the long `csay` line into locals and use the `baninfo.lua` pattern:
```lua
local victim = db.getLastAlias(ban["victim_id"])
local invoker = db.getLastAlias(ban["invoker_id"])
... victim and util.removeColors(victim["alias"]) or "unknown" ...
```

**#9** `db/sqlite3.lua:56` and `db/mysql.lua:56` — `getPlayerId` now creates the
`player` row when it is missing (the same insert `players.onClientConnect`
performs), so the nine sites that do `db.getPlayer(...)["id"]` keep working
instead of throwing. Those sites now simply call `db.getPlayerId(clientId)`,
which is the same lookup they were hand-rolling.

**#7** `auth/acl.lua:225` (level 0 is `Guest`, which the schema always has, so
the fallback is safe and `getLevelName(0)` still resolves):
```lua
function acl.getPlayerLevel(clientId)
    local player = db.getPlayer(players.getGUID(clientId))

-    return player["level_id"]
+    return player and player["level_id"] or 0
end
```

**#8** `commands/server/c*.lua` — guard the `text` argument (defensive; these are
console/rcon-only commands):
```lua
if clientId and clientId ~= -1337 and text then
```

## 5. What was checked and found clean

- **Every module loads and initialises** under both Lua 5.3.6 and Lua 5.4.7.
- **133 commands × 12 argument shapes** in standalone (with DB, without DB, with
  bots) and **62 / 71 / 68** commands in silent / nq / etpub. No Lua-version
  specific behaviour: the error sets are byte-identical on both interpreters.
- **No other undefined global reads.** A scope-aware parse-tree scan
  (`luaparser`) over all 148 files reports only the two in §2 (#1, #2); it
  correctly flags the pre-fix `cmdClient` bug in `commands/commands.lua` on the
  old tree, which is how the scan was validated.
- **No syntax errors** in any of the 148 `.lua` files.
- Bot handling, fireteam lookup, pagination, timers, sprees, greetings,
  balancer and voting all survived the sweep with no errors.

## 6. Verification after the fixes

- **Full sweep clean**: 133 commands x 12 argument shapes in standalone (with
  DB, without DB, with bots) and 62 / 71 / 68 commands in silent / nq / etpub,
  on both Lua 5.3.6 and Lua 5.4.7 — **no errors**. The only remaining message is
  the harness artifact `shrubbot.cfg` missing from the stub.
- **Static scan clean**: the scope-aware parse-tree scan reports no reads of
  undefined globals across all 148 files.
- `!vmute 5` then `!vunmute 5` -> mutes and unmutes, no error.
- `!ban 5` (no duration) -> `cchat -1 "^dban: ^7Player5 ^9has been banned permanently"`, no error.
- `!list` with a bot on the server -> prints all ten players, no error.
- `!showbans` / `!showhistory 5` with no alias row -> prints `unknown`, no error.
- `!incognito` on silent / nq / etpub -> "you are now playing incognito", no error.
- With no `player` row: `!warn 5 test`, `!listaliases 5`, `!vmute 5` all run
  (previously every one of them threw in `acl.getPlayerLevel`).
- **Ban SQL, captured from the real `db/sqlite3.lua` with a recording driver:**

  | call | SQL emitted |
  |------|-------------|
  | `addBan(..., nil, "permanent !ban")` | `expires` = **2147483647** (2038-01-19), `duration` = 0 |
  | `addBan(..., 0, "!banguid / !banip")` | `expires` = **2147483647**, `duration` = 0 |
  | `addBan(..., 600, "ten minutes")` | `expires` = issued **+ 600**, `duration` = 600 |

  So a permanent ban now survives `removeExpiredBans` (which deletes
  `expires <= now`) and is found by `getBanByPlayer` (which selects
  `expires > now`) — previously it expired the moment it was written. The MySQL
  backend is character-identical to the SQLite one for both changed functions.
- **No permission regression**: the stock schema denies exactly the same 31
  command/level pairs at level 5 as the unpatched tree (byte-identical list),
  the startup audit still reports the same 18 ungranted permissions, and the
  upgraded schema still gives level 5 zero denials and level 4 the same nine
  owner-only commands.

### Choice made for #4

"Permanent" is stored as `expires = 2147483647`, the largest timestamp that fits
both SQLite's `INTEGER` and MySQL's `INT` column (2038-01-19), with `duration`
kept at `0` so the existing "duration 0 means permanent" convention in
`!banguid` / `!banip` still reads correctly. The alternative (ban time + 10
years) would need MySQL's `expires` column widened to `BIGINT`.

## 7. How this was tested

The engine is stubbed (`et.*` API, 20 fake clients, filesystem, shrubbot), the
real `wolfadmin/main.lua` is loaded unmodified, and a strict-globals metatable
makes any read of an undefined global raise instead of silently returning nil.
Harness lives outside the repo in `/tmp/harness` (`stub.lua`, `probe.lua`,
`targeted.lua`, `scopecheck.py`); nothing was added to the repository except
this report.

Known harness artifacts (not bugs): `auth/shrubbot.lua:87 "failed to open
shrubbot.cfg"` — the stub has no `shrubbot.cfg`; real add-on servers do.
