
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

-- !give, as known from the NoQuarter mod. Gives a weapon or item to a
-- player. Weapon names are translated to the (ET: Legacy) weapon
-- numbers, since the lua api does not know the weapon names.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local settings = wolfa_requireModule("util.settings")

local weapons = {
    ["knife"] = 1, ["grenade"] = 9, ["panzerfaust"] = 5, ["flamethrower"] = 6,
    ["sten"] = 10, ["thompson"] = 8, ["mp40"] = 3, ["kar98"] = 23, ["carbine"] = 24,
    ["garand"] = 25, ["k43"] = 31, ["fg42"] = 32, ["mg42"] = 30, ["mortar"] = 34,
    ["garand_scope"] = 40, ["k43_scope"] = 41, ["akimbo_colt"] = 35, ["akimbo_luger"] = 36
}

function commandGive(clientId, command, victim, item, amount)
    if not et.AddWeaponToPlayer then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9this command is not supported by the current mod.\";")

        return true
    elseif victim == nil or item == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive usage: "..commands.getadmin("give")["syntax"].."\";")

        return true
    end

    local cmdClient

    if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9no connected player by that name or slot #\";")

        return true
    end

    item = string.lower(item)

    if item == "health" or item == "hp" then
        et.gentity_set(cmdClient, "health", 140)

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dgive: ^7"..players.getName(cmdClient).." ^9has been given health.\";")

        return true
    end

    local weapon = tonumber(item) or weapons[item]

    if not weapon then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9unknown weapon or item '^7"..item.."^9'.\";")

        return true
    end

    local ammo = tonumber(amount) or 60

    local isGiven = pcall(et.AddWeaponToPlayer, cmdClient, weapon, ammo, ammo > 10 and 10 or ammo, 1)

    if not isGiven then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9failed to give weapon '^7"..item.."^9'.\";")

        return true
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dgive: ^7"..players.getName(cmdClient).." ^9has been given '^7"..item.."^9'.\";")

    return true
end
commands.addadmin("give", commandGive, auth.PERM_CHEATS, "gives a weapon or item to a player", "^9[^3name|slot#^9] [^3weapon|item^9] (^hamount^9)", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "nq"))
