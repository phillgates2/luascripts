
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

-- !baninfo, as known from the silEnT mod. Shows detailed information
-- of a ban in the ban list, use !showbans to find the ban number.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local bans = wolfa_requireModule("admin.bans")

local db = wolfa_requireModule("db.db")

local settings = wolfa_requireModule("util.settings")

function commandBanInfo(clientId, command, banId)
    if not db.isConnected() then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbaninfo: ^9ban database is disabled.\";")

        return true
    elseif banId == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbaninfo usage: "..commands.getadmin("baninfo")["syntax"].."\";")

        return true
    end

    local ban = bans.get(tonumber(banId))

    if ban == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dbaninfo: ^9no ban with number '^7"..banId.."^9'.\";")

        return true
    end

    local victim = db.getLastAlias(ban["victim_id"])
    local invoker = db.getLastAlias(ban["invoker_id"])

    local expires = "never"

    if tonumber(ban["duration"]) > 0 then
        expires = os.date("%d/%m/%Y %H:%M", ban["expires"])
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dInformation about ban ^7"..banId.."^d:\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dName:    ^2"..(victim and victim["alias"] or "unknown").."\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dIssued:  ^2"..os.date("%d/%m/%Y %H:%M", ban["issued"]).." ^9by ^2"..(invoker and invoker["alias"] or "unknown").."\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dExpires: ^2"..expires.."\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dReason:  ^2"..ban["reason"].."\";")

    return true
end
commands.addadmin("baninfo", commandBanInfo, auth.PERM_LISTBANS, "shows detailed information about a specific ban", "^9[^3ban#^9]", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "silent"))
