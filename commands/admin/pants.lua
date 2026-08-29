
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

-- !pants, as known from the NoQuarter mod. Removes the pants of a player
-- (visual, supported by the mod) and announces it to everyone.
--
-- NOTE: standalone ET: Legacy has no native "pants" model swap, so !pants
-- applies a visible team-colour glow as a cosmetic stand-in and announces it.
-- (On NoQuarter the mod performs the real model swap instead.)

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local events = wolfa_requireModule("util.events")
local settings = wolfa_requireModule("util.settings")

local pantsClients = {}

function commandPants(clientId, command, victim)
    local cmdClient

    if victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpants usage: "..commands.getadmin("pants")["syntax"].."\";")

        return true
    elseif tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpants: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpants: ^9no connected player by that name or slot #\";")

        return true
    end

    -- an immune player is protected from admins *below* their level, but a
    -- peer or superior (e.g. one Server Owner pantsing another) is allowed to
    -- target them. the higher-level check below still stops lower admins from
    -- touching someone above them.
    if auth.isPlayerAllowed(cmdClient, auth.PERM_IMMUNE) and auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpants: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")

        return true
    elseif auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpants: ^9sorry, but your intended victim has a higher admin level than you do.\";")

        return true
    elseif et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_AXIS and et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_ALLIES then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpants: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not playing.\";")

        return true
    elseif et.gentity_get(cmdClient, "health") <= 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpants: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not alive.\";")

        return true
    end

    if pantsClients[cmdClient] then
        pcall(et.gentity_set, cmdClient, "ps.powerups", 5, 0) -- PW_REDFLAG = 5
        pcall(et.gentity_set, cmdClient, "ps.powerups", 6, 0) -- PW_BLUEFLAG = 6

        pantsClients[cmdClient] = nil

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7Your pants have been returned by ^7"..players.getName(clientId).."^7!\";")
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dpants: ^7"..players.getName(cmdClient).." ^9has their pants back.\";")
    else
        if et.gentity_get(cmdClient, "sess.sessionTeam") == constants.TEAM_AXIS then
            pcall(et.gentity_set, cmdClient, "ps.powerups", 5, 2147483647) -- PW_REDFLAG = 5
        else
            pcall(et.gentity_set, cmdClient, "ps.powerups", 6, 2147483647) -- PW_BLUEFLAG = 6
        end

        pantsClients[cmdClient] = true

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7You lost your pants, courtesy of ^7"..players.getName(clientId).."^7!\";")
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "playsound "..cmdClient.." \"sound/player/land_hurt.wav\";")
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dpants: ^7"..players.getName(cmdClient).." ^9lost their pants.\";")
    end

    return true
end

function commandPantsOnClientDisconnect(clientId)
    pantsClients[clientId] = nil
end
events.handle("onClientDisconnect", commandPantsOnClientDisconnect)

commands.addadmin("pants", commandPants, auth.PERM_PANTS, "removes the pants of a player", "^9[^3name|slot#^9]", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "nq"))
