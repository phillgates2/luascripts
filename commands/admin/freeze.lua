
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

-- !freeze and !unfreeze, as known from the etpub, NoQuarter and silEnT
-- mods. Frozen players cannot move until they are unfrozen. The mods
-- freeze players in the game code, WolfAdmin does this by resetting the
-- velocity of frozen players at a small interval.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local events = wolfa_requireModule("util.events")
local settings = wolfa_requireModule("util.settings")
local timers = wolfa_requireModule("util.timers")

local frozenClients = {}
local freezeTimer

local function freezeTick()
    local count = 0

    for clientId, _ in pairs(frozenClients) do
        if players.isConnected(clientId) then
            et.gentity_set(clientId, "ps.velocity", 0, 0)
            et.gentity_set(clientId, "ps.velocity", 1, 0)
            et.gentity_set(clientId, "ps.velocity", 2, 0)

            count = count + 1
        else
            frozenClients[clientId] = nil
        end
    end

    -- no frozen players left, the timer is no longer needed
    if count == 0 and freezeTimer then
        timers.remove(freezeTimer)

        freezeTimer = nil
    end
end

local function freezeCheckTarget(clientId, command, cmdClient)
    if not auth.canTarget(clientId, cmdClient) then
        if auth.isTargetProtected(cmdClient) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^d"..command..": ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")
        else
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^d"..command..": ^9sorry, but your intended victim has a higher admin level than you do.\";")
        end

        return false
    elseif et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_AXIS and et.gentity_get(cmdClient, "sess.sessionTeam") ~= constants.TEAM_ALLIES then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^d"..command..": ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not playing.\";")

        return false
    end

    return true
end

local function freezeApply(clientId, command, cmdClient, reason, isSilent)
    if command == "freeze" then
        frozenClients[cmdClient] = true

        if not freezeTimer then
            freezeTimer = timers.add(freezeTick, 100, 0)
        end

        if reason then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "ccp "..cmdClient.." \"^7You have been frozen by ^7"..players.getName(clientId).."^7: "..reason..".\";")
        end

        if not isSilent then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dfreeze: ^7"..players.getName(cmdClient).." ^9has been frozen.\";")
        end
    else
        if frozenClients[cmdClient] then
            frozenClients[cmdClient] = nil

            if not isSilent then
                et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dunfreeze: ^7"..players.getName(cmdClient).." ^9has been unfrozen.\";")
            end

            return true
        end

        if not isSilent then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dunfreeze: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is not frozen.\";")
        end

        return true
    end

    return true
end

function commandFreeze(clientId, command, victim, ...)
    local targets = {}

    if victim == nil or victim == "all" or victim == "-1" then
        for i = 0, tonumber(et.trap_Cvar_Get("sv_maxclients")) - 1 do
            if players.isConnected(i) and auth.canTarget(clientId, i) then
                local team = et.gentity_get(i, "sess.sessionTeam")

                if team == constants.TEAM_AXIS or team == constants.TEAM_ALLIES then
                    if command == "freeze" or frozenClients[i] then
                        table.insert(targets, i)
                    end
                end
            end
        end

        if #targets == 0 then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^d"..command..": ^9no players eligible for this command.\";")

            return true
        end

        for i = 1, #targets do
            freezeApply(clientId, command, targets[i], nil, true)
        end

        if command == "freeze" then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dfreeze: ^9"..#targets.." players have been frozen.\";")
        else
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dunfreeze: ^9"..#targets.." players have been unfrozen.\";")
        end

        return true
    end

    local cmdClient

    if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
        cmdClient = et.ClientNumberFromString(victim)
    else
        cmdClient = tonumber(victim)
    end

    if cmdClient == -1 or cmdClient == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^d"..command..": ^9no or multiple matches for '^7"..victim.."^9'.\";")

        return true
    elseif not et.gentity_get(cmdClient, "pers.netname") then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^d"..command..": ^9no connected player by that name or slot #\";")

        return true
    elseif not freezeCheckTarget(clientId, command, cmdClient) then
        return true
    end

    local args = {...}

    freezeApply(clientId, command, cmdClient, command == "freeze" and #args > 0 and table.concat(args, " ") or nil)

    return true
end

function commandFreezeOnClientDisconnect(clientId)
    frozenClients[clientId] = nil
end
events.handle("onClientDisconnect", commandFreezeOnClientDisconnect)

commands.addadmin("freeze", commandFreeze, auth.PERM_FREEZE, "freezes a or all players, frozen players cannot move", "^9([^3name|slot#^9]) (^hreason^9)", nil, (settings.get("g_standalone") == 0))
commands.addadmin("unfreeze", commandFreeze, auth.PERM_FREEZE, "unfreezes a or all players", "^9([^3name|slot#^9])", nil, (settings.get("g_standalone") == 0))
