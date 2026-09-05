
-- WolfAdmin module for Wolfenstein: Enemy Territory servers.
-- Copyright (C) 2015-2020 Timo 'Timothy' Smit

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

-- !banip, as known from the NoQuarter mod. Bans a player from the
-- server by their ip address. All known players sharing the ip address
-- are banned, so this effectively bans the ip.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local db = wolfa_requireModule("db.db")

local players = wolfa_requireModule("players.players")

local settings = wolfa_requireModule("util.settings")
local util = wolfa_requireModule("util.util")

local function findPlayersByIp(ip)
    local matches = {}

    local playersCount = tonumber(db.getPlayersCount()) or 0
    local offset, pageSize = 0, 100

    while offset < playersCount do
        for _, player in pairs(db.getPlayers(pageSize, offset) or {}) do
            if player["ip"] == ip then
                table.insert(matches, player)
            end
        end

        offset = offset + pageSize
    end

    return matches
end

function commandBanIP(clientId, command, victim, ...)
    if not db.isConnected() then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbanip: ^9ban database is disabled.\";")

        return true
    elseif victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbanip usage: "..commands.getadmin("banip")["syntax"].."\";")

        return true
    end

    local ip = string.match(victim, "^(%d+%.%d+%.%d+%.%d+)$")

    if not ip then
        local cmdClient

        if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
            cmdClient = et.ClientNumberFromString(victim)
        else
            cmdClient = tonumber(victim)
        end

        if cmdClient == -1 or cmdClient == nil then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbanip: ^9no or multiple matches for '^7"..victim.."^9'.\";")

            return true
        elseif not et.gentity_get(cmdClient, "pers.netname") then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbanip: ^9no connected player by that name or slot #\";")

            return true
        end

        if not auth.canTarget(clientId, cmdClient) then
            if auth.isTargetProtected(cmdClient) then
                et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbanip: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")
            else
                et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbanip: ^9sorry, but your intended victim has a higher admin level than you do.\";")
            end

            return true
        end

        ip = players.getIP(cmdClient)
    end

    local args = {...}
    local duration, reason

    if args[1] and util.getTimeFromString(args[1]) and args[2] then
        duration = util.getTimeFromString(args[1])
        reason = table.concat(args, " ", 2)
    elseif args[1] and util.getTimeFromString(args[1]) then
        duration = util.getTimeFromString(args[1])
        reason = "banned by admin"
    elseif args[1] then
        duration = 0
        reason = table.concat(args, " ")
    else
        duration = 0
        reason = "banned by admin"
    end

    if duration == 0 and not auth.isPlayerAllowed(clientId, auth.PERM_PERMA) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbanip: ^9sorry, you are not allowed to ban permanently.\";")

        return true
    end

    local victims = findPlayersByIp(ip)

    if #victims == 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbanip: ^9no known player with ip '^7"..ip.."^9'.\";")

        return true
    end

    local invokerPlayerId = victims[1]["id"]

    if clientId >= 0 then
        local invoker = db.getPlayer(players.getGUID(clientId))

        if invoker then
            invokerPlayerId = invoker["id"]
        end
    end

    for _, player in pairs(victims) do
        db.addBan(player["id"], invokerPlayerId, os.time(), duration, reason.." (ip ban)")
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dbanip: ^9ip '^7"..ip.."^9' has been banned ("..#victims.." known player"..(#victims ~= 1 and "s" or "").."), Reason: ^7"..reason.."^9.\";")

    return true
end
commands.addadmin("banip", commandBanIP, auth.PERM_BANIP, "bans a player by ip address with an optional duration and reason", "^9[^3name|slot#|ip^9] (^3duration^9) (^3reason^9)", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "nq"))
