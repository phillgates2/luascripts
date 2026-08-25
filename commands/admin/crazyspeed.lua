
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

-- !crazyspeed, as known from the silEnT mod. Enables random speed
-- changes with a thirty second interval. The crazy speed is
-- automatically disabled at map end.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local events = wolfa_requireModule("util.events")
local settings = wolfa_requireModule("util.settings")
local timers = wolfa_requireModule("util.timers")

local isEnabled = false
local defaultSpeed
local crazyTimer

local function crazySpeedTick()
    if isEnabled then
        et.trap_Cvar_Set("g_speed", tostring(math.random(200, 600)))
    end
end

function commandCrazySpeed(clientId, command, mode)
    local isEnabling = (mode == nil or string.lower(mode) == "on" or tonumber(mode) == 1)

    if isEnabling and not isEnabled then
        isEnabled = true

        defaultSpeed = et.trap_Cvar_Get("g_speed")

        crazyTimer = timers.add(crazySpeedTick, 30000, 0)

        crazySpeedTick()

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dcrazyspeed: ^9crazy speed has been ^7enabled^9!\";")
    elseif not isEnabling and isEnabled then
        isEnabled = false

        if crazyTimer then
            timers.remove(crazyTimer)

            crazyTimer = nil
        end

        if defaultSpeed then
            et.trap_Cvar_Set("g_speed", defaultSpeed)

            defaultSpeed = nil
        end

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dcrazyspeed: ^9crazy speed has been ^7disabled^9.\";")
    elseif isEnabling then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dcrazyspeed: ^9crazy speed is already enabled.\";")
    else
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dcrazyspeed: ^9crazy speed is not enabled.\";")
    end

    return true
end

function commandCrazySpeedOnGameShutdown(restartMap)
    if isEnabled then
        isEnabled = false

        if crazyTimer then
            timers.remove(crazyTimer)

            crazyTimer = nil
        end

        if defaultSpeed then
            et.trap_Cvar_Set("g_speed", defaultSpeed)

            defaultSpeed = nil
        end
    end
end
events.handle("onGameShutdown", commandCrazySpeedOnGameShutdown)

commands.addadmin("crazyspeed", commandCrazySpeed, auth.PERM_CRAZYSETTINGS, "enables random speed changes with a thirty second interval", "^9(^hon|off^9)", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "silent"))
