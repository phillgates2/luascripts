# Patch notes: !give permissions, !firegod and !pconexec (etoz port)

Follow-up to `DEBUG-REPORT.md`. Addresses three symptoms from the server:

- `!give` answered `permission denied (cheats)` for everyone, and a number of
  fun commands (`!lol`, `!nade`, `!poison`, `!throwall`, `!giba`, ...) did the
  same for their own permissions.
- `!firegod` and `!pconexec` (habits from the etoz server) were unknown
  commands here.
- `/!firegod` from the client console was unknown for the same reason.

## 1. The permissions are now applied automatically

The root cause of every "permission denied" was a schema gap, not a bug: a
stock WolfAdmin database grants 21 permissions this fork's commands are
guarded by to **no level at all**, so the answer is "no" for every player on
the server, the Server Owner included. `DEBUG-REPORT.md` shipped a manual SQL
upgrade for this; if it is never run, the denials never go away - which is
exactly what happened.

WolfAdmin now heals this itself. On every game init (standalone mode, database
connected) `acl.applyDefaultPermissions()` in `auth/acl.lua` grants the fork's
default permission set to the levels they belong to, but only where the level
exists and does not already have the permission:

| level | gets |
| ----- | ---- |
| 3 (Admin) | `banguid`, `banip`, `lockplayer`, `resetxp_self` |
| 4 (Senior Admin) | the above, plus `resetxp`, `subnetban`, `ammopack`, `medpack`, `revive`, `disguise`, `poison`, `nade`, `lol`, `giball`, `throwall`, `crazysettings`, `warsettings`, `multiview` |
| 5 (Server Owner) | the above, plus `cheats` (`!give`, `!firegod`), `pconexec` (`!pconexec`), `immune` |

`immune` is included for level 5 because without it *no* level is protected:
any level 4 admin could `!burn` the server owner. The startup audit that
warned about ungranted permissions now reports **none**, and the log states
how many grants were applied.

- The behaviour can be turned off per server: `g_defaultPermissions 0`
  (a server cvar, or `[acl] defaults = 0` in `wolfadmin.toml`). Permissions
  are then managed strictly by hand with `!acl addpermission`.
- The grants are idempotent: a second map load inserts nothing, and a database
  that is restored or replaced heals itself on the next map load.
- `database/upgrade/permissions/*.sql` carry the same rows (now including
  `pconexec` and `immune`) and remain available for manual use.

Effect: `!give`, `!lol`, `!nade`, `!poison`, `!giba`, `!throwall`,
`!ammopack`, `!medpack`, `!revive`, `!disguise`, `!crazygravity`,
`!crazyspeed`, the war modes and the new commands below work out of the box
for the Server Owner (level 5), and the fun set for Senior Admins (level 4).

## 2. `!firegod` - ported from etoz

`commands/admin/firegod.lua`, a port of `G_shrubbot_firegod` from
[etoz](https://github.com/phillgates2/etoz) (shrubbot flag `e`, the same
`cheats` permission `!give` uses):

```
!firegod [name|slot#] (noclip?)
```

- The victim must be on a team and alive, and the usual immunity and
  higher-admin-level checks apply.
- Toggling on: the player is set on fire for 1,800,000 ms (thirty minutes,
  the etoz value) and **takes no damage at all** (`takedamage = 0`; the
  engine's damage path ignores such entities, which also blocks `/kill` and
  world damage).
- Toggling off: the fire is extinguished and the player is mortal again.
- The toggle follows the engine: a respawn resets `takedamage`, so a player
  who respawned is toggled back *on* rather than silently staying god.
- The optional `noclip` argument matches the etoz syntax. ET: Legacy exposes
  the client's `noclip` field read-only to Lua, so it is attempted, and the
  admin is told when the engine refuses ("noclip is not supported by this
  engine, <player> burns without it") while the firegod part still applies.

## 3. `!pconexec` - ported from etoz

`commands/admin/pconexec.lua`, a port of `G_shrubbot_pconexec` from etoz:

```
!pconexec [name|slot#] [command] (value)
```

- The victim must be connected; immunity and higher-admin-level checks apply.
  Guarded by the new `pconexec` permission (level 5 by default).
- The server sends `pconexec <command> <value>` to the victim's client - the
  exact etoz wire format, so clients running the etoz client code execute it
  exactly like on the etoz server.
- **Caveat:** the etoz feature needs client cooperation. A stock ET: Legacy
  client has no handler for the `pconexec` server command and prints
  "Unknown client game command" instead - no stock client can be forced to
  execute console commands, by design. The admin reply says what was sent and
  mentions this.
- Quotes, semicolons and newlines are stripped from the command and value so
  the sent token stream cannot be broken up.
- Like on etoz, only the command and a single value reach the client (the
  etoz client-side handler reads two arguments).

Both commands work from chat, from the client console (`/!firegod 2`), and
from rcon, and appear in `!help`.

## 4. Verification

Full-suite re-run on the real `main.lua` loaded on a stubbed engine (Lua 5.3.6,
the version ET: Legacy embeds; strict globals, so any read of an undefined
global throws):

- 6 scenarios around the defaults, `!give`, `!firegod` and `!pconexec`
  (toggles, wire format, victim/immune/level checks, rcon and console paths,
  usage errors): all pass.
- Sweep of 47 command lines at level 5 and level 4 against a stock-schema
  database: level 5 sees **zero denials**, level 4 is denied exactly the
  owner-only commands. No errors.
- 72 hostile-argument cases (quotes, semicolons, colour codes, `%s`,
  backslashes, unicode, huge numbers, empties) against the three commands:
  no errors.
- Add-on mode (nq) boots clean: the new commands correctly stay unregistered
  and no default permissions are written to a mod's database.
- All 150 `.lua` files pass a syntax check; a second map load re-grants
  nothing (idempotency).
