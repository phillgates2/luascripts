
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

-- !burn, as known from the etpub, NoQuarter and silEnT mods. The victim
-- is set on fire (visual, where supported by the mod) and receives fire
-- damage in five intervals of one second.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")
local timers = wolfa_requireModule("util.timers")

local function burnTick(cmdClient, iteration)
    if players.isConnected(cmdClient) and et.gentity_get(cmdClient, "health") > 0 then
        et.G_Damage(cmdClient, 0, 1024, 25, 0, 0) -- MOD_UNKNOWN = 0
    end
end

function commandBurn(clientId, command, victim, ...)
    local cmdClient

    if victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dburn usage: "..commands.getadmin("burn")["syntax"].."\";")

        return true
    elseif tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dburn: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dburn: ^9no connected player by that name or slot #\";")

        return true
    end

    if auth.isPlayerAllowed(cmdClient, auth.PERM_IMMUNE) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dburn: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")

        return true
    elseif auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dburn: ^9sorry, but your intended victim has a higher admin level than you do.\";")

        return true
    elseif et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_AXIS and et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_ALLIES then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dburn: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not playing.\";")

        return true
    elseif et.gentity_get(cmdClient, "health") <= 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dburn: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not alive.\";")

        return true
    end

    local args = {...}
    local reason = #args > 0 and table.concat(args, " ") or nil

    -- the visual burning, supported by etpub based mods and ET: Legacy
    pcall(et.gentity_set, cmdClient, "s.onFireStart", et.trap_Milliseconds())
    pcall(et.gentity_set, cmdClient, "s.onFireEnd", et.trap_Milliseconds() + 6000)

    for i = 0, 4 do
        timers.add(burnTick, i * 1000 + 500, 1, cmdClient)
    end

    if reason then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7You have been set on fire by ^7"..players.getName(clientId).."^7: "..reason..".\";")
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "playsound "..cmdClient.." \"sound/player/fry.wav\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dburn: ^7"..players.getName(cmdClient).." ^9was set on fire.\";")

    return true
end
commands.addadmin("burn", commandBurn, auth.PERM_BURN, "sets a player on fire with an optional reason", "^9[^3name|slot#^9] (^hreason^9)", nil, (settings.get("g_standalone") == 0))
