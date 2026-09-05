
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

-- !lol, as known from the etpub and silEnT mods. Makes players drop
-- grenades; if no victim is specified, all playing players drop them.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local players = wolfa_requireModule("players.players")

local constants = wolfa_requireModule("util.constants")
local settings = wolfa_requireModule("util.settings")
local timers = wolfa_requireModule("util.timers")

local function grenadeExplode(cmdClient)
    if players.isConnected(cmdClient) then
        -- MOD_GRENADE = 4
        et.G_Damage(cmdClient, 0, 1024, 200, 0, 4)

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "playsound "..cmdClient.." \"sound/weapons/grenade/grenExpl.wav\";")
    end
end

local function isValidVictim(clientId, cmdClient)
    if not auth.canTarget(clientId, cmdClient) then
        if auth.isTargetProtected(cmdClient) then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlol: ^7"..et.gentity_get(cmdClient, "pers.netname").." ^9is immune to this command.\";")
        else
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlol: ^9sorry, but your intended victim has a higher admin level than you do.\";")
        end

        return false
    end

    return true
end

function commandLol(clientId, command, victim, amount)
    local grenades = tonumber(amount) or 1

    if grenades < 1 then
        grenades = 1
    elseif grenades > 16 then
        grenades = 16
    end

    local victims = {}

    if victim == nil or victim == "all" or victim == "-1" then
        for i = 0, tonumber(et.trap_Cvar_Get("sv_maxclients")) - 1 do
            if players.isConnected(i) and auth.canTarget(clientId, i) then
                local team = et.gentity_get(i, "sess.sessionTeam")

                if team == constants.TEAM_AXIS or team == constants.TEAM_ALLIES then
                    table.insert(victims, i)
                end
            end
        end
    else
        local cmdClient

        if tonumber(victim) == nil or tonumber(victim) < 0 or tonumber(victim) > tonumber(et.trap_Cvar_Get("sv_maxclients")) then
            cmdClient = et.ClientNumberFromString(victim)
        else
            cmdClient = tonumber(victim)
        end

        if cmdClient == -1 or cmdClient == nil then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlol: ^9no or multiple matches for '^7"..victim.."^9'.\";")

            return true
        elseif not et.gentity_get(cmdClient, "pers.netname") then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlol: ^9no connected player by that name or slot #\";")

            return true
        elseif not isValidVictim(clientId, cmdClient) then
            return true
        end

        table.insert(victims, cmdClient)
    end

    if #victims == 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dlol: ^9no players eligible for this command.\";")

        return true
    end

    for _, cmdClient in pairs(victims) do
        for i = 0, grenades - 1 do
            timers.add(grenadeExplode, i * 400 + 600, 1, cmdClient)
        end
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dlol: ^9"..#victims.." player"..(#victims ~= 1 and "s" or "").." dropped "..grenades.." grenade"..(grenades ~= 1 and "s" or "")..".\";")

    return true
end
commands.addadmin("lol", commandLol, auth.PERM_LOL, "makes players drop grenades (max. 16)", "^9([^3name|slot#^9]) (^hgrenades^9)", nil, (settings.get("g_standalone") == 0 and (settings.get("fs_game") == "etpub" or settings.get("fs_game") == "silent")))
