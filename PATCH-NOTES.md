# Patch notes: !give permissions, !firegod and !pconexec (etoz port)

Follow-up to `DEBUG-REPORT.md`. Addresses three symptoms from the server:

- `!give` answered `permission denied (cheats)` for everyone, and a number of
  fun commands (`!lol`, `!nade`, `!poison`, `!throwall`, `!giba`, ...) did the
  same for their own permissions.
- `!firegod` and `!pconexec` (habits from the etoz server) were unknown
  commands here.
- `/!firegod` from the client console was unknown for the same reason.

## 1. The permissions are now applied automatically - Server Owner only

The root cause of every "permission denied" was a schema gap, not a bug: a
stock WolfAdmin database grants 21 permissions this fork's commands are
guarded by to **no level at all**, so the answer is "no" for every player on
the server, the Server Owner included. `DEBUG-REPORT.md` shipped a manual SQL
upgrade for this; if it is never run, the denials never go away - which is
exactly what happened.

WolfAdmin now heals this itself. On every game init (standalone mode, database
connected) `acl.applyDefaultPermissions()` in `auth/acl.lua` grants the fork's
default permission set to **level 5 (Server Owner) only**, and only where that
permission is not already granted:

| level | gets |
| ----- | ---- |
| 5 (Server Owner) | `banguid`, `banip`, `lockplayer`, `resetxp_self`, `resetxp`, `subnetban`, `ammopack`, `medpack`, `revive`, `disguise`, `poison`, `nade`, `lol`, `giball`, `throwall`, `crazysettings`, `warsettings`, `multiview`, `cheats` (`!give`, `!firegod`), `pconexec` (`!pconexec`), `immune` |

**Levels 3 and 4 are deliberately left alone.** They keep exactly the
permissions the stock schema already gives them (burn, slap, gib, throw,
glow, pants, pop, freeze, disorient, warn, kick, ban and so on for level 4),
so no lower admin gains commands or privileges from this change. If you ever
want a lower level to have one of these, grant it on purpose with
`!acl addpermission [level] [permission]`.

`immune` is included for level 5 because without it *no* level is protected:
any level 4 admin could `!burn` the server owner. The startup audit that
warned about ungranted permissions now reports **none**, and the log states
how many grants were applied.

- The behaviour can be turned off per server: `g_defaultPermissions 0`
  (a server cvar, or `[acl] defaults = 0` in `wolfadmin.toml`). Permissions
  are then managed strictly by hand with `!acl addpermission`.
- The grants are idempotent: a second map load inserts nothing, and a database
  that is restored or replaced heals itself on the next map load.
- `database/upgrade/permissions/*.sql` carry the same rows and remain
  available for manual use.

Effect: `!give`, `!firegod`, `!pconexec`, `!lol`, `!nade`, `!poison`, `!giba`,
`!throwall`, `!ammopack`, `!medpack`, `!revive`, `!disguise`,
`!crazygravity`, `!crazyspeed` and the war modes work out of the box for the
Server Owner (level 5) - and for nobody else unless you say so.

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
  database: level 5 sees **zero denials**; level 4 is denied every
  fork-added permission (it keeps its stock permissions: burn, slap, gib,
  throw, glow, pants, pop, pip, freeze, disorient). No errors.
- 72 hostile-argument cases (quotes, semicolons, colour codes, `%s`,
  backslashes, unicode, huge numbers, empties) against the three commands:
  no errors.
- Add-on mode (nq) boots clean: the new commands correctly stay unregistered
  and no default permissions are written to a mod's database.
- All 150 `.lua` files pass a syntax check; a second map load re-grants
  nothing (idempotency).

## 5. Configurable immune level + consistent target checks

Player-targeting punishment/game-effect commands now share one immunity rule
instead of a mix of "immune permission only", "immune + higher level" and
`"!"`-flag checks that never matched in standalone mode.

- New server setting `g_immuneLevel` (default **5**, Server Owner; set
  `[acl] immune = 5` in `wolfadmin.toml`). A player is protected when their
  level reaches this value **or** they carry the `immune` permission
  (`auth.isTargetProtected`). The level path works even with
  `g_defaultPermissions 0`, so an owner stays protected without relying on a
  database permission row.
- New `auth.canTarget(invoker, victim)`: a protected player can still be
  targeted by themselves and by same- or higher-level admins. Only someone
  below their level is blocked. The existing level hierarchy (a lower-level
  admin cannot target a higher-level player) is preserved for every target;
  `g_immuneLevel`/`immune` decides which target gets the "immune" reply.
- Applied to: `!give`, `!firegod`, `!pconexec`, `!ban`, `!banip`
  (by connected player name/slot; raw-IP, `!banguid` and `!subnetban` entries
  are unchanged because they do not resolve to a single connected player), `!kick`, `!mute`,
  `!unmute`, `!vmute`, `!vunmute`, `!warn`, `!dewarn`, `!slap`, `!gib`,
  `!giba`, `!burn`, `!freeze`, `!disorient`, `!orient`, `!put`, `!rename`,
  `!plock`, `!punlock`, `!resetxp`, `!throw`, `!throwall`, `!lol`, `!nade`,
  `!poison`, `!pants`, `!pop`, `!pip`, `!glow`, `!medpack`, `!ammopack`,
  `!disguise`, `!dw`, `!revive`. The all-player variants (`!giba`,
  `!throwall`, `!freeze all`, `!lol all`, `!pop all`, `!pip all`) skip only
  players the invoker is not allowed to target.
- Fixed `!put`/`!gib`/`!slap`/`!plock` using the literal `"!"` flag instead of
  `auth.PERM_IMMUNE` (they never protected a Server Owner in standalone mode),
  and fixed `!put`'s higher-level check comparing the victim against itself.
- Commands that merely look a player up (`!finger`, `!stats`, `!country`,
  `!showhistory`, `!listaliases`, ...) are intentionally unchanged.
