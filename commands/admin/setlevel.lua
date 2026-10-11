
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

local admin = wolfa_requireModule("admin.admin")
local history = wolfa_requireModule("admin.history")

local auth = wolfa_requireModule("auth.auth")

local db = wolfa_requireModule("db.db")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local settings = wolfa_requireModule("util.settings")

-- add-on mode: the host mod owns the admin levels (shrubbot.cfg), so the
-- command only records the change and hands the line back to the mod. When
-- there is no backend at all - `standalone = 0` on a mod without a shrubbot
-- flag table, e.g. ET:Legacy - nothing would handle it, and the command used
-- to return without a word ("!setlevel does not do anything"); say so instead.
function commandSetLevelPassThrough(clientId, command, victim, level)
    if not auth.isBackendAvailable() then
        commands.reply(clientId, "^dsetlevel: ^9no admin backend is available - add-on mode needs a mod with shrubbot flags (see wolfadmin.toml, standalone = 1)")

        return true
    elseif victim == nil or level == nil then
        commands.reply(clientId, "^dsetlevel usage: "..commands.getadmin("setlevel")["syntax"])

        return true
    end

    local cmdClient

    if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    -- -1 is what the engine's Lua binding used to answer for "none or more
    -- than one match"; it hands back nil for that now
    if cmdClient == -1 or cmdClient == nil then
        commands.reply(clientId, "^dsetlevel: ^9no or multiple matches for '^7"..tostring(victim).."^9'.")

        return true
    elseif not players.isConnected(cmdClient) then
        commands.reply(clientId, "^dsetlevel: ^9no connected player by that name or slot #")

        return true
    end

    level = tonumber(level)

    if not level then
        commands.reply(clientId, "^dsetlevel: ^9'^7"..tostring(level).."^9' is not a level number")

        return true
    end

    -- the mod applies the level itself (the function returns false, so the
    -- engine's own command handling - the mod - runs after this handler);
    -- only the history entry is ours to write
    local victimLevel = tonumber(auth.getPlayerLevel(cmdClient)) or 0
    local invokerLevel = tonumber(auth.getPlayerLevel(clientId)) or 0

    if victimLevel > invokerLevel then
        return false
    elseif level > invokerLevel then
        return false
    end

    history.add(cmdClient, clientId, "level", tostring(level))

    return false
end
commands.addadmin("setlevel", commandSetLevelPassThrough, auth.PERM_SETLEVEL, "sets the admin level of a player", "^9[^3name|slot#^9] ^9[^3level^9]", true, (settings.get("g_standalone") ~= 0))

-- standalone mode: the level lives in WolfAdmin's database and this handler
-- does the work.
function commandSetLevel(clientId, command, victim, level)
    -- !setlevel needs the ACL and player tables in the database. The console
    -- command path bypasses permission checks, so fail clearly here if the
    -- standalone database did not connect instead of calling a missing auth
    -- backend (or a missing database method) below.
    if not db.isConnected() then
        commands.reply(clientId, "^dsetlevel: ^9the database is unavailable; admin levels cannot be changed.")

        return true
    elseif type(auth.getPlayerLevel) ~= "function" then
        commands.reply(clientId, "^dsetlevel: ^9the authorization backend is unavailable; admin levels cannot be changed.")

        return true
    end

    local cmdClient

    if victim == nil or level == nil then
        commands.reply(clientId, "^dsetlevel usage: "..commands.getadmin("setlevel")["syntax"])

        return true
    elseif tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        commands.reply(clientId, "^dsetlevel: ^9no or multiple matches for '^7"..victim.."^9'.")

        return true
    elseif not players.isConnected(cmdClient) then
        commands.reply(clientId, "^dsetlevel: ^9no connected player by that name or slot #")

        return true
    end

    -- a level that is not a whole number is a typo, not a request for level 0
    -- (which is what `tonumber(level) or 0` made of it: a mistyped
    -- `!setlevel Alice 5` demoted Alice to guest)
    local levelId = string.match(tostring(level), "^%d+$") and tonumber(level)

    if not levelId then
        commands.reply(clientId, "^dsetlevel: ^9'^7"..level.."^9' is not a level number, see ^2!acl listlevels^9.")

        return true
    end

    level = math.tointeger and math.tointeger(levelId) or levelId

    -- always numbers: the mysql driver hands levels back as strings
    local victimLevel = tonumber(auth.getPlayerLevel(cmdClient)) or 0
    local invokerLevel = tonumber(auth.getPlayerLevel(clientId)) or 0

    if victimLevel > invokerLevel then
        commands.reply(clientId, "^dsetlevel: ^9sorry, but your intended victim has a higher admin level than you do.")

        return true
    elseif not db.getLevel(level) then
        commands.reply(clientId, "^dsetlevel: ^9this admin level does not exist.")

        return true
    elseif level > invokerLevel then
        commands.reply(clientId, "^dsetlevel: ^9you may not setlevel higher than your current level.")

        return true
    end

    if not admin.setPlayerLevel(cmdClient, level, clientId) then
        -- no player row and none could be created (a client without a GUID):
        -- say so instead of announcing a level that was never stored
        commands.reply(clientId, "^dsetlevel: ^9could not store the level of ^7"..et.gentity_get(cmdClient, "pers.netname").."^9, the player has no database record.")

        return true
    end

    history.add(cmdClient, clientId, "level", tostring(level))

    local announcement = "^dsetlevel: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is now a level ^7"..level.." ^9player."

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \""..announcement.."\";")

    -- the players get the announcement above; the server console and rcon get
    -- no chat at all, and a !setlevel that worked used to answer them with
    -- nothing whatsoever - which is what "does not do anything" looks like
    -- from an rcon client
    if clientId == -1337 then
        commands.reply(clientId, announcement)
    end

    return true
end
commands.addadmin("setlevel", commandSetLevel, auth.PERM_SETLEVEL, "sets the admin level of a player", "^9[^3name|slot#^9] ^9[^3level^9]", nil, (settings.get("g_standalone") == 0))
