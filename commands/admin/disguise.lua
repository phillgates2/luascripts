
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

-- !disguise, as known from the NoQuarter mod. Disguises a player as
-- the enemy team by setting the covert ops disguise powerup.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local events = wolfa_requireModule("util.events")
local settings = wolfa_requireModule("util.settings")

local disguisedClients = {}

function commandDisguise(clientId, command, victim)
    local cmdClient

    if victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisguise usage: "..commands.getadmin("disguise")["syntax"].."\";")

        return true
    elseif tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisguise: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisguise: ^9no connected player by that name or slot #\";")

        return true
    end

    if not auth.canTarget(clientId, cmdClient) then
        if auth.isTargetProtected(cmdClient) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisguise: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")
        else
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisguise: ^9sorry, but your intended victim has a higher admin level than you do.\";")
        end

        return true
    elseif et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_AXIS and et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_ALLIES then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisguise: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not playing.\";")

        return true
    elseif et.gentity_get(cmdClient, "health") <= 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisguise: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not alive.\";")

        return true
    end

    if disguisedClients[cmdClient] then
        -- PW_OPS_DISGUISED = 7
        pcall(et.gentity_set, cmdClient, "ps.powerups", 7, 0)

        disguisedClients[cmdClient] = nil

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^ddisguise: ^7"..players.getName(cmdClient).." ^9is no longer disguised.\";")
    else
        pcall(et.gentity_set, cmdClient, "ps.powerups", 7, 2147483647)

        disguisedClients[cmdClient] = true

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^ddisguise: ^7"..players.getName(cmdClient).." ^9has been disguised as the enemy.\";")
    end

    return true
end

function commandDisguiseOnClientDisconnect(clientId)
    disguisedClients[clientId] = nil
end
events.handle("onClientDisconnect", commandDisguiseOnClientDisconnect)

commands.addadmin("disguise", commandDisguise, auth.PERM_DISGUISE, "disguises a player as the enemy team (toggle)", "^9[^3name|slot#^9]", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "nq"))
