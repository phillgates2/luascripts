
-- WolfAdmin module for Wolfenstein: Enemy Territory servers.
-- Copyright (C) 2015-2020 Timo 'Timothy' Smit

-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- at your option any later version.

-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.

-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.

local auth = wolfa_requireModule("auth.auth")
local commands = wolfa_requireModule("commands.commands")
local pagination = wolfa_requireModule("util.pagination")
local settings = wolfa_requireModule("util.settings")

-- the command list is split up in pages of 10 commands, 5 of them per line
local COMMANDS_PER_PAGE = 10
local COMMANDS_PER_LINE = 5
local MIN_COLUMN_WIDTH = 12
local MAX_LINE_LENGTH = 72

-- !help pg 2, !help page 2 and !help p 2 all do the same thing
local pageKeywords = { ["p"] = true, ["pg"] = true, ["page"] = true }

-- the hidden value of a command can either be a boolean or a function (see commands.addadmin())
local function isCommandHidden(data)
    if type(data["hidden"]) == "function" then
        return data["hidden"]()
    end

    return data["hidden"] and true or false
end

local function getPageCount(count)
    return math.floor((count + COMMANDS_PER_PAGE - 1) / COMMANDS_PER_PAGE)
end

-- pairs() has no fixed order, so the list has to be sorted or the same page
-- would show different commands on every call
local function getAvailableCommands(clientId)
    local cmds = commands.getadmin()
    local availableCommands = {}

    for command, data in pairs(cmds) do
        if data["function"] and data["flag"] and not isCommandHidden(data) and auth.isPlayerAllowed(clientId, data["flag"]) then
            table.insert(availableCommands, command)
        end
    end

    table.sort(availableCommands)

    return availableCommands
end

local function sendPage(clientId, availableCommands, page)
    local count = #availableCommands
    local limit, offset = pagination.calculate(count, COMMANDS_PER_PAGE, (page - 1) * COMMANDS_PER_PAGE)

    -- a fixed column width runs the commands into each other as soon as a
    -- command is longer than it, so size the columns to the longest command
    local columnWidth = MIN_COLUMN_WIDTH

    for _, command in ipairs(availableCommands) do
        columnWidth = math.max(columnWidth, string.len(command) + 2)
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat "..clientId.." \"^dhelp: ^9page ^7"..page.."^9/^7"..getPageCount(count).." ^9- ^7"..count.." "..((settings.get("g_standalone") ~= 0) and "available" or "additional").." commands:\";")

    -- never print more commands on a line than fit in the chat area
    local cmdsPerLine = math.max(1, math.min(COMMANDS_PER_LINE, math.floor(MAX_LINE_LENGTH / columnWidth)))
    local cmdsOnLine, cmdsBuffer = 0, ""

    for idx = offset + 1, offset + limit do
        cmdsBuffer = cmdsBuffer..string.format("%-"..columnWidth.."s", availableCommands[idx])
        cmdsOnLine = cmdsOnLine + 1

        if cmdsOnLine == cmdsPerLine then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat "..clientId.." \"^f"..cmdsBuffer.."\";")

            cmdsBuffer = ""
            cmdsOnLine = 0
        end
    end

    if cmdsBuffer ~= "" then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat "..clientId.." \"^f"..cmdsBuffer.."\";")
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat "..clientId.." \"^9Type ^2!help pg # ^9for another page or ^2!help ^d[command] ^9for a specific command.\";")

    return true
end

function commandHelp(clientId, command, cmd, cmd2)
    local cmds = commands.getadmin()

    if cmd then
        cmd = string.lower(cmd)
    end

    -- !help, !help pg #, !help #
    if not cmd or pageKeywords[cmd] or (not cmds[cmd] and tonumber(cmd) ~= nil) then
        local availableCommands = getAvailableCommands(clientId)

        if #availableCommands == 0 then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dhelp: ^9no commands are available to you.\";")

            return true
        end

        local page = 1

        if cmd then
            if pageKeywords[cmd] then
                page = tonumber(cmd2)
            else
                page = tonumber(cmd)
            end

            if not page or page < 1 or math.floor(page) ~= page then
                et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dhelp: ^9invalid page number, syntax: ^2!help pg #^9.\";")

                return true
            end

            page = math.floor(page)

            if page > getPageCount(#availableCommands) then
                et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dhelp: ^9there is no page ^7"..page.."^9, the last page is ^7"..getPageCount(#availableCommands).."^9.\";")

                return true
            end
        end

        return sendPage(clientId, availableCommands, page)
    end

    -- !help [command]
    if cmds[cmd] ~= nil and not isCommandHidden(cmds[cmd]) then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dhelp: ^9help for '^2".. cmd .."^9':\";")
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dfunction: ^9"..cmds[cmd]["help"].."\";")
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dsyntax: ^9"..cmds[cmd]["syntax"].."\";")
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dflag: ^9'^2"..cmds[cmd]["flag"].."^9'\";")

        return true
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dhelp: ^9no help available for '^7"..cmd.."^9', type ^2!help ^9for the available commands.\";")

    return true
end
commands.addadmin("help", commandHelp, auth.PERM_HELP, "display commands available to you or help on a specific command", "^9(^hcommand^9) ^9|^7 ^9(^hpg #^9)", (settings.get("g_standalone") == 0))
