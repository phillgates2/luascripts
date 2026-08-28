
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

-- !levinfo, as known from the silEnT mod. Lists all details of a
-- specific admin level.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local db = wolfa_requireModule("db.db")

local settings = wolfa_requireModule("util.settings")

function commandLevInfo(clientId, command, levelId)
    if not db.isConnected() then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlevinfo: ^9database is disabled.\";")

        return true
    elseif levelId == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlevinfo usage: "..commands.getadmin("levinfo")["syntax"].."\";")

        return true
    end

    local level = auth.getLevels()

    local levelName

    for _, knownLevel in pairs(level or {}) do
        if tonumber(knownLevel["id"]) == tonumber(levelId) then
            levelName = knownLevel["name"]
        end
    end

    if levelName == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlevinfo: ^9no level with number '^7"..levelId.."^9'.\";")

        return true
    end

    local permissions = auth.getLevelPermissions(tonumber(levelId)) or {}

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dInformation about level ^7"..levelId.."^d:\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dName:        ^2"..levelName.."\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dPermissions: ^2"..#permissions.."\";")

    local permissionsOnLine, permissionsBuffer = 0, ""

    for _, permission in pairs(permissions) do
        permissionsBuffer = permissionsBuffer ~= "" and permissionsBuffer.." "..permission or permission
        permissionsOnLine = permissionsOnLine + 1

        if permissionsOnLine == 4 then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^f"..permissionsBuffer.."\";")
            permissionsBuffer = ""
            permissionsOnLine = 0
        end
    end

    if permissionsBuffer ~= "" then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^f"..permissionsBuffer.."\";")
    end

    return true
end
commands.addadmin("levinfo", commandLevInfo, auth.PERM_SETLEVEL, "lists all details of a specific admin level", "^9[^3level#^9]", nil, (settings.get("g_standalone") == 0))
