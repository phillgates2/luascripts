
-- WolfAdmin module for Wolfenstein: Enemy Territory servers.
-- Copyright (C) 2015-2020 Timo 'Timothy' Smit

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- at your option any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

-- !acl, the in-game counterpart of the console command of the same name. In
-- standalone mode the permissions of every level live in the database, so a
-- level that was never granted a permission sees "permission denied" for every
-- command guarded by it - this command is what fixes that without needing
-- rcon or direct access to the database.

local acl = wolfa_requireModule("auth.acl")

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local settings = wolfa_requireModule("util.settings")

local PERMISSIONS_PER_LINE = 3
local PERMISSION_WIDTH = 24

-- every permission this version of WolfAdmin knows about, used to catch typos
-- in !acl addpermission (a mistyped permission grants nothing at all)
local knownPermissions = {}

for key, permission in pairs(auth) do
    if string.find(key, "^PERM_") then
        knownPermissions[permission] = true
    end
end

local function reply(clientId, message)
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dacl: ^9"..message.."\";")
end

local function printList(clientId, entries)
    if #entries == 0 then
        reply(clientId, "(none)")

        return
    end

    local line, onLine = "", 0

    for _, entry in ipairs(entries) do
        line = line..string.format("%-"..PERMISSION_WIDTH.."s", entry)
        onLine = onLine + 1

        if onLine == PERMISSIONS_PER_LINE then
            reply(clientId, line)

            line, onLine = "", 0
        end
    end

    if onLine > 0 then
        reply(clientId, line)
    end
end

local function getLevelId(clientId, level)
    local levelId = tonumber(level)

    if not levelId then
        reply(clientId, "^1"..tostring(level).." ^9is not a level number.")

        return nil
    elseif not acl.isLevel(levelId) then
        reply(clientId, "there is no level ^7"..levelId.."^9, see ^2!acl listlevels^9.")

        return nil
    end

    return levelId
end

function commandAclListLevels(clientId)
    local levels = {}

    for _, level in ipairs(acl.getLevels()) do
        table.insert(levels, "^7"..level["id"].." ^9= "..level["name"])
    end

    printList(clientId, levels)
end

function commandAclListLevelPermissions(clientId, levelId)
    local permissions = acl.getLevelPermissions(levelId)

    if not permissions then
        reply(clientId, "level ^7"..levelId.." ^9has no permissions.")
    else
        table.sort(permissions)

        printList(clientId, permissions)
    end
end

function commandAclIsAllowed(clientId, levelId, permission)
    reply(clientId, "level ^7"..levelId.." ^9"..(acl.isLevelAllowed(levelId, permission) and "HAS" or "HAS NOT").." ^7"..permission)
end

function commandAclAddLevelPermission(clientId, levelId, permission)
    if acl.isLevelAllowed(levelId, permission) then
        reply(clientId, "level ^7"..levelId.." ^9already has ^7"..permission.."^9.")

        return
    end

    if not knownPermissions[permission] then
        reply(clientId, "^1warning: ^7"..permission.." ^9is not a permission WolfAdmin knows about.")
    end

    acl.addLevelPermission(levelId, permission)

    reply(clientId, "added ^7"..permission.." ^9to level ^7"..levelId.."^9.")
end

function commandAclRemoveLevelPermission(clientId, levelId, permission)
    if not acl.isLevelAllowed(levelId, permission) then
        reply(clientId, "level ^7"..levelId.." ^9does not have ^7"..permission.."^9.")

        return
    end

    acl.removeLevelPermission(levelId, permission)

    reply(clientId, "removed ^7"..permission.." ^9from level ^7"..levelId.."^9.")
end

function commandAclCopyLevelPermissions(clientId, levelId, newLevelId)
    acl.copyLevelPermissions(levelId, newLevelId)

    reply(clientId, "copied the permissions of level ^7"..levelId.." ^9to level ^7"..newLevelId.."^9.")
end

-- permissions no level has: every command needing one of them is denied for
-- every player on the server, whatever their level is
function commandAclMissingPermissions(clientId)
    local commandsByPermission = commands.collectPermissions()
    local permissions = {}

    for permission in pairs(commandsByPermission) do
        table.insert(permissions, permission)
    end

    local ungranted = acl.getUngrantedPermissions(permissions)

    if #ungranted == 0 then
        reply(clientId, "every permission used by a command is granted to at least one level.")

        return
    end

    reply(clientId, #ungranted.." permission(s) are granted to no level, so the commands needing them are denied for everyone:")

    printList(clientId, ungranted)

    reply(clientId, "grant one with ^2!acl addpermission [level] [permission]^9, the server console logs which command needs which permission.")
end

function commandAcl(clientId, command, action, arg1, arg2)
    if not action then
        reply(clientId, "usage: ^2!"..command.." ^9[^3listlevels^9|^3listpermissions^9|^3isallowed^9|^3addpermission^9|^3removepermission^9|^3copypermissions^9|^3missing^9]")

        return true
    end

    if action == "missing" then
        commandAclMissingPermissions(clientId)

        return true
    elseif action == "listlevels" then
        commandAclListLevels(clientId)

        return true
    end

    if not arg1 then
        reply(clientId, "usage: ^2!"..command.." "..action.." ^9[^3level#^9] [^3permission^9]")

        return true
    end

    local levelId = getLevelId(clientId, arg1)

    if not levelId then
        return true
    end

    -- listpermissions is the only action that takes a level and nothing else
    if action == "listpermissions" then
        commandAclListLevelPermissions(clientId, levelId)

        return true
    elseif not arg2 then
        reply(clientId, "usage: ^2!"..command.." "..action.." ^9[^3level#^9] [^3permission^9]")

        return true
    end

    if action == "isallowed" then
        commandAclIsAllowed(clientId, levelId, arg2)
    elseif action == "addpermission" then
        commandAclAddLevelPermission(clientId, levelId, arg2)
    elseif action == "removepermission" then
        commandAclRemoveLevelPermission(clientId, levelId, arg2)
    elseif action == "copypermissions" then
        local newLevelId = getLevelId(clientId, arg2)

        if newLevelId then
            commandAclCopyLevelPermissions(clientId, levelId, newLevelId)
        end
    else
        reply(clientId, "unknown action ^7"..action.."^9, see ^2!acl^9.")
    end

    return true
end
commands.addadmin("acl", commandAcl, auth.PERM_SETLEVEL, "lists, checks and changes the permissions of an admin level", "^9(^3listlevels^9|^3listpermissions ^3level#^9|^3isallowed ^3level# permission^9|^3addpermission ^3level# permission^9|^3removepermission ^3level# permission^9|^3copypermissions ^3level# level#^9|^3missing^9)", nil, (settings.get("g_standalone") == 0))
