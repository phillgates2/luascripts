
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

-- !giba, as known from the etpub and silEnT mods. Kills and gibs all
-- playing players.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

function commandGibAll(clientId, command)
    local count = 0

    for i = 0, tonumber(et.trap_Cvar_Get("sv_maxclients")) - 1 do
        if players.isConnected(i) and not auth.isPlayerAllowed(i, auth.PERM_IMMUNE) then
            local team = et.gentity_get(i, "sess.sessionTeam")

            if (team == constants.TEAM_AXIS or team == constants.TEAM_ALLIES) and et.gentity_get(i, "health") > 0 then
                -- GENTITYNUM_BITS    10                      10
                -- MAX_GENTITIES      1 << GENTITYNUM_BITS    1024
                -- ENTITYNUM_WORLD    MAX_GENTITIES - 2       18
                et.G_Damage(i, 0, 1024, 500, 0, 0) -- MOD_UNKNOWN = 0

                count = count + 1
            end
        end
    end

    if count > 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dgiba: ^9"..count.." players have been gibbed.\";")
    else
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dgiba: ^9no players eligible for this command.\";")
    end

    return true
end
commands.addadmin("giba", commandGibAll, auth.PERM_GIBALL, "kills and gibs all players", nil, nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
