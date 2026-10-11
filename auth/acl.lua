
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

-- the console (rcon, server console) runs admin commands as clientId -1337
local CONSOLE = -1337

-- Level ids come from three places that do not agree on their type: the
-- command line ("3", a string), LuaSQL's sqlite3 driver (3, or 3.0 on the
-- older builds that push every column as a double) and LuaSQL's mysql driver
-- ("3": MySQL hands back every column as a string). cachedLevels is keyed by
-- level id and the level checks compare them, so a "3" against a 3 either
-- misses the cache ("permission denied" for every command at that level) or
-- throws ("attempt to compare string with number" in !setlevel). Everything
-- in this module goes through here first.
local function toLevelId(id)
    local number = tonumber(id)

    if not number then
        return nil
    end

    return math.tointeger and math.tointeger(number) or number
end
acl.toLevelId = toLevelId

-- the cache entry for a level, created when the level is new to the cache
-- (a level added through `acl addlevel` on another server, a permission row
-- whose level is not in the level table...), so no caller indexes a nil
local function levelCache(levelId)
    levelId = toLevelId(levelId)

    if levelId == nil then
        return nil
    end

    if not cachedLevels[levelId] then
        cachedLevels[levelId] = {}
    end

    return cachedLevels[levelId]
end

-- the highest level id in the database: what the console counts as
local function highestLevelId()
    local highest = 0

    for levelId in pairs(cachedLevels) do
        if levelId > highest then
            highest = levelId
        end
    end

    return highest
end

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

    cachedLevels = {}

    local levels = db.getLevelsWithIds()
    for _, level in ipairs(levels) do
        levelCache(level["id"])
    end

    local permissions = db.getLevelPermissions()

    for _, permission in ipairs(permissions) do
        local levelPermissions = levelCache(permission["level_id"])

        if levelPermissions and not tables.contains(levelPermissions, permission["permission"]) then
            table.insert(levelPermissions, permission["permission"])
        end
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

                    table.insert(levelCache(levelId), permission)

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
    levelId = toLevelId(levelId)

    return levelId ~= nil and (db.getLevel(levelId) ~= nil)
end

function acl.addLevel(levelId, name)
    levelId = toLevelId(levelId)

    db.addLevel(levelId, name)

    cachedLevels[levelId] = {}
end

function acl.removeLevel(levelId)
    levelId = toLevelId(levelId)

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
    return cachedLevels[toLevelId(levelId)]
end

function acl.addLevelPermission(levelId, permission)
    levelId = toLevelId(levelId)

    if acl.isLevelAllowed(levelId, permission) then
        return
    end

    db.addLevelPermission(levelId, permission)

    table.insert(levelCache(levelId), permission)
end

function acl.removeLevelPermission(levelId, permission)
    levelId = toLevelId(levelId)

    db.removeLevelPermission(levelId, permission)

    local levelPermissions = cachedLevels[levelId]

    if not levelPermissions then
        return
    end

    -- backwards, so removing an entry does not skip the one after it
    for i = #levelPermissions, 1, -1 do
        if levelPermissions[i] == permission then
            table.remove(levelPermissions, i)
        end
    end
end

function acl.copyLevelPermissions(levelId, newLevelId)
    levelId, newLevelId = toLevelId(levelId), toLevelId(newLevelId)

    db.copyLevelPermissions(levelId, newLevelId)

    local target = levelCache(newLevelId)

    for _, permission in ipairs(cachedLevels[levelId] or {}) do
        if not tables.contains(target, permission) then
            table.insert(target, permission)
        end
    end
end

function acl.removeLevelPermissions(levelId)
    levelId = toLevelId(levelId)

    db.removeLevelPermissions(levelId)

    cachedLevels[levelId] = {}
end

function acl.isLevelAllowed(levelId, permission)
    local levelPermissions = cachedLevels[toLevelId(levelId)]

    return levelPermissions ~= nil and tables.contains(levelPermissions, permission)
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
    local guid = players.getGUID(clientId)

    -- a slot that is not connected has no GUID: treat it as a guest (level 0)
    if not guid then
        return 0
    end

    local player = db.getPlayer(guid)

    -- no row means no level: treat the player as a guest (level 0) instead of
    -- throwing, because this runs inside every permission check. always a
    -- number (MySQL hands back a string), the callers compare it.
    local level = player and toLevelId(player["level_id"]) or 0

    -- the console is rcon: commands.onServerCommand() runs its commands
    -- without a permission check, so it also outranks every level - with the
    -- stock schema it has a level 5 row, but without that row (or after
    -- `acl addlevel 6`) it would otherwise be unable to !setlevel anyone
    if clientId == CONSOLE then
        local highest = highestLevelId()

        if highest > level then
            level = highest
        end
    end

    return level
end

return acl
