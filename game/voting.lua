
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

local auth = wolfa_requireModule("auth.auth")

local botvote = wolfa_requireModule("game.botvote")

local constants = wolfa_requireModule("util.constants")
local events = wolfa_requireModule("util.events")
local settings = wolfa_requireModule("util.settings")
local timers = wolfa_requireModule("util.timers")
local util = wolfa_requireModule("util.util")

local voting = {}

local allowed = {}
local forced = {}
local restricted = {}

function voting.allow(type, value)
    allowed[type] = value
    et.trap_Cvar_Set("vote_allow_"..type, value)
end

function voting.isAllowed(type)
    return (allowed[type] == 1)
end

function voting.force(type)
    forced[type] = 1
    voting.allow(type, 1)
end

function voting.isForced(type)
    return (forced[type] == 1)
end

function voting.isRestricted(type)
    return (restricted[type] == 1)
end

function voting.disableNextMap()
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dvote: ^9next map voting has automatically been disabled.\";")

    voting.allow("nextmap", 0)
end

function voting.load()
    for _, type in pairs(constants.VOTE_TYPES) do
        allowed[type] = tonumber(et.trap_Cvar_Get("vote_allow_"..type))
        forced[type] = 0
    end

    local restrictedVotes = util.split(settings.get("g_restrictedVotes"), ",")

    for _, type in pairs(restrictedVotes) do
        restricted[type] = 1
    end
end

function voting.onGameInit(levelTime, randomSeed, restartMap)
    voting.load()

    if settings.get("g_voteNextMapTimeout") > 0 then
        voting.allow("nextmap", 1)
    end
end
events.handle("onGameInit", voting.onGameInit)

function voting.onGameStateChange(gameState)
    if gameState == 0 and settings.get("g_voteNextMapTimeout") > 0 then
        timers.add(voting.disableNextMap, settings.get("g_voteNextMapTimeout") * 1000, 1)
    end
end
events.handle("onGameStateChange", voting.onGameStateChange)

function voting.onCallvote(clientId, type, args)
    if et.gentity_get(clientId, "sess.sessionTeam") == constants.TEAM_SPECTATORS or args[1] == "?" then
        return 0
    elseif voting.isRestricted(type) and not auth.isPlayerAllowed(clientId, auth.PERM_NOVOTELIMIT) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"callvote: you are not allowed to call this type of vote.\";")
        et.trap_SendServerCommand(clientId, "cp \"You are not allowed to call this type of vote.")

        return 1
    end
end
events.handle("onCallvote", voting.onCallvote)

-- A poll is the only vote type the engine will carry for something it does not
-- have in aVoteInfo[], so "callvote poll enable bots" is how a bot vote used to
-- be called. What happened next never worked: this handler sent "needbots",
-- "kickbots" and "putbots" to the console, and no engine implements any of them
-- - g_svcmds.c's console table has a single bot entry, "bot", and that belongs
-- to the omnibot interface (GAMEPLAY-FIX.md 11.2). game/botvote.lua owns the
-- wording and the commands behind it now, and it also runs "callvote bots ..."
-- as a vote of its own.
function voting.onPollFinish(passed, poll)
    if not passed then
        return
    end

    local action, value = botvote.parse(poll)

    if not action then
        return
    end

    botvote.execute(action, value)

    -- the engine has already announced the poll itself; say what it changed
    et.trap_SendServerCommand(-1, "print \"^dbots^7: "..botvote.describe(action, value).."\n\"")
end
events.handle("onPollFinish", voting.onPollFinish)

return voting
