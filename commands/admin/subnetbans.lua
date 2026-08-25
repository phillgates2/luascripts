
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

-- !subnetban, !subnets and !rmsubnetban, as known from the silEnT
-- mod. The subnet bans themselves are stored and enforced by the
-- admin.subnetbans module.

local auth = wolfa_requireModule("auth.auth")

local commands = wolfa_requireModule("commands.commands")

local subnetbans = wolfa_requireModule("admin.subnetbans")

local settings = wolfa_requireModule("util.settings")

function commandSubnetBan(clientId, command, subnet, ...)
    if subnet == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dsubnetban usage: "..commands.getadmin("subnetban")["syntax"].."\";")

        return true
    end

    local args = {...}
    local reason = #args > 0 and table.concat(args, " ") or "banned by admin"

    local isAdded, result = subnetbans.add(subnet, clientId, 0, reason)

    if not isAdded then
        if result == "self" then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dsubnetban: ^9you cannot ban a subnet that matches your own ip address.\";")
        else
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dsubnetban: ^9'^7"..subnet.."^9' is not a valid subnet.\";")
        end

        return true
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^dsubnetban: ^9subnet '^7"..subnet.."^9' has been banned, Reason: ^7"..reason.."^9.\";")

    return true
end

function commandSubnets(clientId, command, startAt)
    if subnetbans.getCount() == 0 then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dsubnets: ^9no subnet bans have been issued.\";")

        return true
    end

    local start = tonumber(startAt) or 0

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^dsubnets: ^9"..subnetbans.getCount().." subnet bans issued:\";")

    local shown = 0

    for _, subnet in pairs(subnetbans.getList()) do
        if subnet["id"] > start then
            et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^f"..string.format("%3s", subnet["id"]).." ^7"..string.format("%-18s", subnet["subnet"]).." ^f"..subnet["reason"].."\";")

            shown = shown + 1

            if shown == 30 then
                et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^9Type ^2!subnets ^d"..(start + 30).." ^9to view the next bans.\";")

                break
            end
        end
    end

    return true
end

function commandRmSubnetBan(clientId, command, subnetId)
    if subnetId == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^drmsubnetban usage: "..commands.getadmin("rmsubnetban")["syntax"].."\";")

        return true
    end

    local subnet = subnetbans.remove(subnetId)

    if subnet == nil then
        et.trap_SendConsoleCommand(et.EXEC_APPEND, "csay "..clientId.." \"^drmsubnetban: ^9no subnet ban with number '^7"..subnetId.."^9'.\";")

        return true
    end

    et.trap_SendConsoleCommand(et.EXEC_APPEND, "cchat -1 \"^drmsubnetban: ^9subnet ban '^7"..subnet.."^9' has been removed.\";")

    return true
end
commands.addadmin("subnetban", commandSubnetBan, auth.PERM_SUBNETBAN, "bans an ip subnet (e.g. 123.45.67.*) with an optional reason", "^9[^3subnet^9] (^3reason^9)", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "silent"))
commands.addadmin("subnets", commandSubnets, auth.PERM_LISTBANS, "displays all issued subnet bans", "^9(^hstart at^9)", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "silent"))
commands.addadmin("rmsubnetban", commandRmSubnetBan, auth.PERM_SUBNETBAN, "removes a subnet ban", "^9[^3ban#^9]", nil, (settings.get("g_standalone") == 0 and settings.get("fs_game") == "silent"))
