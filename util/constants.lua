
-- WolfAdmin module for Wolfenstein: Enemy Territory servers.
-- Copyright (C) 2015-2020 Timo 'Timothy' Smit

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- at your option any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

local constants = {}

constants.GAME_STATE_RUNNING = 0
constants.GAME_STATE_WARMUP = 1
constants.GAME_STATE_INTERMISSION = 3

constants.COLOR_MAIN = "^7"

constants.MAX_LENGTH_CP = 56
constants.MAX_LENGTH_CVAR = 254
constants.MAX_LENGTH_CONSOLE = 255

-- Entity numbers, q_shared.h:1239-1248. MAX_GENTITIES is 1 << GENTITYNUM_BITS,
-- so the valid range is 0 to 1023, and ENTITYNUM_NONE is the last slot - the one
-- the engine never spawns into, whose ->client is NULL.
--
-- Every number handed to et.G_Damage(), et.gentity_get() or et.gentity_set() has
-- to be inside that range. _et_G_Damage() does "g_entities + attacker" with no
-- bounds check at all, so 1024 points one gentity_t past the end of the array
-- and G_Damage() then reads whatever the linker placed there - a crash if it
-- happens to look like a client pointer. Six admin commands used to pass 1024
-- where they meant "nobody" (GAMEPLAY-FIX.md 9.4).
constants.MAX_GENTITIES = 1024
constants.ENTITYNUM_NONE = 1023
constants.ENTITYNUM_WORLD = 1022

constants.TEAM_AXIS = 1
constants.TEAM_ALLIES = 2
constants.TEAM_SPECTATORS = 3

constants.TEAM_AXIS_SC = "r"
constants.TEAM_ALLIES_SC = "b"
constants.TEAM_SPECTATORS_SC = "s"

constants.TEAM_AXIS_NAME = "axis"
constants.TEAM_ALLIES_NAME = "allies"
constants.TEAM_SPECTATORS_NAME = "spectator"

constants.TEAM_AXIS_COLOR = "^1"
constants.TEAM_ALLIES_COLOR = "^4"
constants.TEAM_SPECTATORS_COLOR = "^2"

constants.TEAM_AXIS_COLOR_NAME = "red"
constants.TEAM_ALLIES_COLOR_NAME = "blue"

constants.CON_DISCONNECTED = 0
constants.CON_CONNECTING = 1
constants.CON_CONNECTED = 2

constants.CLASS_SOLDIER = 0
constants.CLASS_MEDIC = 1
constants.CLASS_ENGINEER = 2
constants.CLASS_FIELDOPS = 3
constants.CLASS_COVERTOPS = 4

constants.SKILL_BATTLESENSE = 0
constants.SKILL_ENGINEER = 1
constants.SKILL_MEDIC = 2
constants.SKILL_FIELDOPS = 3
constants.SKILL_LIGHTWEAPONS = 4
constants.SKILL_SOLDIER = 5
constants.SKILL_COVERTOPS = 6

constants.AREA_CONSOLE = 0
constants.AREA_POPUPS = 1
constants.AREA_CHAT = 2
constants.AREA_CP = 3
constants.AREA_BP = 4

-- The vote types ET: Legacy knows: aVoteInfo[] in g_vote.c. Cmd_CallVote_f()
-- answers anything that is not in that table with "Unknown vote command" and
-- its help text (g_cmds.c:3380), and no Lua call adds a row to it, so this is
-- also the whole of what voting.load() can read a vote_allow_* cvar for.
--
-- The list this replaces was an ETPro era one that a search and replace had
-- mangled on the way in: "gametype" had become "gamconstantsype", "matchreset"
-- "matchresconstants" and "shuffleteamsxp" "shufflconstantseamsxp", and it
-- named types no engine implements - comp, pub, shuffleteamsxp. Those names
-- were dead in two directions: vote_allow_gamconstantsype is not a cvar, and a
-- restriction on "comp" could never match a vote anybody called.
--
-- "muting" stays in the list on purpose. It is not a vote type, it is the cvar
-- that gates both the mute and the unmute vote (vote_allow_muting, used by
-- G_Mute_v and G_UnMute_v in g_vote.c), so voting.allow() needs the name to
-- reach it. The same is true of campaign and unreferee, which the engine gates
-- through vote_allow_map and vote_allow_referee.
constants.VOTE_TYPES = {
    "antilag", "balancedteams", "campaign", "cointoss", "config", "friendlyfire",
    "gametype", "kick", "map", "maprestart", "matchreset", "mutespecs", "mute",
    "muting", "nextcampaign", "nextmap", "poll", "referee", "restartcampaign",
    "shuffleteams", "shuffleteams_norestart", "startmatch", "surrender",
    "swapteams", "timelimit", "unmute", "unreferee", "warmupdamage"
}

return constants
