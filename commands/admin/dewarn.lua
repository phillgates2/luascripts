
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

-- !dewarn, as known from the etpub and silEnT mods. Shows the warnings
-- of a player, optionally a specific warning is removed. Requires the
-- player history (g_playerHistory) to be enabled.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local db = wolfa_requireModule("db.db")

local history = wolfa_requireModule("admin.history")

local players = wolfa_requireModule("players.players")

local settings = wolfa_requireModule("util.settings")

function commandDeWarn(clientId, command, victim, warningId)
    if not db.isConnected() or settings.get("g_playerHistory") == 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddewarn: ^9player history is disabled.\";")

        return true
    elseif victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddewarn usage: "..commands.getadmin("dewarn")["syntax"].."\";")

        return true
    end

    local cmdClient

    if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddewarn: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddewarn: ^9no connected player by that name or slot #\";")

        return true
    end

    local warnings = {}

    for _, item in pairs(history.getList(cmdClient, 100, 0) or {}) do
        if item["type"] == "warn" then
            table.insert(warnings, item)
        end
    end

    if #warnings == 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddewarn: ^7"..players.getName(cmdClient).." ^9has no warnings.\";")

        return true
    end

    if warningId == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddewarn: ^9warnings for ^7"..players.getName(cmdClient).."^9:\";")

        for i, warning in pairs(warnings) do
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^f"..string.format("%3s", i).." ^7"..os.date("%d/%m/%Y %H:%M", warning["datetime"]).." ^f"..warning["reason"].."\";")
        end

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^9Type ^2!dewarn ^d[name|slot#] [warning#] ^9to remove a warning.\";")
    else
        local warning = warnings[tonumber(warningId)]

        if warning == nil then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddewarn: ^9no warning with number '^7"..warningId.."^9'.\";")

            return true
        end

        history.remove(cmdClient, warning["id"])

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^ddewarn: ^9warning ^7"..warningId.." ^9of ^7"..players.getName(cmdClient).." ^9has been removed.\";")
    end

    return true
end
commands.addadmin("dewarn", commandDeWarn, auth.PERM_WARN, "shows the warnings of a player or removes one", "^9[^3name|slot#^9] (^hwarning#^9)", nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
