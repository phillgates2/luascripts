
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

-- !howfair, as known from the etpub and silEnT mods. The etpub and
-- silEnT versions base their output on (kill|player) rating, which is
-- not tracked by WolfAdmin, so team experience is used instead.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

function commandHowFair(clientId, command)
    local axisXp, alliesXp = 0, 0

    for i = 0, tonumber(et.trap_Cvar_Get("sv_maxclients")) - 1 do
        if players.isConnected(i) then
            local team = et.gentity_get(i, "sess.sessionTeam")

            if team == constants.TEAM_AXIS then
                axisXp = axisXp + et.gentity_get(i, "ps.persistant", 0)
            elseif team == constants.TEAM_ALLIES then
                alliesXp = alliesXp + et.gentity_get(i, "ps.persistant", 0)
            end
        end
    end

    local totalXp = axisXp + alliesXp

    local axisPercentage, alliesPercentage = 50, 50

    if totalXp > 0 then
        axisPercentage = math.floor((axisXp / totalXp) * 100 + 0.5)
        alliesPercentage = 100 - axisPercentage
    end

    local axisBar, alliesBar = "", ""

    for i = 1, 10 do
        axisBar = axisBar..(i <= math.floor(axisPercentage / 10) and "#" or "-")
        alliesBar = alliesBar..(i <= math.floor(alliesPercentage / 10) and "#" or "-")
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dhowfair: ^1Axis ^7["..axisBar.."] ^d"..axisPercentage.."^7 : ^d"..alliesPercentage.."^7 ["..alliesBar.."] ^4Allies^7\";")

    return true
end
commands.addadmin("howfair", commandHowFair, auth.PERM_LISTTEAMS, "prints a simple summary of the team fairness based on team experience", nil, nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
