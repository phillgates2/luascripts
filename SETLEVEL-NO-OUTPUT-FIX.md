# `!setlevel` does nothing: diagnosis and fix

The report: *"!setlevel does not do anything"* - no traceback, no answer, no
level change that anyone can see. `ACL-SETLEVEL-FIX.md` fixed the commands
that **raised**; what is left is the ones that return *silence*, and `!setlevel`
had three of them. All three are now answers.

## 1. Short version

* On a **standalone ET:Legacy server** (the normal case: `fs_game = legacy`
  forces `standalone = 1`) a chat `!setlevel` by a **level 5** player has
  always worked. A `!setlevel` from the **client console** (`/!setlevel ...`),
  from **team chat** (`say_team !setlevel ...`) or from **rcon** either worked
  with no feedback or did nothing at all:
  * `rcon "!setlevel ..."` **did** change the level, but the answer went
    nowhere the admin could see it;
  * `/!setlevel ...` (client console) and `say_team !setlevel ...` were
    **dropped by the dispatcher without a word** whenever the player had the
    command's permission but not the channel's (`silentcmds` / `teamcmds`);
  * in **add-on mode without a mod backend** (`standalone = 0` left over in
    `wolfadmin.toml`, or `set g_standalone 0`) every `!setlevel` returned
    `false` and did **nothing** - no mod handles the command, no message is
    printed.
* Fixed by giving `!setlevel` one reply path that reaches whoever typed the
  command (`commands.reply()`), by making the dispatcher explain a denied
  channel, and by making the add-on path say that there is no backend instead
  of returning silently.

## 2. Why it looked like "nothing"

Three engine facts decide whether a message is visible; none of them is
obvious from the Lua side.

| Channel | What the engine does | Who sees it |
| ------- | -------------------- | ----------- |
| `et.G_Print(text)` in a **console** command | `case G_PRINT` → `Com_Printf` (`src/server/sv_game.c`) | the **server console** and the log file. Inside `rcon` the engine runs the command under `Com_BeginRedirect` (`SVC_RemoteCommand`, `src/server/sv_main.c`), so it also reaches the rcon client - but only while the command is still running. |
| `trap_SendConsoleCommand(EXEC_APPEND, "csay <id> \"...\"")` | queued command, runs later; `commands/server/csay.lua` turns it into the client command `print` | the client's **console**, never the game HUD and never the chat. An admin typing `!setlevel` in chat (or looking at the game, not the console) cannot see it. |
| `trap_SendConsoleCommand(EXEC_APPEND, "cchat <id> \"...\"")` | `commands/server/cchat.lua` → client command `chat` → `CG_ServerCommand`'s `CHAT_HASH` | the player's **chat line**, i.e. where the admin is looking. ET drops it for clients with `cg_teamChatsOnly 1` - so it cannot be the only channel. |

(The rcon path is the one `CONSOLE-COMMAND-FIX.md` §1 documents from the engine
side: `Cmd_ExecuteString()` → `SV_GameCommand()` → `ConsoleCommand()` →
`G_LuaHook_ConsoleCommand()` → `et_ConsoleCommand()`.)

The command tree answers the invoker with `csay` almost everywhere
(`commands/admin/*.lua`, ~400 call sites), which is exactly the "I typed it, I
get nothing, nothing happens" experience in game. On top of that, the queued
`csay`/`cchat` commands run **after** the console command has returned - which
is why an rcon invocation, whose output buffer is closed at that point, never
showed anything at all for a *successful* level change.

## 3. What the code did, path by path

| # | Path | Before | Now |
| - | ---- | ------ | --- |
| 1 | rcon / server console: `!setlevel 3 3` | silently changed the level; only the global `cchat -1` announcement went out, and no rcon output | `commands.reply()` prints the result on the console (`et.G_Print` inside the running command, so rcon sees it) *and* the announcement reaches the players |
| 2 | rcon / console: `!setlevel 3 99`, `!setlevel zzz 1`, `!setlevel`, ... | `csay -1337 "..."` - a client print for a client that does not exist (`-1337`); effectively `(no output)` | printed on the console, with the colours stripped |
| 3 | player in chat with the permission: `say !setlevel 3 3` | worked; refusals arrived as a client print (console) only | worked; refusals arrive as a chat line **and** a print |
| 4 | player in chat without the permission | `csay <id> "permission denied (setlevel)"` (client print) | chat line + print |
| 5 | `/!setlevel 3 3` (client console) or `say_team !setlevel 3 3`, player has `setlevel` but not `silentcmds`/`teamcmds` | **nothing whatsoever** - the dispatcher's outer `if` failed and fell through in silence | `setlevel: '!setlevel' needs the 'silentcmds' permission` (or `'say_team !setlevel' ... 'teamcmds'`), in the player's chat |
| 6 | `standalone = 0` with no `auth/shrubbot/<mod>.lua` (ET:Legacy with a stale `standalone = 0`) | `commandSetLevel` returned `false` immediately and silently - every invocation | `setlevel: no admin backend is available - add-on mode needs a mod with shrubbot flags (see wolfadmin.toml, standalone = 1)` |

`!setlevel` is registered twice (`commands/admin/setlevel.lua`) - the in-game
pass-through variant for add-on mode, the database variant for standalone
mode - so paths 1-5 are the database handler and path 6 is the pass-through
one. The pass-through handler is now called `commandSetLevelPassThrough()`
instead of shadowing the global `commandSetLevel` (`ACL-SETLEVEL-FIX.md` §3
fixed the same pattern in `acl.lua`).

## 4. The fix

* **`commands/commands.lua`**: new `commands.reply(clientId, text)`.
  * `clientId == -1337` (server console / rcon): `et.G_Print(util.removeColors(text))`
    - the message is written *while the command runs*, so an rcon client is
    still inside `Com_BeginRedirect` and receives it.
  * a player: `cchat <id>` (chat line) **and** `csay <id>` (print), so the
    answer shows up whether the admin typed in chat or in the client console,
    and survives `cg_teamChatsOnly`.
  * Called by `!setlevel` and by the dispatcher's denials.
* **`commands/commands.lua`**, `commands.onClientCommand()`: the channel check
  that used to swallow the command now reports the missing permission when the
  player has the command's permission but not the channel's. It is a generic
  fix - every admin command benefits (`!setlevel`, `!acl`, `!warn`, ...).
* **`commands/admin/setlevel.lua`**: every reply goes through
  `commands.reply()`; the successful standalone change additionally answers
  the console; the add-on path checks `auth.isBackendAvailable()` and explains
  itself; the pass-through handler is renamed.
* **`auth/auth.lua`**: new `auth.isBackendAvailable()` - `false` while the
  "no backend" stand-in (the one PR #20 added to `auth.onGameInit()`) is
  installed, `true` when the ACL or a shrubbot flag table is loaded. Without it a command cannot tell
  "this player is a guest" from "there is no ACL at all".
* **`tests/wolfadmin_server.lua`**: the harness created
  `<base>/legacy/luascripts/` regardless of `fs_game`, so a `fs_game` other
  than `legacy` could not open its database; it now creates the directory of
  the mod it boots, which is what makes the add-on test below possible.

## 5. Verification

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
== !setlevel fails cleanly when the standalone database is unavailable
== add-on mode (standalone = 0) with no shrubbot flag table: !setlevel says so instead of doing nothing
== every admin command, from the console and from players, raises nothing
250 checks passed
```

The new checks: the console is answered in place on success and on every
refusal (`seen(s)` = queued chat lines + console prints), a `say_team` /
client-console command without its channel permission names the permission
that is missing, and the add-on-without-backend case answers both the console
and the player. Against the tree before this fix the same spec fails **17 of
250** checks, among them `and the console is answered in place, not only the
players`, both channel messages and the whole add-on test.

What each invoker sees now (harness transcript, standalone mode, Alice level 5,
Bob level 3, Carol level 4):

```
rcon/console: setlevel 4 2               -> works, console is answered
  players:
    cchat -1 "^dsetlevel: ^7Carol ^9is now a level ^72 ^9player.";
  console:
    setlevel: Carol is now a level 2 player.
rcon/console: setlevel 4 99              -> refused, on the console
  players: (nothing)
  console:
    setlevel: this admin level does not exist.
Alice in chat: say !setlevel Carol 3     -> works
  players:
    cchat -1 "^dsetlevel: ^7Carol ^9is now a level ^73 ^9player.";
  console: (nothing)
Bob (level 3, no setlevel) in chat       -> refused, in Bob's chat
  players:
    cchat 3 "^dsetlevel: ^9permission denied ^9(^7setlevel^9)";
    csay 3 "^dsetlevel: ^9permission denied ^9(^7setlevel^9)";
  console:
    [WolfAdmin] ^3player 3 was denied 'setlevel', which needs permission 'setlevel'
Bob now has setlevel, but level 3 has no 'teamcmds': say_team !setlevel 4 1
  players:
    cchat 3 "^dsetlevel: ^9'say_team !setlevel' needs the '^7teamcmds^9' permission";
    csay 3 "^dsetlevel: ^9'say_team !setlevel' needs the '^7teamcmds^9' permission";
Bob, client console: /!setlevel 4 1 (no 'silentcmds')
  players:
    cchat 3 "^dsetlevel: ^9'!setlevel' needs the '^7silentcmds^9' permission";
    csay 3 "^dsetlevel: ^9'!setlevel' needs the '^7silentcmds^9' permission";
Alice, client console: /!setlevel 4 1    -> works
  players:
    cchat -1 "^dsetlevel: ^7Carol ^9is now a level ^71 ^9player.";
  console: (nothing)
```

The rest of the suite is unchanged: `audit_fix_spec` 70, `botvote_spec` 184,
`command_target_spec` 48, `doublejump_spec` 67, `gameplay_spec` 38,
`honors_spec` 34, `init_guard_spec` 61, `knife_kill_spec` 182,
`slot5_engine_spec` 20, `live_sim` 26.

## 6. If `!setlevel` still does nothing on your server

The command now answers, so the answer itself says where to look:

* *"no admin backend is available"* - `wolfadmin.toml` says `standalone = 0`
  (or something does `set g_standalone 0`) on a mod this fork has no
  `auth/shrubbot/<mod>.lua` for. ET:Legacy and ETPro belong in standalone
  mode: `standalone = 1`, then `!setlevel` writes to WolfAdmin's own
  database.
* *"permission denied (setlevel)"* - the stock schema gives `setlevel` to
  level 5 only. `!acl addpermission 4 setlevel` (from a level 5 player or the
  console) grants it to Senior Admins. From the console the check is skipped
  on purpose: the console outranks every level.
* *"needs the 'silentcmds' permission"* / *"needs the 'teamcmds' permission"* -
  the command came in on a channel the level may not use. Levels 4 and 5 have
  both in the stock schema (`!acl addpermission 3 silentcmds` for a lower
  level), or use plain chat: `say !setlevel <name> <level>`.
* *"the database is unavailable"* - `[db]` in `wolfadmin.toml`; check the
  server log for the WolfAdmin database error.
* A **level change that nobody confirms** used to be normal for the console;
  it now prints on the console and the players get the `cchat` line. If a
  player is not announced on your server, `!setlevel` was not the command
  that changed them.

Everything else that answers an admin - `!slap`, `!kick`, `!warn`, `!acl`, ...
- still sends its *invoker* replies with the queued `csay` print described in
§2, i.e. visible in the client console and not in the game. They can be moved
to `commands.reply()` the same way `!setlevel` was, file by file, with no
change to their logic.
