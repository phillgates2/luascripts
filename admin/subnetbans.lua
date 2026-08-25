
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

-- Subnet bans, as known from the silEnT mod (!subnetban, !subnets and
-- !rmsubnetban). Subnets are stored in "subnetbans.cfg" inside the
-- mod homepath and are checked on every (first time) client connect.

local events = wolfa_requireModule("util.events")

local subnetbans = {}

local subnets = {}

local function load()
    local fileName = wolfa_getHomePath().."subnetbans.cfg"
    local fileDescriptor, fileLength = et.trap_FS_FOpenFile(fileName, et.FS_READ)

    if fileLength == -1 then
        return
    end

    local fileString = et.trap_FS_Read(fileDescriptor, fileLength)

    et.trap_FS_FCloseFile(fileDescriptor)

    local nextId = 1

    for line in string.gmatch(fileString, "([^\n]+)\n?") do
        local id, subnet, reason = string.match(line, "^(%d+);([^;]+);(.*)$")

        if id and subnet then
            id = tonumber(id)

            subnets[id] = {
                ["id"] = id,
                ["subnet"] = subnet,
                ["reason"] = reason or "banned by admin"
            }

            if id >= nextId then
                nextId = id + 1
            end
        end
    end

    subnetbans.nextId = nextId
end

local function save()
    local fileName = wolfa_getHomePath().."subnetbans.cfg"
    local fileDescriptor, _ = et.trap_FS_FOpenFile(fileName, et.FS_WRITE)

    local fileString = ""

    for _, subnet in pairs(subnets) do
        fileString = fileString..subnet["id"]..";"..subnet["subnet"]..";"..subnet["reason"].."\n"
    end

    et.trap_FS_Write(fileString, string.len(fileString), fileDescriptor)

    et.trap_FS_FCloseFile(fileDescriptor)
end

-- converts an ip address (e.g. "192.168.1.20") or subnet (e.g. "192.168.1.*"
-- or "192.168.*") to a comparable table of octets, wildcards are nil
local function parseIp(ip)
    local octets = {}

    for octet in string.gmatch(ip, "(%d+)%.?") do
        table.insert(octets, tonumber(octet))
    end

    return #octets > 0 and octets or nil
end

function subnetbans.matches(clientIp, subnet)
    local subnetOctets = parseIp(subnet)

    if not subnetOctets then
        return false
    end

    local ipOctets = parseIp(clientIp)

    if not ipOctets then
        return false
    end

    -- the subnet matches when all specified (non-wildcard) octets are equal
    for i = 1, #subnetOctets do
        if ipOctets[i] ~= subnetOctets[i] then
            return false
        end
    end

    return true
end

function subnetbans.add(subnet, invokerId, duration, reason)
    -- normalize the subnet, only digits, dots and wildcards are kept and
    -- a trailing wildcard is added to "short" ips (e.g. "10.0.0" -> "10.0.0.*")
    subnet = string.gsub(string.lower(subnet), "[^%d%.%*]", "")

    local octets = parseIp(subnet)

    if octets == nil then
        return false
    end

    if string.find(subnet, "*", 1, true) == nil and #octets < 4 then
        subnet = subnet..".*"
    end

    -- do not allow admins to ban themselves (like silEnT does)
    if invokerId >= 0 then
        local ip = et.Info_ValueForKey(et.trap_GetUserinfo(invokerId), "ip")

        ip = string.match(ip or "", "^(%d+%.%d+%.%d+%.%d+)")

        if ip and subnetbans.matches(ip, subnet) then
            return false, "self"
        end
    end

    local id = subnetbans.nextId or 1

    subnets[id] = {
        ["id"] = id,
        ["subnet"] = subnet,
        ["reason"] = reason and reason ~= "" and reason or "banned by admin"
    }

    subnetbans.nextId = id + 1

    save()

    return true, id
end

function subnetbans.remove(subnetId)
    if subnets[tonumber(subnetId)] then
        local subnet = subnets[tonumber(subnetId)]["subnet"]

        subnets[tonumber(subnetId)] = nil

        save()

        return subnet
    end

    return nil
end

function subnetbans.getList()
    return subnets
end

function subnetbans.getCount()
    local count = 0

    for _ in pairs(subnets) do
        count = count + 1
    end

    return count
end

function subnetbans.onClientConnectAttempt(clientId, firstTime, isBot)
    if not firstTime or isBot then
        return
    end

    if subnetbans.getCount() == 0 then
        return
    end

    local ip = et.Info_ValueForKey(et.trap_GetUserinfo(clientId), "ip")

    -- possibly includes a port, strip it
    ip = string.match(ip or "", "^(%d+%.%d+%.%d+%.%d+)")

    if not ip then
        return
    end

    for _, subnet in pairs(subnets) do
        if subnetbans.matches(ip, subnet["subnet"]) then
            return "\n\nYou have been subnet banned from this server, Reason: "..subnet["reason"]
        end
    end
end

function subnetbans.onGameInit()
    load()
end
events.handle("onGameInit", subnetbans.onGameInit)

return subnetbans
