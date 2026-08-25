
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

-- !resetmyxp, as known from the etpub, NoQuarter and silEnT mods.
-- Clears all XP and skillpoints of the player running this command.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local settings = wolfa_requireModule("util.settings")

-- SK_NUM_SKILLS = 7
function commandResetMyXP(clientId, command)
    if clientId < 0 then
        return false
    end

    if et.G_ResetXP then
        pcall(et.G_ResetXP, clientId)
    elseif et.G_XP_Set then
        for skill = 0, 6 do
            pcall(et.G_XP_Set, clientId, 0, skill, 0)
        end
    else
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dresetmyxp: ^9this command is not supported by the current mod.\";")

        return true
    end

    pcall(et.gentity_set, clientId, "ps.persistant", 0, 0) -- PERS_SCORE = 0

    for skill = 0, 6 do
        pcall(et.gentity_set, clientId, "sess.skill", skill, 0)
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dresetmyxp: ^7"..et.gentity_get(clientId, "pers.netname").."^9's XP has been reset.\";")

    return true
end
commands.addadmin("resetmyxp", commandResetMyXP, auth.PERM_RESETXP_SELF, "clears all your XP and skillpoints", nil, nil, (settings.get("g_standalone") == 0))
