
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

-- !userinfo, as known from the etpub mod. Alias for !finger, which is
-- registered in finger.lua.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local settings = wolfa_requireModule("util.settings")

function commandUserInfo(clientId, command, ...)
    return commandFinger(clientId, "finger", ...)
end
commands.addadmin("userinfo", commandUserInfo, auth.PERM_FINGER, "gives specific information about a player", "^9[^3name|slot#^9]", true, (settings.get("g_standalone") == 0))
