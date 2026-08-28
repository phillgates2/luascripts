
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

-- !firegod, as known from the etoz mod (github.com/phillgates2/etoz). Makes a
-- player an invincible flaming god: the victim is set on fire, but takes no
-- damage at all. Calling the command again turns the player mortal. The
-- optional noclip argument matches the etoz syntax; the engine exposes the
-- field read-only to Lua, so it is attempted and reported when it fails.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

-- the etoz mod keeps a firegod burning for 1,800,000 ms (thirty minutes)
local FIREGOD_TIME = 1800000

function commandFiregod(clientId, command, victim, ...)
    if victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dfiregod usage: "..commands.getadmin("firegod")["syntax"].."\";")

        return true
    end

    local cmdClient

    if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dfiregod: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dfiregod: ^9no connected player by that name or slot #\";")

        return true
    end

    if auth.isPlayerAllowed(cmdClient, auth.PERM_IMMUNE) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dfiregod: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")

        return true
    elseif auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dfiregod: ^9sorry, but your intended victim has a higher admin level than you do.\";")

        return true
    elseif et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_AXIS and et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_ALLIES then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dfiregod: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9must be on a team.\";")

        return true
    elseif et.gentity_get(cmdClient, "health") <= 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dfiregod: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9must be alive.\";")

        return true
    end

    local args = {...}
    local noclip = #args > 0 and not string.find(string.lower(args[1]), "^no?$") and not string.find(string.lower(args[1]), "^off$")
    local now = et.trap_Milliseconds()

    -- a firegod takes no damage at all; the engine resets takedamage to
    -- true on respawn, which doubles as the toggle state
    local isFiregod = (tonumber(et.gentity_get(cmdClient, "takedamage")) or 1) == 0

    if isFiregod then
        et.gentity_set(cmdClient, "takedamage", 1)
        pcall(et.gentity_set, cmdClient, "s.onFireEnd", now) -- extinguish

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7"..players.getName(clientId).." ^9set you mortal player\";")
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dfiregod: ^7"..players.getName(cmdClient).." ^9is a mortal player again.\";")

        return true
    end

    et.gentity_set(cmdClient, "takedamage", 0)

    -- the visual burning, supported by etpub based mods and ET: Legacy
    pcall(et.gentity_set, cmdClient, "s.onFireStart", now)
    pcall(et.gentity_set, cmdClient, "s.onFireEnd", now + FIREGOD_TIME)

    if noclip then
        -- 'client.noclip' is read-only in ET: Legacy's Lua api
        local isSet = pcall(et.gentity_set, cmdClient, "noclip", 1)

        if not isSet then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dfiregod: ^9noclip is not supported by this engine, ^7"..players.getName(cmdClient).." ^9burns without it.\";")
        end
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7"..players.getName(clientId).." ^9set you invincible flaming god\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "playsound "..cmdClient.." \"sound/player/fry.wav\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dfiregod: ^7"..players.getName(cmdClient).." ^9is an invincible flaming god.\";")

    return true
end
commands.addadmin("firegod", commandFiregod, auth.PERM_CHEATS, "makes a player an invincible burning god (toggle)", "^9[^3name|slot#^9] (^hnoclip^9)", nil, (settings.get("g_standalone") == 0))
