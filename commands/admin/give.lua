
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

-- !give, as known from the NoQuarter mod. Gives a weapon, ammo, health
-- or xp to a player. Weapon and skill names are translated to the
-- (ET: Legacy) numbers, since the lua api does not know the names.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

-- weapon numbers (bg_public.h), the lua api does not know weapon names
local weapons = {
    ["knife"] = 1, ["kabar"] = 48,
    ["luger"] = 2, ["silencedluger"] = 14, ["akimboluger"] = 36, ["akimbosilencedluger"] = 46,
    ["colt"] = 7, ["silencedcolt"] = 39, ["akimbocolt"] = 35, ["akimbosilencedcolt"] = 45,
    ["mp40"] = 3, ["thompson"] = 8, ["sten"] = 10,
    ["grenade"] = 9, ["pineapple"] = 9, ["axisgrenade"] = 4,
    ["panzerfaust"] = 5, ["panzer"] = 5,
    ["flamethrower"] = 6, ["flamer"] = 6,
    ["mg42"] = 30, ["mobilemg42"] = 30,
    ["mortar"] = 34,
    ["kar98"] = 23, ["carbine"] = 24, ["garand"] = 25, ["k43"] = 31,
    ["gpg40"] = 37, ["m7"] = 38,
    ["garandscope"] = 40, ["k43scope"] = 41, ["sniper"] = 40,
    ["fg42"] = 32, ["fg42scope"] = 42,
    ["dynamite"] = 15, ["landmine"] = 26, ["satchel"] = 27,
    ["smokebomb"] = 29, ["smokemarker"] = 22,
    ["syringe"] = 11, ["adrenaline"] = 44, ["medkit"] = 19,
    ["ammopack"] = 12, ["binoculars"] = 20, ["pliers"] = 21,
    ["arty"] = 13
}

-- skill numbers, the lua api does not know skill names
local skills = {
    ["battlesense"] = constants.SKILL_BATTLESENSE, ["bs"] = constants.SKILL_BATTLESENSE,
    ["engineer"] = constants.SKILL_ENGINEER, ["eng"] = constants.SKILL_ENGINEER,
    ["medic"] = constants.SKILL_MEDIC,
    ["fieldops"] = constants.SKILL_FIELDOPS, ["fops"] = constants.SKILL_FIELDOPS,
    ["lightweapons"] = constants.SKILL_LIGHTWEAPONS, ["lw"] = constants.SKILL_LIGHTWEAPONS,
    ["soldier"] = constants.SKILL_SOLDIER,
    ["covertops"] = constants.SKILL_COVERTOPS, ["cvops"] = constants.SKILL_COVERTOPS
}

local function getSkillName(skill)
    for name, id in pairs(skills) do
        if id == skill and string.len(name) > 3 then
            return name
        end
    end

    return "unknown"
end

local function giveXP(cmdClient, amount, skill)
    amount = math.floor(tonumber(amount) or 0)

    if amount >= 0 then
        if et.G_XP_Set then
            -- the fourth argument makes the xp being added instead of set
            return pcall(et.G_XP_Set, cmdClient, amount, skill, 1)
        elseif et.G_AddSkillPoints then
            return pcall(et.G_AddSkillPoints, cmdClient, skill, amount)
        end
    elseif et.G_LoseSkillPoints then
        return pcall(et.G_LoseSkillPoints, cmdClient, skill, -amount)
    end

    return false
end

function commandGive(clientId, command, victim, item, amount, skill)
    if victim == nil or item == nil then
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

    if not auth.canTarget(clientId, cmdClient) then
        if auth.isTargetProtected(cmdClient) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")
        else
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9sorry, but your intended victim has a higher admin level than you do.\";")
        end

        return true
    end

    item = string.lower(item)

    -- !give [name|slot#] health (amount)
    if item == "health" or item == "hp" then
        local health = tonumber(amount) or 140

        if health < 1 then
            health = 1
        elseif health > 999 then
            health = 999
        end

        et.gentity_set(cmdClient, "health", health)

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dgive: ^7"..players.getName(cmdClient).." ^9has been given ^7"..health.." ^9health.\";")

        return true
    end

    -- !give [name|slot#] ammo (amount)
    if item == "ammo" then
        if not et.GetCurrentWeapon or not et.AddWeaponToPlayer then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9giving ammo is not supported by the current mod.\";")

            return true
        end

        local weapon, currentAmmo, currentClip = et.GetCurrentWeapon(cmdClient)

        local ammo = tonumber(amount) or 90

        if ammo < 0 then
            ammo = 0
        end

        et.AddWeaponToPlayer(cmdClient, weapon, currentAmmo + ammo, currentClip, 0)

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dgive: ^7"..players.getName(cmdClient).." ^9has been given ^7"..ammo.." ^9rounds of ammo.\";")

        return true
    end

    -- !give [name|slot#] xp <amount> (skill)
    if item == "xp" then
        if tonumber(amount) == nil then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive usage: "..commands.getadmin("give")["syntax"].."\";")

            return true
        end

        local skillId = constants.SKILL_BATTLESENSE

        if skill ~= nil then
            skillId = skills[string.lower(skill)]

            if skillId == nil then
                et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9unknown skill '^7"..skill.."^9'.\";")

                return true
            end
        end

        local amountNumber = tonumber(amount)

        if not giveXP(cmdClient, amountNumber, skillId) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9giving xp is not supported by the current mod.\";")

            return true
        end

        local skillName = getSkillName(skillId)

        if amountNumber >= 0 then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dgive: ^7"..players.getName(cmdClient).." ^9has been given ^7"..amountNumber.." ^9xp in ^7"..skillName.."^9.\";")
        else
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dgive: ^9^7"..amountNumber.." ^9xp has been taken from ^7"..players.getName(cmdClient).." ^9(^7"..skillName.."^9).\";")
        end

        return true
    end

    -- !give [name|slot#] <weapon|weapon#> (ammo)
    if not et.AddWeaponToPlayer then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9giving weapons is not supported by the current mod.\";")

        return true
    end

    local weapon = tonumber(item) or weapons[item]

    if not weapon then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9unknown weapon or item '^7"..item.."^9'.\";")

        return true
    end

    local ammo = tonumber(amount) or 60

    if ammo < 0 then
        ammo = 0
    end

    local isGiven = pcall(et.AddWeaponToPlayer, cmdClient, weapon, ammo, ammo > 10 and 10 or ammo, 1)

    if not isGiven then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgive: ^9failed to give weapon '^7"..item.."^9'.\";")

        return true
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dgive: ^7"..players.getName(cmdClient).." ^9has been given '^7"..item.."^9'.\";")

    return true
end
commands.addadmin("give", commandGive, auth.PERM_CHEATS, "gives a weapon, ammo, health or xp to a player", "^9[^3name|slot#^9] [^3weapon|ammo|health|xp^9] (^hamount^9) (^hskill^9)", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "nq"))
