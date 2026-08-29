
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

-- !flinga, !launcha and !throwa, as known from the etpub and silEnT
-- mods. These send all playing players flying.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

function commandThrowAll(clientId, command)
    local count = 0

    for i = 0, tonumber(et.trap_Cvar_Get("sv_maxclients")) - 1 do
        if players.isConnected(i) and not (auth.isPlayerAllowed(i, auth.PERM_IMMUNE) and auth.getPlayerLevel(i) > auth.getPlayerLevel(clientId)) then
            local team = et.gentity_get(i, "sess.sessionTeam")

            if (team == constants.TEAM_AXIS or team == constants.TEAM_ALLIES) and et.gentity_get(i, "health") > 0 then
                local velocityX, velocityY = 0, 0

                if command ~= "launcha" then
                    velocityX = (math.random() - 0.5) * 600
                    velocityY = (math.random() - 0.5) * 600
                end

                et.gentity_set(i, "ps.velocity", 0, velocityX)
                et.gentity_set(i, "ps.velocity", 1, velocityY)
                et.gentity_set(i, "ps.velocity", 2, command == "launcha" and 1200 or 900)

                count = count + 1
            end
        end
    end

    if count > 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^d"..command..": ^9"..count.." players were sent flying.\";")
    else
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^d"..command..": ^9no players eligible for this command.\";")
    end

    return true
end
commands.addadmin("flinga", commandThrowAll, auth.PERM_THROWALL, "sends all players flying in a random direction", nil, nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
commands.addadmin("launcha", commandThrowAll, auth.PERM_THROWALL, "sends all players flying straight up into the air", nil, nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
commands.addadmin("throwa", commandThrowAll, auth.PERM_THROWALL, "sends all players flying in a random direction", nil, nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
