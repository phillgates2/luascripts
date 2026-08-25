
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

-- !uptime, as known from the etpub, NoQuarter and silEnT mods.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local settings = wolfa_requireModule("util.settings")

function commandUptime(clientId, command)
    local uptime = math.floor(et.trap_Milliseconds() / 1000)

    local days = math.floor(uptime / 86400)
    local hours = math.floor((uptime % 86400) / 3600)
    local minutes = math.floor((uptime % 3600) / 60)
    local seconds = uptime % 60

    local uptimeString = ""

    if days > 0 then
        uptimeString = uptimeString..days.." day"..(days ~= 1 and "s" or "").." "
    end

    uptimeString = uptimeString..string.format("%dh %dm %ds", hours, minutes, seconds)

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^duptime: ^9server has been up for ^7"..uptimeString.."^9.\";")

    return true
end
commands.addadmin("uptime", commandUptime, auth.PERM_UPTIME, "shows how long the server has been up and running", nil, nil, (settings.get("g_standalone") == 0))
