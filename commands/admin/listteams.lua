
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

-- !listteams, as known from the etpub, NoQuarter and silEnT mods.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local teams = wolfa_requireModule("game.teams")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

function commandListTeams(clientId, command)
    local axisCount = teams.count(constants.TEAM_AXIS)
    local alliesCount = teams.count(constants.TEAM_ALLIES)
    local spectatorsCount = teams.count(constants.TEAM_SPECTATORS)

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

    local difference = teams.difference()

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dTeamstatus:^7\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^1Axis^7:        ^d"..axisCount.." players, ^d"..axisXp.." XP"..(teams.isLocked(constants.TEAM_AXIS) and " ^9(^7locked^9)" or "").."^7\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^4Allies^7:       ^d"..alliesCount.." players, ^d"..alliesXp.." XP"..(teams.isLocked(constants.TEAM_ALLIES) and " ^9(^7locked^9)" or "").."^7\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^2Spectators^7:  ^d"..spectatorsCount.." players"..(teams.isLocked(constants.TEAM_SPECTATORS) and " ^9(^7locked^9)" or "").."^7\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^7Difference:   ^d"..(difference > 0 and "+" or "")..difference.." player"..(math.abs(difference) ~= 1 and "s" or "").."^7\";")

    return true
end
commands.addadmin("listteams", commandListTeams, auth.PERM_LISTTEAMS, "displays statistical information about each team", nil, nil, (settings.get("g_standalone") == 0))
