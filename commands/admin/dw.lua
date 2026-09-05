
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

-- !dw (drop weapons), as known from the NoQuarter mod. Removes the
-- current weapon of a player, forcing them to switch to their pistol
-- or knife.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

function commandDropWeapons(clientId, command, victim)
    local cmdClient

    if not et.GetCurrentWeapon or not et.RemoveWeaponFromPlayer then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddw: ^9this command is not supported by the current mod.\";")

        return true
    elseif victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddw usage: "..commands.getadmin("dw")["syntax"].."\";")

        return true
    elseif tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddw: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddw: ^9no connected player by that name or slot #\";")

        return true
    end

    if not auth.canTarget(clientId, cmdClient) then
        if auth.isTargetProtected(cmdClient) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddw: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")
        else
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddw: ^9sorry, but your intended victim has a higher admin level than you do.\";")
        end

        return true
    elseif et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_AXIS and et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_ALLIES then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddw: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not playing.\";")

        return true
    elseif et.gentity_get(cmdClient, "health") <= 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddw: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not alive.\";")

        return true
    end

    local weapon, _, _ = et.GetCurrentWeapon(cmdClient)

    local isRemoved = weapon > 2 and pcall(et.RemoveWeaponFromPlayer, cmdClient, weapon)

    if not isRemoved then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddw: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9has no weapon to drop.\";")

        return true
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "playsound "..cmdClient.." \"sound/weapons/grenade/gren_throw.wav\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^ddw: ^7"..players.getName(cmdClient).." ^9dropped their weapons.\";")

    return true
end
commands.addadmin("dw", commandDropWeapons, auth.PERM_DROPWEAPONS, "makes a player drop their current weapon", "^9[^3name|slot#^9]", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "nq"))
