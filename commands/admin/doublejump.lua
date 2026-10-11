
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

-- !doublejump, the toggle for game/doublejump.lua: turns the double jump on and
-- off while the map runs, changes how players trigger it, and reports what the
-- server is doing now. Everything it writes is one of the cvars the module
-- reads, so a server.cfg can set the same values at start-up and rcon can set
-- them without WolfAdmin.
--
-- The mode it reports by default is auto, the one that asks nothing of the
-- player: a jump press in mid air never reaches a Lua module, so a bind of the
-- player's own is the only route to jaymod's tap-jump-twice, and command mode
-- works only for the players who made one. game/doublejump.lua's header carries
-- the engine detail; the job here is to say out loud which of the three the
-- server is running and what each one costs.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local doublejump = wolfa_requireModule("game.doublejump")

local players = wolfa_requireModule("players.players")

local settings = wolfa_requireModule("util.settings")

local function usage(clientId)
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddoublejump usage: "..commands.getadmin("doublejump")["syntax"].."\";")
end

local function status(clientId)
    local state = doublejump.getStatus()

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddoublejump: ^9"..(state.enabled and "on" or "off")..", ^7mode ^3"..state.mode..", ^7window ^3"..state.window.."ms^7, ^7boost ^3x"..state.boost.." ^7of "..state.jumpVelocity.."^9.\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddoublejump: ^9"..state.maxAirJumps.." extra jump per time in the air - ^7"..state.trigger.."^9.\";")
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddoublejump: "..(state.needsBind and "^9players must bind ^3djump^9 once, which nothing on the server can do for them" or "^9nothing for players to bind")..(state.announce and ", and they are told how it works on spawn" or "")..".\";")
end

function commandDoubleJump(clientId, command, action, ...)
    action = string.lower(tostring(action or "status"))

    if action == "on" or action == "1" or action == "enable" then
        doublejump.setEnabled(true)

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^ddoublejump: ^7"..players.getName(clientId).." ^9turned the double jump on, ^7"..doublejump.getMode().." ^9mode.\";")

        return true
    elseif action == "off" or action == "0" or action == "disable" then
        doublejump.setEnabled(false)

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^ddoublejump: ^7"..players.getName(clientId).." ^9turned the double jump off.\";")

        return true
    elseif action == "status" or action == "info" then
        status(clientId)

        return true
    elseif action == "mode" then
        local args = {...}
        local mode = doublejump.setMode(args[1])

        if not mode then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddoublejump: ^9no such mode, choose ^3auto^9 (the default), ^3command^9 or ^3crouch^9.\";")

            return true
        end

        -- what the mode change asks of the players is worth saying in the same
        -- breath: command mode is the only one that answers a second press of
        -- the jump key, and it is the only one that needs a bind to do it
        local note = ""

        if mode == "command" then
            note = " ^9Players must bind ^3djump^9 - ^3bind MOUSE3 djump^9, or one quoted ^3+moveup;djump^9 on the jump key."
        elseif mode == "auto" then
            note = " ^9Every take-off is boosted, so players need no bind and no second press."
        end

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^ddoublejump: ^9trigger mode is now ^7"..mode.."^9."..note.."\";")

        return true
    elseif action == "window" or action == "boost" then
        local args = {...}
        local value = tonumber(args[1])
        local cvar = (action == "window") and "g_doublejump_window" or "g_doublejump_boost"

        if not value or value <= 0 then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddoublejump: ^9"..action.." needs a number above zero.\";")

            return true
        end

        if action == "window" and value > 10000 then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^ddoublejump: ^9a window above ten seconds is not a double jump any more.\";")

            return true
        end

        et.trap_Cvar_Set(cvar, tostring(value))

        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^ddoublejump: ^9"..action.." is now ^7"..value.."^9.\";")

        return true
    end

    usage(clientId)

    return true
end
commands.addadmin("doublejump", commandDoubleJump, auth.PERM_CHEATS, "toggles the double jump and how players trigger it", "^9(^3on|off|status|mode <auto|command|crouch>|window <ms>|boost <x>^9)", nil, (settings.get("g_standalone") == 0))
