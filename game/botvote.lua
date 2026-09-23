
-- WolfAdmin module for Wolfenstein: Enemy Territory servers.
-- Copyright (C) 2015-2020 Timo 'Timothy' Smit

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

-- A vote to turn the bots on and off.
--
-- ET:Legacy's vote list is a fixed table inside the engine: aVoteInfo[] in
-- g_vote.c holds 27 types - gametype, kick, mute, unmute, map, campaign,
-- maprestart, matchreset, mutespecs, nextmap, referee, shuffleteams,
-- shuffleteams_norestart, startmatch, swapteams, friendlyfire, timelimit,
-- unreferee, warmupdamage, antilag, balancedteams, surrender,
-- restartcampaign, nextcampaign, poll, config and cointoss - and
-- Cmd_CallVote_f() answers anything else with "Unknown vote command" plus the
-- help text (g_cmds.c:3380-3388). There is no Lua call that adds a row, so
-- "bots" cannot become an engine vote type. That is also why game/voting.lua
-- ended up sending "needbots", "kickbots" and "putbots" to the console: no
-- engine has ever implemented those commands, so a passed poll did nothing at
-- all (g_svcmds.c's console table has one bot entry, "bot", and it belongs to
-- the omnibot interface).
--
-- It can still be a vote, because et_ClientCommand() runs before the engine
-- looks at a command and may swallow it by returning non-zero (g_cmds.c:5336).
-- This module owns "callvote bots ..." and, while one of its votes is running,
-- "vote yes" and "vote no". It counts them the way G_CheckVote() does -
-- vote_percent of the clients who can vote, VOTE_TIME of 30 seconds, the same
-- cpm wording - and hands the work to game/bots.lua, which speaks the omnibot
-- console commands the engine really implements.
--
--   callvote bots on              put the bots back in
--   callvote bots off             take them out again
--   callvote bots axis|allies     move every bot to one team
--   callvote bots max 8           the maximum number of bots
--   callvote bots difficulty 4    the omnibot skill level, 0-6 or by name
--
-- "callvote poll enable bots" keeps working as well: game/voting.lua parses a
-- passed poll through this module instead of the dead console commands.
--
--   g_botVote       0 = players may not call this vote, 1 = they may (default 1)
--
-- Two engine rules are honoured as they are written there: a referee-level
-- caller gets the change at once instead of a poll (g_cmds.c:3396 executes a
-- ref's callvote immediately), and vote_limit caps how many votes one player
-- may call (g_cmds.c:3334). Announcements go out through
-- et.trap_SendServerCommand() rather than the csay/cchat/ccp console commands
-- the rest of WolfAdmin uses, because those belong to etpub and silEnT and a
-- stock ET:Legacy server has never heard of them.

local auth = wolfa_requireModule("auth.auth")

local bots = wolfa_requireModule("game.bots")

local constants = wolfa_requireModule("util.constants")
local events = wolfa_requireModule("util.events")
local players = wolfa_requireModule("players.players")
local settings = wolfa_requireModule("util.settings")
local timers = wolfa_requireModule("util.timers")

local botvote = {}

-- bg_public.h:70, the engine's own vote window
local VOTE_TIME = 30000

-- the omnibot skill levels, as game/voting.lua has always spelled them out
local DIFFICULTIES = {
    ["poorest"] = 0, ["very poor"] = 1, ["poor"] = 2, ["easy frag"] = 3,
    ["standard"] = 4, ["professional"] = 5, ["uber"] = 6,
}

local MAX_BOTS = 64
local MAX_DIFFICULTY = 6

-- the running vote, or nil
local vote

-- [clientId] = how many votes they have called this map
local called = {}

-- Spellings of the same action. Deliberately none of the words an engine vote
-- type starts with: a poll called "kick 3" has to stay a kick vote, not turn
-- into "bots off".
local ALIASES = {
    enable = "on", disable = "off",
    ["1"] = "on", ["0"] = "off",
    r = "axis", red = "axis", b = "allies", blue = "allies", allied = "allies",
    maxbots = "max", skill = "difficulty",
}

local function trim(text)
    return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function announceAll(command)
    et.trap_SendServerCommand(-1, command)
end

local function announce(clientId, command)
    et.trap_SendServerCommand(clientId, command)
end

-- the engine announces votes with AP(va("cpm \"%s\n\"")), which is a
-- trap_SendServerCommand(-1, ...) with a real newline inside the quotes
local function cpm(text)
    announceAll("cpm \""..text.."\n\"")
end

local function name(clientId)
    return tostring(et.gentity_get(clientId, "pers.netname") or players.getName(clientId) or clientId)
end

local function isInGame(clientId)
    if not players.isConnected(clientId) or players.isBot(clientId) then
        return false
    end

    local team = et.gentity_get(clientId, "sess.sessionTeam")

    return team == constants.TEAM_AXIS or team == constants.TEAM_ALLIES
end

function botvote.isEnabled()
    local value = et.trap_Cvar_Get("g_botVote")

    if value == "" then
        return true
    end

    return tonumber(value) ~= 0
end

-- vote_percent, clamped the way G_CheckVote() clamps it (g_main.c:3746-3756)
local function percent()
    local value = tonumber(et.trap_Cvar_Get("vote_percent")) or 50

    if value > 99 then
        return 99
    elseif value < 1 then
        return 1
    end

    return value
end

-- how many clients get a say: everybody in the game, bots excepted
local function eligible()
    local total = 0
    local maxClients = tonumber(et.trap_Cvar_Get("sv_maxclients")) or 0

    for clientId = 0, maxClients - 1 do
        if isInGame(clientId) then
            total = total + 1
        end
    end

    return total
end

-- Read either the wording game/voting.lua already accepted from a poll - "enable
-- bots", "put bots axis", "set bot max 8", "set bot difficulty uber" - or the
-- short form the callvote takes: "on", "off", "axis", "allies", "max 8",
-- "difficulty uber". Returns the action and its value, or nil plus why not.
function botvote.parse(text)
    text = string.lower(trim(text))

    if text == "" then
        return nil, "no action given"
    end

    -- the wording game/voting.lua has always taken from a poll, matched whole
    if text == "enable bots" or text == "need bots" then
        return "on", nil
    elseif text == "disable bots" or text == "kick bots" then
        return "off", nil
    end

    -- and the short forms the callvote takes: "bots on", "on", "max 8",
    -- "put bots axis", "set bot difficulty uber"
    text = text:gsub("^put bots%s+", ""):gsub("^set bot%s+", ""):gsub("^bots%s+", "")

    local action, value = text:match("^(%S+)%s*(.*)$")

    if not action then
        return nil, "no action given"
    end

    action = ALIASES[action] or action
    value = trim(value)

    if action == "on" or action == "off" then
        -- never "on <something>": that is somebody else's vote wording
        if value ~= "" then
            return nil, "no such bot vote"
        end

        return action, nil
    elseif action == "axis" or action == "allies" then
        if value ~= "" then
            return nil, "no such bot vote"
        end

        return action, nil
    elseif action == "max" then
        local amount = tonumber(value)

        if not amount or amount < 0 or amount > MAX_BOTS then
            return nil, "max needs a number of bots between 0 and "..MAX_BOTS
        end

        return "max", math.floor(amount)
    elseif action == "difficulty" then
        local level = tonumber(value) or DIFFICULTIES[value]

        if not level or level < 0 or level > MAX_DIFFICULTY then
            return nil, "difficulty needs 0-"..MAX_DIFFICULTY.." or one of: poorest, very poor, poor, easy frag, standard, professional, uber"
        end

        return "difficulty", math.floor(level)
    end

    return nil, "no such bot vote"
end

-- the vote string the players see, in the "arg1 arg2" shape the engine uses
function botvote.voteString(action, value)
    if action == "on" then
        return "bots on"
    elseif action == "off" then
        return "bots off"
    elseif action == "axis" or action == "allies" then
        return "put bots "..action
    elseif action == "max" then
        return "set bot max "..tostring(value)
    elseif action == "difficulty" then
        return "set bot difficulty "..tostring(value)
    end

    return "bots "..tostring(action or "")
end

function botvote.describe(action, value)
    if action == "on" then
        return "put the bots back in the game"
    elseif action == "off" then
        return "take the bots out of the game"
    elseif action == "axis" then
        return "put every bot on the axis team"
    elseif action == "allies" then
        return "put every bot on the allied team"
    elseif action == "max" then
        return "set the maximum number of bots to "..tostring(value)
    elseif action == "difficulty" then
        return "set the bot difficulty to "..tostring(value)
    end

    return tostring(action)
end

-- What a passed vote does. Everything here goes through the omnibot console
-- interface, the only bot command ET:Legacy implements (g_svcmds.c:2613).
function botvote.execute(action, value)
    if action == "on" then
        bots.enable(true)

        return true
    elseif action == "off" then
        bots.enable(false)

        return true
    elseif action == "axis" then
        bots.put(constants.TEAM_AXIS)

        return true
    elseif action == "allies" then
        bots.put(constants.TEAM_ALLIES)

        return true
    elseif action == "max" then
        -- bots.enable(true) reads this setting back when it puts the bots in,
        -- so a new maximum has to be remembered as well as sent
        settings.set("omnibot_maxbots", value)
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "bot maxbots "..value..";")

        return true
    elseif action == "difficulty" then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "bot difficulty "..value..";")

        return true
    end

    return false
end

function botvote.isActive()
    return vote ~= nil
end

function botvote.getVote()
    return vote
end

function botvote.cancel(reason)
    if not vote then
        return false
    end

    vote = nil

    cpm("^1Vote CANCELED!"..(reason and (" ^7("..reason..")") or ""))

    return true
end

local function tally()
    local yes, no = 0, 0

    for _, _ in pairs(vote.yes) do
        yes = yes + 1
    end

    for _, _ in pairs(vote.no) do
        no = no + 1
    end

    return yes, no
end

-- G_CheckVote()'s decision, in the same order and with the same arithmetic:
-- passed when the yes votes are over the threshold, failed when the no votes
-- reach it, timed out when the window closes with neither (g_main.c:3787-3841).
function botvote.decide(timedOut)
    if not vote then
        return false
    end

    local yes, no = tally()
    local total = eligible()
    -- integer arithmetic, as the engine does it: threshold = pcnt * total / 100
    local threshold = math.floor(percent() * total / 100)
    local text = vote.string

    if yes > threshold then
        -- the action has to be taken out of the vote before it is cleared
        local action, value = vote.action, vote.value

        vote = nil

        cpm(("^5Vote passed! ^7(^2Y:%d^7-^1N:%d^7) ^7(%s)"):format(yes, no, text))
        botvote.execute(action, value)

        return true
    elseif no > 1 and no >= threshold then
        vote = nil

        cpm(("^1Vote FAILED! ^7(^2Y:%d^7-^1N:%d^7) ^7(%s)"):format(yes, no, text))

        return true
    elseif timedOut then
        vote = nil

        cpm(("^1Vote TIMEOUT! Not enough voters to pass vote ^7(^1%d^7/^2%d^7) ^7(%s)"):format(yes, threshold, text))

        return true
    end

    return false
end

function botvote.finish()
    return botvote.decide(true)
end

function botvote.cast(clientId, yes)
    if not vote then
        return false, "no vote in progress"
    end

    if not isInGame(clientId) then
        return false, "spectators cannot vote"
    end

    if vote.yes[clientId] or vote.no[clientId] then
        return false, "you have already voted"
    end

    if yes then
        vote.yes[clientId] = true
    else
        vote.no[clientId] = true
    end

    local yesCount, noCount = tally()

    announceAll(("print \"%s^7 voted %s. (^2Y:%d^7-^1N:%d^7)\n\""):format(
        name(clientId), yes and "YES" or "NO", yesCount, noCount))

    botvote.decide(false)

    return true, nil
end

local function usage(clientId)
    announce(clientId, "print \"^dbots vote^7: callvote bots ^3on^7|^3off^7|^3axis^7|^3allies^7|^3max <n>^7|^3difficulty <0-6>^7\n\"")
    announce(clientId, "print \"^dbots vote^7: then ^3vote yes^7 or ^3vote no^7, "..(VOTE_TIME / 1000).." seconds, "..percent().."% of the players in the game.\n\"")
end

function botvote.start(clientId, action, value)
    if not botvote.isEnabled() then
        announce(clientId, "cp \"Bot votes are disabled on this server.\"")

        return false
    end

    if vote then
        announce(clientId, "cp \"A vote is already in progress.\"")

        return false
    end

    if not isInGame(clientId) then
        announce(clientId, "cp \"Spectators cannot call a vote.\"")

        return false
    end

    local limit = tonumber(et.trap_Cvar_Get("vote_limit")) or 0

    if limit > 0 and (called[clientId] or 0) >= limit then
        announce(clientId, ("cp \"You have already called the maximum number of votes (%d).\""):format(limit))

        return false
    end

    -- a referee gets the change straight away, the way the engine treats a
    -- ref's callvote (g_cmds.c:3396)
    if auth.isPlayerAllowed(clientId, auth.PERM_BOTADMIN) then
        botvote.execute(action, value)

        cpm(("^5Referee changed setting! ^7(%s)"):format(botvote.voteString(action, value)))

        return true
    end

    called[clientId] = (called[clientId] or 0) + 1

    vote = {
        action = action,
        value = value,
        string = botvote.voteString(action, value),
        caller = clientId,
        yes = { [clientId] = true },
        no = {},
    }

    -- the engine's own two lines for a called vote (g_cmds.c:3423-3429), plus
    -- what to type, since this vote has no configstring to drive the UI
    announceAll(("print \"[lof]%s^7 [lon]called a vote.[lof] Voting for: %s\n\""):format(name(clientId), vote.string))
    announceAll(("cp \"%s\n^7[lon]called a vote: %s\n^7type ^3vote yes^7 or ^3vote no^7\n\""):format(name(clientId), vote.string))

    timers.add(botvote.finish, VOTE_TIME, 1)

    -- one player in the game, and they called it: the threshold is already met
    botvote.decide(false)

    return true
end

function botvote.oncallvote(clientId, type, args)
    type = string.lower(tostring(type or ""))

    if type ~= "bots" then
        -- the engine's help for "callvote ?" lists aVoteInfo[] and nothing else,
        -- so this vote type has to add its own line before that list arrives
        if type == "?" or type == "" then
            usage(clientId)
        end

        return 0
    end

    local action, value = botvote.parse(table.concat(args or {}, " "))

    if not action then
        usage(clientId)

        if value then
            announce(clientId, "cp \""..tostring(value).."\"")
        end

        return 1
    end

    botvote.start(clientId, action, value)

    return 1
end
events.handle("onCallvote", botvote.oncallvote)

function botvote.onclientcommand(clientId)
    if not vote then
        return 0
    end

    local command = string.lower(et.trap_Argv(0) or "")

    if command == "vote" then
        local answer = string.lower(et.trap_Argv(1) or "")

        if answer == "yes" or answer == "y" or answer == "1" then
            local ok, reason = botvote.cast(clientId, true)

            if not ok and reason then
                announce(clientId, "cp \""..reason.."\"")
            end
        elseif answer == "no" or answer == "n" or answer == "0" then
            local ok, reason = botvote.cast(clientId, false)

            if not ok and reason then
                announce(clientId, "cp \""..reason.."\"")
            end
        else
            announce(clientId, "cp \"vote yes or vote no\"")
        end

        return 1
    elseif command == "callvote" then
        -- "callvote bots ..." is oncallvote's to answer, and it has by now.
        -- Any other type would start an engine vote alongside this one, which
        -- the engine itself refuses while a vote is running (g_cmds.c:3319), so
        -- answer the way it does - once.
        if string.lower(et.trap_Argv(1) or "") == "bots" then
            return 0
        end

        announce(clientId, "cp \"A vote is already in progress.\"")

        return 1
    end

    return 0
end
events.handle("onClientCommand", botvote.onclientcommand)

function botvote.onclientdisconnect(clientId)
    if not vote then
        called[clientId] = nil

        return
    end

    vote.yes[clientId] = nil
    vote.no[clientId] = nil

    -- the engine drops a vote whose caller leaves
    if vote.caller == clientId then
        botvote.cancel("the caller disconnected")
    end
end
events.handle("onClientDisconnect", botvote.onclientdisconnect)

function botvote.oninit(levelTime, randomSeed, restartMap)
    vote = nil
    called = {}

    if et.trap_Cvar_Get("g_botVote") == "" then
        et.trap_Cvar_Set("g_botVote", "1")
    end
end
events.handle("onGameInit", botvote.oninit)

return botvote
