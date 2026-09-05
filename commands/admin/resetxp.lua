
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

-- !resetxp, as known from the etpub, NoQuarter and silEnT mods. Clears
-- all XP and skillpoints of a player.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

-- SK_NUM_SKILLS = 7
local function resetPlayerXP(cmdClient)
    if et.G_ResetXP then
        pcall(et.G_ResetXP, cmdClient)
    elseif et.G_XP_Set then
        for skill = 0, 6 do
            pcall(et.G_XP_Set, cmdClient, 0, skill, 0)
        end
    else
        return false
    end

    pcall(et.gentity_set, cmdClient, "ps.persistant", 0, 0) -- PERS_SCORE = 0

    for skill = 0, 6 do
        pcall(et.gentity_set, cmdClient, "sess.skill", skill, 0)
    end

    return true
end

function commandResetXP(clientId, command, victim, ...)
    local cmdClient

    if victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dresetxp usage: "..commands.getadmin("resetxp")["syntax"].."\";")

        return true
    elseif tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dresetxp: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dresetxp: ^9no connected player by that name or slot #\";")

        return true
    end

    if not auth.canTarget(clientId, cmdClient) then
        if auth.isTargetProtected(cmdClient) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dresetxp: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")
        else
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dresetxp: ^9sorry, but your intended victim has a higher admin level than you do.\";")
        end

        return true
    end

    if not resetPlayerXP(cmdClient) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dresetxp: ^9this command is not supported by the current mod.\";")

        return true
    end

    local args = {...}
    local reason = #args > 0 and table.concat(args, " ") or nil

    if reason then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7Your XP has been reset by ^7"..players.getName(clientId).."^7: "..reason..".\";")
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dresetxp: ^7"..players.getName(cmdClient).."^9's XP has been reset.\";")

    return true
end
commands.addadmin("resetxp", commandResetXP, auth.PERM_RESETXP, "clears all XP and skillpoints of a player with an optional reason", "^9[^3name|slot#^9] (^hreason^9)", nil, (settings.get("g_standalone") == 0))
