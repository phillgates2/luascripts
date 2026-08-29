
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

-- !pop, as known from the etpub, NoQuarter and silEnT mods. Pops the
-- helmet off a player's head.
--
-- NOTE: on etpub/NoQuarter/silEnT the mod performs the actual helmet pop;
-- on standalone ET: Legacy (gamename "legacy") there is no native helmet
-- removal, so !pop draws real sparks (EV_SPARKS = 78) as the visible
-- effect, the same way !pip does.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

local function popClient(cmdClient)
    if et.G_TempEntity and string.lower(et.trap_Cvar_Get("gamename") or "") == "legacy" then
        -- EV_SPARKS = 78 (ET: Legacy): draw real sparks around the player
        pcall(et.G_TempEntity, et.gentity_get(cmdClient, "r.currentOrigin", 0), et.gentity_get(cmdClient, "r.currentOrigin", 1), et.gentity_get(cmdClient, "r.currentOrigin", 2) + 40, 78)
        pcall(et.G_TempEntity, et.gentity_get(cmdClient, "r.currentOrigin", 0), et.gentity_get(cmdClient, "r.currentOrigin", 1), et.gentity_get(cmdClient, "r.currentOrigin", 2) + 20, 78)
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "playsound "..cmdClient.." \"sound/weapons/impact/metal4.wav\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7Your helmet popped off!\";")
end

function commandPop(clientId, command, victim)
    local targets = {}

    if victim == nil or victim == "all" or victim == "-1" then
        for i = 0, tonumber(et.trap_Cvar_Get("sv_maxclients")) - 1 do
            if players.isConnected(i) and not (auth.isPlayerAllowed(i, auth.PERM_IMMUNE) and auth.getPlayerLevel(i) > auth.getPlayerLevel(clientId)) then
                local team = et.gentity_get(i, "sess.sessionTeam")

                if team == constants.TEAM_AXIS or team == constants.TEAM_ALLIES then
                    table.insert(targets, i)
                end
            end
        end
    else
        local cmdClient

        if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
            cmdClient = et.ClientNumberFromString(victim)
        else
            cmdClient = tonumber(victim)
        end

        if cmdClient == -1 or cmdClient == nil then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpop: ^9no or multiple matches for '^7"..victim.."^9'.\";")

            return true
        elseif not et.gentity_get(cmdClient, "pers.netname") then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpop: ^9no connected player by that name or slot #\";")

            return true
        end

        -- an immune player is protected from admins *below* their level, but a
        -- peer or superior (e.g. one Server Owner popping another) is allowed to
        -- target them. the higher-level check below still stops lower admins
        -- from touching someone above them.
        if auth.isPlayerAllowed(cmdClient, auth.PERM_IMMUNE) and auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpop: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")

            return true
        elseif auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpop: ^9sorry, but your intended victim has a higher admin level than you do.\";")

            return true
        elseif et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_AXIS and et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_ALLIES then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpop: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not playing.\";")

            return true
        elseif et.gentity_get(cmdClient, "health") <= 0 then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpop: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not alive.\";")

            return true
        end

        table.insert(targets, cmdClient)
    end

    if #targets == 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpop: ^9no players eligible for this command.\";")

        return true
    end

    for i = 1, #targets do
        popClient(targets[i])
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dpop: ^9popped the helmet"..(#targets > 1 and "s" or "").." off "..(#targets > 1 and #targets.." players" or "^7"..players.getName(targets[1]).."^9")..".\";")

    return true
end
commands.addadmin("pop", commandPop, auth.PERM_POP, "pops the helmet off a or all players", "^9([^3name|slot#^9])", nil, (settings.get("g_standalone") == 0))
