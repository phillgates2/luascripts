
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

-- !aliases, as known from the silEnT mod. Alias for !listaliases,
-- which is registered in listaliases.lua.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local settings = wolfa_requireModule("util.settings")

function commandAliases(clientId, command, ...)
    return commandListAliases(clientId, "listaliases", ...)
end
commands.addadmin("aliases", commandAliases, auth.PERM_LISTALIASES, "display all known aliases for a player", "^9[^3name|slot#^9] ^9(^hoffset^9)", true, (settings.get("g_standalone") == 0))
