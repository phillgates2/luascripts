
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

-- !spree and !tspree, as known from the etpub and silEnT mods. !spree
-- shows the current killing spree of a player, !tspree shows the top
-- sprees of all connected players.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local sprees = wolfa_requireModule("game.sprees")

local settings = wolfa_requireModule("util.settings")

function commandSpree(clientId, command, victim)
    local cmdClient = clientId

    if victim ~= nil then
        if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
            cmdClient = et.ClientNumberFromString(victim)
        else
            cmdClient = tonumber(victim)
        end

        if cmdClient == -1 or cmdClient == nil then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dspree: ^9no or multiple matches for '^7"..victim.."^9'.\";")

            return true
        elseif not et.gentity_get(cmdClient, "pers.netname") then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dspree: ^9no connected player by that name or slot #\";")

            return true
        end
    end

    if cmdClient < 0 then
        return false
    end

    local currentSpree = sprees.getCurrent(cmdClient, sprees.TYPE_KILL)

    if currentSpree > 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dspree: ^7"..players.getName(cmdClient).." ^9is on a killing spree of ^7"..currentSpree.."^9.\";")
    else
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dspree: ^7"..players.getName(cmdClient).." ^9has no current killing spree.\";")
    end

    return true
end

function commandTopSpree(clientId, command, amount)
    local topPlayers = {}

    for i = 0, tonumber(et.trap_Cvar_Get("sv_maxclients")) - 1 do
        if players.isConnected(i) then
            local currentSpree = sprees.getCurrent(i, sprees.TYPE_KILL)

            if currentSpree > 0 then
                table.insert(topPlayers, { ["clientId"] = i, ["spree"] = currentSpree })
            end
        end
    end

    if #topPlayers == 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dtspree: ^9nobody is on a killing spree.\";")

        return true
    end

    table.sort(topPlayers, function(a, b) return a["spree"] > b["spree"] end)

    local showAmount = tonumber(amount) or 5

    if showAmount < 1 then
        showAmount = 1
    elseif showAmount > 20 then
        showAmount = 20
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dtspree: ^9top killing spreers:\";")

    for i = 1, math.min(showAmount, #topPlayers) do
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^f"..string.format("%2s", i)..". ^7"..players.getName(topPlayers[i]["clientId"]).." ^9- ^7"..topPlayers[i]["spree"].." ^9kills\";")
    end

    return true
end
commands.addadmin("spree", commandSpree, auth.PERM_LISTSPREES, "shows the current killing spree of a player", "^9([^3name|slot#^9])", nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
commands.addadmin("tspree", commandTopSpree, auth.PERM_LISTSPREES, "shows the top killing spreers of all connected players", "^9(^hamount^9)", nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
