
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

-- !panzerwar, !sniperwar and !riflewar, as known from the etpub and
-- silEnT mods. These game modes change the weapon of all playing
-- players, respawning players receive their new weapon on spawn. The
-- mode is automatically disabled at the end of the map.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local events = wolfa_requireModule("util.events")
local settings = wolfa_requireModule("util.settings")

-- weapon numbers (bg_public.h), the lua api does not know weapon names
local WEAPON_PANZERFAUST = 5
local WEAPON_GARAND = 25
local WEAPON_K43 = 31
local WEAPON_GARAND_SCOPE = 40
local WEAPON_K43_SCOPE = 41

local currentMode
local defaultMaxPanzers

local function getModeWeapon(mode, team)
    if mode == "panzerwar" then
        return WEAPON_PANZERFAUST
    elseif mode == "sniperwar" then
        return (team == constants.TEAM_AXIS) and WEAPON_K43_SCOPE or WEAPON_GARAND_SCOPE
    elseif mode == "riflewar" then
        return (team == constants.TEAM_AXIS) and WEAPON_K43 or WEAPON_GARAND
    end

    return nil
end

local function armClient(cmdClient)
    if not players.isConnected(cmdClient) then
        return
    end

    local team = et.gentity_get(cmdClient, "sess.sessionTeam")

    if team ~= constants.TEAM_AXIS and team ~= constants.TEAM_ALLIES then
        return
    end

    local weapon = getModeWeapon(currentMode, team)

    if weapon and et.AddWeaponToPlayer then
        pcall(et.AddWeaponToPlayer, cmdClient, weapon, 60, 10, 1)
    end
end

local function setMode(mode)
    currentMode = mode

    if mode == "panzerwar" then
        if defaultMaxPanzers == nil then
            defaultMaxPanzers = et.trap_Cvar_Get("team_maxPanzers")
        end

        et.trap_Cvar_Set("team_maxPanzers", "-1")
    elseif defaultMaxPanzers ~= nil then
        et.trap_Cvar_Set("team_maxPanzers", defaultMaxPanzers)

        defaultMaxPanzers = nil
    end
end

function commandWarMode(clientId, command, mode)
    local isEnabling = (mode == nil or string.lower(mode) == "on" or tonumber(mode) == 1)

    if isEnabling then
        setMode(command)

        for i = 0, tonumber(et.trap_Cvar_Get("sv_maxclients")) - 1 do
            armClient(i)
        end

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^d"..command..": ^9"..command.." has been ^7enabled^9!\";")
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^d"..command..": ^9use ^2!"..command.." off ^9to disable it.\";")
    else
        setMode(nil)

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^d"..command..": ^9"..command.." has been ^7disabled^9, changes apply on respawn.\";")
    end

    return true
end

function commandWarModeOnPlayerSpawn(clientId)
    if currentMode then
        armClient(clientId)
    end
end
events.handle("onPlayerSpawn", commandWarModeOnPlayerSpawn)

function commandWarModeOnGameShutdown(restartMap)
    -- the mods disable the war modes at the end of the map
    if currentMode then
        setMode(nil)
    end
end
events.handle("onGameShutdown", commandWarModeOnGameShutdown)

commands.addadmin("panzerwar", commandWarMode, auth.PERM_WARSETTINGS, "enables the panzerwar game mode (all players get a panzerfaust)", "^9(^hon|off^9)", nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
commands.addadmin("sniperwar", commandWarMode, auth.PERM_WARSETTINGS, "enables the sniperwar game mode (all players get a sniper rifle)", "^9(^hon|off^9)", nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
commands.addadmin("riflewar", commandWarMode, auth.PERM_WARSETTINGS, "enables the riflewar game mode (all players get a rifle)", "^9(^hon|off^9)", nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
