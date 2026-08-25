
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

-- !pip, as known from the etpub, NoQuarter and silEnT mods. Draws
-- sparks (pixie dust) around a player. On ET: Legacy real sparks are
-- drawn, on other mods a sound is played instead.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

local function pipClient(cmdClient)
    if et.G_TempEntity and string.lower(et.trap_Cvar_Get("gamename") or "") == "legacy" then
        -- EV_SPARKS = 78 (ET: Legacy)
        pcall(et.G_TempEntity, et.gentity_get(cmdClient, "r.currentOrigin", 0), et.gentity_get(cmdClient, "r.currentOrigin", 1), et.gentity_get(cmdClient, "r.currentOrigin", 2) + 40, 78)
        pcall(et.G_TempEntity, et.gentity_get(cmdClient, "r.currentOrigin", 0), et.gentity_get(cmdClient, "r.currentOrigin", 1), et.gentity_get(cmdClient, "r.currentOrigin", 2) + 20, 78)
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "playsound "..cmdClient.." \"sound/weapons/impact/metal4.wav\";")
end

function commandPip(clientId, command, victim)
    local targets = {}

    if victim == nil or victim == "all" or victim == "-1" then
        for i = 0, tonumber(et.trap_Cvar_Get("sv_maxclients")) - 1 do
            if players.isConnected(i) and not auth.isPlayerAllowed(i, auth.PERM_IMMUNE) then
                table.insert(targets, i)
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
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpip: ^9no or multiple matches for '^7"..victim.."^9'.\";")

            return true
        elseif not et.gentity_get(cmdClient, "pers.netname") then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpip: ^9no connected player by that name or slot #\";")

            return true
        end

        if auth.isPlayerAllowed(cmdClient, auth.PERM_IMMUNE) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpip: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")

            return true
        elseif auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpip: ^9sorry, but your intended victim has a higher admin level than you do.\";")

            return true
        end

        table.insert(targets, cmdClient)
    end

    if #targets == 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpip: ^9no players eligible for this command.\";")

        return true
    end

    for i = 1, #targets do
        pipClient(targets[i])
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dpip: ^9sparks fly around "..(#targets > 1 and #targets.." players" or "^7"..players.getName(targets[1]).."^9")..".\";")

    return true
end
commands.addadmin("pip", commandPip, auth.PERM_POP, "draws sparks (pixie dust) around a or all players", "^9([^3name|slot#^9])", nil, (settings.get("g_standalone") == 0))
