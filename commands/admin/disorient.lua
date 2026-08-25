
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

-- !disorient, as known from the etpub, NoQuarter and silEnT mods. Turns
-- the view of the victim upside down by flipping the pitch delta angle
-- by 180 degrees.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")

-- flips (or restores) the pitch delta angle of a client, returns
-- whether the mod's lua api supports delta_angles
function disorientFlip(cmdClient, flip)
    local isReadable, pitch = pcall(et.gentity_get, cmdClient, "ps.delta_angles", 0)

    if not isReadable then
        return false
    end

    pitch = tonumber(pitch) or 0

    if flip then
        pitch = pitch + 32768 -- 180 degrees in short angle units
    else
        pitch = pitch - 32768
    end

    pitch = pitch % 65536

    if pitch > 32767 then
        pitch = pitch - 65536
    end

    local isWritable = pcall(et.gentity_set, cmdClient, "ps.delta_angles", 0, pitch)

    return isWritable
end

function commandDisorient(clientId, command, victim, ...)
    local cmdClient

    if victim == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisorient usage: "..commands.getadmin("disorient")["syntax"].."\";")

        return true
    elseif tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisorient: ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisorient: ^9no connected player by that name or slot #\";")

        return true
    end

    if auth.isPlayerAllowed(cmdClient, auth.PERM_IMMUNE) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisorient: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")

        return true
    elseif auth.getPlayerLevel(cmdClient) > auth.getPlayerLevel(clientId) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisorient: ^9sorry, but your intended victim has a higher admin level than you do.\";")

        return true
    elseif et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_AXIS and et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_ALLIES then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisorient: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not playing.\";")

        return true
    elseif et.gentity_get(cmdClient, "health") <= 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisorient: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not alive.\";")

        return true
    end

    if not disorientFlip(cmdClient, true) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddisorient: ^9this command is not supported by the current mod.\";")

        return true
    end

    local args = {...}
    local reason = #args > 0 and table.concat(args, " ") or nil

    if reason then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7You have been disoriented by ^7"..players.getName(clientId).."^7: "..reason..".\";")
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^ddisorient: ^7"..players.getName(cmdClient).." ^9has been disoriented.\";")

    return true
end
commands.addadmin("disorient", commandDisorient, auth.PERM_DISORIENT, "turns the view of a player upside down with an optional reason", "^9[^3name|slot#^9] (^hreason^9)", nil, (settings.get("g_standalone") == 0))
