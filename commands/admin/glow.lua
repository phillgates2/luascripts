
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

-- !glow, as known from the NoQuarter mod. Makes a player glow in their
-- team color (red for axis, blue for allies) by setting the flag
-- carrier powerup.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local events = wolfa_requireModule("util.events")
local settings = wolfa_requireModule("util.settings")

local glowingClients = {}

function commandGlow(clientId, command, victim)
    local cmdClient

    if victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dglow usage: "..commands.getadmin("glow")["syntax"].."\";")

        return true
    elseif tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dglow: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dglow: ^9no connected player by that name or slot #\";")

        return true
    end

    if auth.isPlayerAllowed(cmdClient, auth.PERM_IMMUNE) and auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dglow: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")

        return true
    elseif auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dglow: ^9sorry, but your intended victim has a higher admin level than you do.\";")

        return true
    elseif et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_AXIS and et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_ALLIES then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dglow: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not playing.\";")

        return true
    elseif et.gentity_get(cmdClient, "health") <= 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dglow: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not alive.\";")

        return true
    end

    if glowingClients[cmdClient] then
        pcall(et.gentity_set, cmdClient, "ps.powerups", 5, 0) -- PW_REDFLAG = 5
        pcall(et.gentity_set, cmdClient, "ps.powerups", 6, 0) -- PW_BLUEFLAG = 6

        glowingClients[cmdClient] = nil

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dglow: ^7"..players.getName(cmdClient).." ^9no longer glows.\";")
    else
        if et.gentity_get(cmdClient, "sess.sessionTeam") == constants.TEAM_AXIS then
            pcall(et.gentity_set, cmdClient, "ps.powerups", 5, 2147483647) -- PW_REDFLAG = 5
        else
            pcall(et.gentity_set, cmdClient, "ps.powerups", 6, 2147483647) -- PW_BLUEFLAG = 6
        end

        glowingClients[cmdClient] = true

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dglow: ^7"..players.getName(cmdClient).." ^9now glows in their team color.\";")
    end

    return true
end

function commandGlowOnClientDisconnect(clientId)
    glowingClients[clientId] = nil
end
events.handle("onClientDisconnect", commandGlowOnClientDisconnect)

commands.addadmin("glow", commandGlow, auth.PERM_GLOW, "makes a player glow in their team color (toggle)", "^9[^3name|slot#^9]", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "nq"))
