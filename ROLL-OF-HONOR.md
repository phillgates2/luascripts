# A different Roll of Honor for ET:Legacy

## 1. What ET:Legacy allows (and what it does not)

The "ROLL OF HONOR" on the intermission screen is drawn by the **client**:
`src/cgame/cg_debriefing.c` has the window title and the award names in
`awardNames[]`, sized by `NUM_ENDGAME_AWARDS` in `cg_local.h` (21 entries, 22
with `FEATURE_RATING`; only `NUMSHOW_ENDGAME_AWARDS` = 14 fit, the rest scroll).
There is **no cvar** for it in either `cg_cvars.c` or `g_cvars.c`, and no
client-side Lua to hook it.

The **server** decides only who wins which of those fixed categories:
`G_BuildEndgameStats()` (`src/game/g_stats.c`, called from `G_LogExit()`) writes
`clientNum value team` for every award into the config string
`CS_ENDGAME_STATS`, and the client parses it on the first debriefing draw.

| | title / category list | who wins |
| --- | --- | --- |
| where | client, `cg_debriefing.c` | server, `g_stats.c` → `CS_ENDGAME_STATS` |
| changeable from Lua | no | yes: `et.trap_SetConfigstring(et.CS_ENDGAME_STATS, ...)` exists |
| changeable from a cvar | no | no |

So "different categories inside the debriefing window" needs a mod build that
every client installs (`g_stats.c` + `cg_debriefing.c` + `cg_local.h`). "A
server-side Roll of Honor with its own categories" needs nothing but Lua - and
that is what this fork now has.

## 2. `game/honors.lua` - the server-side Roll of Honor

New module, loaded automatically by `main.lua` (no `lua_modules` entry needed),
registered like the other `game.*` modules. When a map reaches intermission it
announces its own list in chat:

```
== Roll of Honor == test_map
Deadliest: Hans (34 kills)
Efficient killer: Hans (3.40 K/D)
Headhunter: Mia (12 headshots)
Silent blade: Piet (6 knife kills)
Demolitions expert: Piet (9 explosive kills)
Heavy hitter: Hans (4200 damage)
Spray and pray: Mia (310 shots fired)
Killing machine: Hans (9 kill spree)
Angel of Mercy: Mia (7 revives)
Most XP earned: Hans (230 XP)
Iron man: Piet (15 min played)
Butcher: Piet (9 gibs)
Cannon fodder: Piet (21 deaths)
Friendly fire: Piet (4 team kills)
Suicide king: Piet (2 self kills)
Sharp eye: Hans (41.2% accuracy)
```

(Colours: gameplay awards green `^2`, team awards blue `^4`, fun awards yellow
`^3`, the name white, the value grey - the sample above is the plain text that
also goes to the server log.)

An award is only announced when somebody qualifies, so a short or quiet map
stays quiet instead of printing empty titles.

### Categories

| group | award | what it measures | needs |
| --- | --- | --- | --- |
| gameplay | Deadliest | kills | 5 |
| gameplay | Efficient killer | kills / deaths | 10 kills |
| gameplay | Headhunter | headshots | 1 |
| gameplay | Silent blade | knife + k-bar + backstab kills | 1 |
| gameplay | Demolitions expert | panzerfaust, bazooka, grenade, riflegrenade, landmine, satchel, dynamite, airstrike, artillery, mortar kills | 3 |
| gameplay | Heavy hitter | damage given | 100 |
| gameplay | Spray and pray | shots fired | 100 |
| gameplay | Killing machine | longest kill streak | 5 |
| team | Angel of Mercy | revives performed | 1 |
| team | Most XP earned | XP gained on this map | 1 |
| team | Iron man | time played | - |
| team | Butcher | gibs | 1 |
| fun | Cannon fodder | deaths | 5 |
| fun | Friendly fire | team kills | 1 |
| fun | Suicide king | self kills | 1 |
| fun | Sharp eye | accuracy | 100 shots |

A player has to have played at least a minute to win anything (configurable),
so somebody who joins for the last 30 seconds can not take "Best K/D".

### Where the numbers come from

Everything is read out of the engine, not guessed:

* `sess.kills`, `sess.deaths`, `sess.gibs`, `sess.team_kills`,
  `sess.self_kills`, `sess.damage_given`, `sess.time_played` - the same session
  counters the scoreboard and the stock awards use (`gclient_fields` in
  `g_lua.c`).
* `sess.aWeaponStats[WS_*]` - the per-weapon block `{atts, deaths, headshots,
  hits, kills}` behind ET:L's accuracy and headshot awards; the `WS_*` indexes
  mirror `extWeaponStats_t` (`bg_public.h`) and are *not* the `WP_*` numbers.
* map XP - `sum(sess.skillpoints[i] - sess.startskillpoints[i])`, exactly how
  `G_BuildEndgameStats()` computes "Highest Experience Points".
* revives - counted from `onPlayerRevive` (the `Medic_Revive` console line
  main.lua parses), because `PERS_REVIVE_COUNT` counts the *revived* player,
  not the medic.

The counters are snapshotted every 15 s and again when the map ends, so a
player who disconnects five minutes before the end still appears in the
results - and each snapshot only ever raises a value, so a read that lags
behind can not undo a higher one.

### Configuration

Server cvars (no file editing needed):

| cvar | default | meaning |
| --- | --- | --- |
| `g_honors` | 1 | 0 disables the module |
| `g_honors_bots` | 0 | 1 lets bots into the results |
| `g_honors_messages` | 1 | 1 chat lines, 2 popups, 3 both, 0 server log only |

Tunables that live in the file's CONFIG block (`game/honors.lua`, top):
`SHOW_BOTS`, `MIN_PLAY_MS` (minimum play time), `SNAPSHOT_MS` (snapshot
interval), `MESSAGES`, `ROW_LIMIT` (max awards per map), `TITLE`, the colours,
and the `CATEGORIES` table itself - adding or removing an award is one entry.

### Tests

`tests/honors_spec.lua`, 34 checks, run from the repository root:

```
lua tests/honors_spec.lua [--verbose]
```

It uses `tests/et_stub.lua` (the ET:Legacy field table, the WEAPONSTAT read,
session counters) and covers: the awards themselves, the minimum thresholds
that suppress weak winners, a player who leaves before the end, a slot being
reused by somebody else, snapshots that lag behind, kill streaks from the
obituary, bot exclusion and the `g_honors_bots` override, the message modes,
and `g_honors 0`.

## 3. If you want the titles inside the debriefing window

That is a mod patch, and every player needs the modified client:

1. `src/game/g_stats.c` - add a block to `G_BuildEndgameStats()` that computes
   your category and appends `clientNum value team` to `buffer` in the award
   order.
2. `src/cgame/cg_debriefing.c` - add the matching title to `awardNames[]` at the
   same index.
3. `src/cgame/cg_local.h` - bump `NUM_ENDGAME_AWARDS`.
4. Rebuild; players must use the same build (the names are compiled into the
   client, the values come from the server).

Because ET:L ships the `legacy` mod inside the client install, this is only
practical for a closed community that distributes its own build. On a public
server, the module above is the only way to get new award categories.

A middle path also exists: a server-side Lua script may rewrite
`CS_ENDGAME_STATS` after `G_LogExit()` wrote it (`et.trap_SetConfigstring` runs
from `et_RunFrame`, which is called at the end of the same frame) - that can
re-assign, re-value or blank out the *existing* categories, but it can not add
a title. Useful if you prefer the stock list with different winners.
