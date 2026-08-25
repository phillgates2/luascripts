
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

-- !levlist, as known from the silEnT mod. Lists all admin levels
-- defined in the WolfAdmin database.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local db = wolfa_requireModule("db.db")

local settings = wolfa_requireModule("util.settings")

function commandLevList(clientId, command)
    if not db.isConnected() then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlevlist: ^9database is disabled.\";")

        return true
    end

    local levels = auth.getLevels()

    if #levels == 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlevlist: ^9no admin levels have been defined.\";")

        return true
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlevlist: ^9"..#levels.." admin levels defined:\";")

    for _, level in pairs(levels) do
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^f"..string.format("%2s", level["id"]).." ^7"..level["name"].." ^9("..level["players"].." players)\";")
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^9Type ^2!levinfo ^d[level#] ^9for detailed information.\";")

    return true
end
commands.addadmin("levlist", commandLevList, auth.PERM_SETLEVEL, "lists all admin levels", nil, nil, (settings.get("g_standalone") == 0))
