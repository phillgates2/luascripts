
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

-- !ammopack, as known from the NoQuarter mod. Gives an ammo pack to a
-- player, refilling the ammo and clip of their current weapon.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local settings = wolfa_requireModule("util.settings")

function commandAmmoPack(clientId, command, victim)
    local cmdClient

    if victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dammopack usage: "..commands.getadmin("ammopack")["syntax"].."\";")

        return true
    elseif tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dammopack: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dammopack: ^9no connected player by that name or slot #\";")

        return true
    end

    if not et.GetCurrentWeapon or not et.AddWeaponToPlayer then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dammopack: ^9this command is not supported by the current mod.\";")

        return true
    end

    local weapon, ammo, ammoclip = et.GetCurrentWeapon(cmdClient)

    et.AddWeaponToPlayer(cmdClient, weapon, ammo + 30, ammoclip + 30, 0)

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7You have received an ammo pack from ^7"..players.getName(clientId).."^7.\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "playsound "..cmdClient.." \"sound/misc/ammo_pickup.wav\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dammopack: ^7"..players.getName(cmdClient).." ^9received an ammo pack.\";")

    return true
end
commands.addadmin("ammopack", commandAmmoPack, auth.PERM_AMMOPACK, "gives an ammo pack to a player", "^9[^3name|slot#^9]", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "nq"))
