
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

-- !pconexec, as known from the etoz mod (github.com/phillgates2/etoz). Sends
-- the 'pconexec' server command to a player's client, which makes the client
-- execute the given console command, e.g. '!pconexec bob cg_thirdperson 1'.
-- The server side matches the etoz wire format exactly; the client only runs
-- the command when its mod implements the handler (etoz does, a stock
-- ET: Legacy client reports an unknown command instead), which the reply
-- mentions so the result is not a surprise.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local settings = wolfa_requireModule("util.settings")

function commandPconexec(clientId, command, victim, ...)
    local args = {...}

    if victim == nil or #args < 1 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpconexec usage: "..commands.getadmin("pconexec")["syntax"].."\";")

        return true
    end

    local cmdClient

    if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpconexec: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpconexec: ^9no connected player by that name or slot #\";")

        return true
    end

    if auth.isPlayerAllowed(cmdClient, auth.PERM_IMMUNE) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpconexec: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")

        return true
    elseif auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpconexec: ^9sorry, but your intended victim has a higher admin level than you do.\";")

        return true
    end

    -- the etoz client reads the command and a single value from the
    -- 'pconexec' server command, so anything beyond the second argument
    -- would never reach the client
    local clientCommand = string.gsub(args[1], "[\";\r\n]", "")
    local clientValue = #args > 1 and string.gsub(args[2], "[\";\r\n]", "") or nil

    et.trap_SendServerCommand(cmdClient, "pconexec "..clientCommand..(clientValue and " "..clientValue or ""))

    local sentCommand = clientCommand..(clientValue and " "..clientValue or "")

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dpconexec: ^9sent '^7"..sentCommand.."^9' to ^7"..players.getName(cmdClient).."^9's console (only clients that support pconexec run it).\";")

    return true
end
commands.addadmin("pconexec", commandPconexec, auth.PERM_PCONEXEC, "executes a console command on a player's client (etoz clients)", "^9[^3name|slot#^9] [^3command^9] (^hvalue^9)", nil, (settings.get("g_standalone") == 0))
