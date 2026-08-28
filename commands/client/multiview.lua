
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

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

-- In standalone mode, grant access to a level with:
--   acl addpermission <level> multiview
local multiviewCommands = {
    "mvadd",
    "mvallies",
    "mvaxis",
    "mvall",
    "mvnone",
    "mvdel"
}

function commandMultiview(clientId)
    -- ET: Legacy handles this check itself when g_multiview is disabled. Do
    -- not interfere with that behaviour unless the server has enabled it.
    local multiviewEnabled = tonumber(et.trap_Cvar_Get("g_multiview")) or 0
    if multiviewEnabled == 0 then
        return
    end

    if auth.isPlayerAllowed(clientId, auth.PERM_MULTIVIEW) then
        return
    end

    et.trap_SendServerCommand(clientId, "print \"^1Multiview is restricted to authorized admin levels ^7(^1"..auth.PERM_MULTIVIEW.."^7)\\n\"")

    return true
end

-- These are the server-side commands used by ET: Legacy's multiview client
-- commands. An empty flag lets the handler inspect the permission and return
-- 1 to stop unauthorized commands from reaching the game code.
for _, command in ipairs(multiviewCommands) do
    commands.addclient(command, commandMultiview, "", nil, false)
end
