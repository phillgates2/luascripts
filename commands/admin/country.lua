
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

-- !country, as known from the silEnT mod. Displays the country of a
-- player. WolfAdmin has no GeoIP integration, so the ip address is
-- shown instead.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local settings = wolfa_requireModule("util.settings")

function commandCountry(clientId, command, victim)
    local cmdClient = clientId

    if victim ~= nil then
        if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
            cmdClient = et.ClientNumberFromString(victim)
        else
            cmdClient = tonumber(victim)
        end

        if cmdClient == -1 or cmdClient == nil then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dcountry: ^9no or multiple matches for '^7"..victim.."^9'.\";")

            return true
        elseif not et.gentity_get(cmdClient, "pers.netname") then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dcountry: ^9no connected player by that name or slot #\";")

            return true
        end
    end

    if cmdClient < 0 then
        return false
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dcountry: ^7"..players.getName(cmdClient).." ^9connects from ip ^7"..players.getIP(cmdClient).."^9.\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^9WolfAdmin has no GeoIP integration, the ip address is shown instead.\";")

    return true
end
commands.addadmin("country", commandCountry, auth.PERM_LISTPLAYERS, "displays the ip address of a player", "^9([^3name|slot#^9])", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "silent"))
