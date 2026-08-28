
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

local db = wolfa_requireModule("db.db")

local players = wolfa_requireModule("players.players")

local events = wolfa_requireModule("util.events")
local settings = wolfa_requireModule("util.settings")
local tables = wolfa_requireModule("util.tables")

local acl = {}

local cachedLevels = {}
local cachedClients = {}

-- Permissions this fork's commands are guarded by that a stock WolfAdmin
-- database (database/new/sqlite.sql) never grants to any level, so every
-- command below them answers "permission denied" for every player - the
-- Server Owner included - until the permission is granted. The same grants
-- exist as a manual script (database/upgrade/permissions/), but they are
-- also applied automatically on startup (see acl.applyDefaultPermissions)
-- so commands such as !give, !lol and !firegod work out of the box.
--
-- Everything is granted to level 5 (Server Owner) ONLY: levels 3 and 4 keep
-- exactly the permissions the stock schema gives them, so no lower admin
-- gains commands or privileges from this.
--
-- Set g_defaultPermissions to 0 in wolfadmin.toml ([acl] defaults = 0) or as
-- a server cvar to manage permissions strictly by hand.
local defaultPermissions = {
    -- level 5 (Server Owner): everything the fork adds, all in one place
    [5] = {
        "banguid",
        "banip",
        "lockplayer", -- the stock schema grants the plural 'lockplayers', which nothing checks
        "resetxp_self",
        "resetxp",
        "subnetban",
        "ammopack",
        "medpack",
        "revive",
        "disguise",
        "poison",
        "nade",
        "lol",
        "giball",
        "throwall",
        "crazysettings",
        "warsettings",
        "multiview", -- ET: Legacy only, and only while g_multiview is enabled
        "cheats", -- !give, !firegod
        "pconexec", -- !pconexec
        "immune", -- without this no level is protected from other admins' commands
    },
}

function acl.onClientConnect(clientId, firstTime, isBot)
    if settings.get("g_standalone") ~= 0 and db.isConnected() then
        local guid = et.Info_ValueForKey(et.trap_GetUserinfo(clientId), "cl_guid")
        local player = db.getPlayer(guid)

        if player then
            cachedClients[clientId] = {}

            local permissions = db.getPlayerPermissions(player["id"])

            for _, permission in ipairs(permissions) do
                table.insert(cachedClients[clientId], permission["permission"])
            end
        end
    end
end
events.handle("onClientConnect", acl.onClientConnect)

function acl.readPermissions()
    -- read level permissions into a cache file (can be loaded at mod start)
    -- should probably cache current players' permissions as well, then
    -- read in new players' permissions as they join the server

    local levels = db.getLevelsWithIds()
    for _, level in ipairs(levels) do
        cachedLevels[level["id"]] = {}
    end

    local permissions = db.getLevelPermissions()

    for _, permission in ipairs(permissions) do
        table.insert(cachedLevels[permission["level_id"]], permission["permission"])
    end

    acl.applyDefaultPermissions()
end

-- grants the fork's default permissions (see defaultPermissions) to the
-- levels they belong to, but only where the level exists and does not have
-- the permission yet. runs on every game init, so a database that is
-- restored or replaced heals itself on the next map load.
function acl.applyDefaultPermissions()
    if settings.get("g_defaultPermissions") == 0 then
        return
    end

    local granted = 0

    for levelId, permissions in pairs(defaultPermissions) do
        if cachedLevels[levelId] then -- the level must exist in the database
            for _, permission in ipairs(permissions) do
                if not acl.isLevelAllowed(levelId, permission) then
                    db.addLevelPermission(levelId, permission)

                    table.insert(cachedLevels[levelId], permission)

                    granted = granted + 1
                end
            end
        end
    end

    if granted > 0 then
        outputDebug("Granted "..granted.." default permission(s) to the Server Owner level (disable with g_defaultPermissions 0).", 3)
    end
end

function acl.clearCache()
    cachedLevels = {}
end

function acl.isPlayerAllowed(clientId, permission, playerOnly)
    local level = acl.getPlayerLevel(clientId)

    return (not playerOnly and acl.isLevelAllowed(level, permission)) or (cachedClients[clientId] ~= nil and tables.contains(cachedClients[clientId], permission))
end

function acl.getLevels()
    return db.getLevels()
end

function acl.isLevel(levelId)
    return (db.getLevel(levelId) ~= nil)
end

function acl.addLevel(levelId, name)
    db.addLevel(levelId, name)

    cachedLevels[levelId] = {}
end

function acl.removeLevel(levelId)
    db.removeLevel(levelId)

    cachedLevels[levelId] = nil
end

function acl.reLevel(levelId, newLevelId)
    db.reLevel(levelId, newLevelId)
end

function acl.getLevelName(levelId)
    local level = db.getLevel(levelId)

    -- the name ends up in chat output, so hand back a string when the level
    -- record is missing instead of nil, which breaks the caller
    return level and level["name"] or "unknown"
end

function acl.getLevelPermissions(levelId)
    return cachedLevels[levelId]
end

function acl.addLevelPermission(levelId, permission)
    db.addLevelPermission(levelId, permission)

    table.insert(cachedLevels[levelId], permission)
end

function acl.removeLevelPermission(levelId, permission)
    db.removeLevelPermission(levelId, permission)

    for i, levelPermission in ipairs(cachedLevels[levelId]) do
        if levelPermission == permission then
            table.remove(cachedLevels[levelId], i)
        end
    end
end

function acl.copyLevelPermissions(levelId, newLevelId)
    db.copyLevelPermissions(levelId, newLevelId)

    cachedLevels[newLevelId] = tables.merge(cachedLevels[newLevelId], cachedLevels[levelId])
end

function acl.removeLevelPermissions(levelId)
    db.removeLevelPermissions(levelId)

    cachedLevels[levelId] = {}
end

function acl.isLevelAllowed(levelId, permission)
    return cachedLevels[levelId] ~= nil and tables.contains(cachedLevels[levelId], permission)
end

function acl.isPermissionGranted(permission)
    for _, levelPermissions in pairs(cachedLevels) do
        if tables.contains(levelPermissions, permission) then
            return true
        end
    end

    return false
end

function acl.getUngrantedPermissions(permissions)
    local ungranted = {}

    for _, permission in ipairs(permissions) do
        if not acl.isPermissionGranted(permission) then
            table.insert(ungranted, permission)
        end
    end

    table.sort(ungranted)

    return ungranted
end

-- a permission that no level has can never be satisfied: every command guarded
-- by it answers "permission denied" for every player on the server, no matter
-- how high their level is. commandsByPermission maps a permission to the list
-- of commands that need it (see commands.collectPermissions()).
function acl.auditPermissions(commandsByPermission)
    local permissions = {}

    for permission in pairs(commandsByPermission) do
        table.insert(permissions, permission)
    end

    local ungranted = acl.getUngrantedPermissions(permissions)

    if #ungranted == 0 then
        return
    end

    outputDebug(#ungranted.." permission(s) are not granted to any level, so the commands below are denied for every player:", 3)

    for _, permission in ipairs(ungranted) do
        outputDebug("  '"..permission.."' is needed by: "..table.concat(commandsByPermission[permission], ", "), 3)
    end

    outputDebug("Grant a permission with '!acl addpermission [level] [permission]'.", 3)
end

function acl.getPlayerPermissions(clientId)
    return cachedClients[clientId]
end

function acl.addPlayerPermission(clientId, permission)
    if not cachedClients[clientId] then
        -- not a connected player (the console passes clientId -1337): there is
        -- no player record to attach a permission to
        if clientId < 0 then
            return
        end

        cachedClients[clientId] = {}
    end

    db.addPlayerPermission(db.getPlayerId(clientId), permission)

    table.insert(cachedClients[clientId], permission)
end

function acl.removePlayerPermission(clientId, permission)
    if not cachedClients[clientId] then
        return
    end

    db.removePlayerPermission(db.getPlayerId(clientId), permission)

    for i, levelPermission in ipairs(cachedClients[clientId]) do
        if levelPermission == permission then
            table.remove(cachedClients[clientId], i)
        end
    end
end

function acl.copyPlayerPermissions(clientId, newClientId)
    if not cachedClients[clientId] or not cachedClients[newClientId] then
        return
    end

    db.copyPlayerPermissions(db.getPlayerId(clientId), db.getPlayerId(newClientId))

    cachedClients[newClientId] = tables.copy(cachedClients[clientId])
end

function acl.removePlayerPermissions(clientId)
    db.removePlayerPermissions(db.getPlayerId(clientId))

    cachedClients[clientId] = {}
end

function acl.getPlayerLevel(clientId)
    local player = db.getPlayer(players.getGUID(clientId))

    -- no row means no level: treat the player as a guest (level 0) instead of
    -- throwing, because this runs inside every permission check
    return player and player["level_id"] or 0
end

return acl
