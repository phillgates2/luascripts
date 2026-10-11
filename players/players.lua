
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

local db = wolfa_requireModule("db.db")

local bits = wolfa_requireModule("util.bits")
local events = wolfa_requireModule("util.events")

local players = {}

players.MUTE_CHAT = 1
players.MUTE_VOICE = 2

local data = {[-1337] = {["guid"] = "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"}}

function players.isConnected(clientId)
    return (data[clientId] ~= nil)
end

function players.getName(clientId)
    if clientId == -1337 then
        return "console"
    end

    return et.gentity_get(clientId, "pers.netname")
end

-- the accessors below must survive a slot that is not (or no longer)
-- connected: the engine hands every command the slot number the admin typed,
-- and data[clientId] only exists between onClientConnect and
-- onClientDisconnect. Returning nil (instead of indexing nil) lets acl/commands
-- treat the target as a guest/unknown player - see the players.isConnected()
-- guards in commands/admin/*.lua.
function players.getGUID(clientId)
    return data[clientId] and data[clientId]["guid"]
end

function players.getIP(clientId)
    return data[clientId] and data[clientId]["ip"]
end

function players.getProtocol(clientId)
    return data[clientId] and data[clientId]["protocol"]
end

function players.isBot(clientId)
    return data[clientId] and data[clientId]["bot"]
end

function players.setLastPMSender(clientId, senderId)
    if data[clientId] then
        data[clientId]["lastpmsender"] = senderId
    end
end

function players.getLastPMSender(clientId)
    return data[clientId] and data[clientId]["lastpmsender"]
end

function players.setMuted(clientId, state, type, issued, expires)
    if not data[clientId] then
        return
    end

    data[clientId]["mute"] = nil

    if state == true then
        data[clientId]["mute"] = {
            ["type"] = type,
            ["issued"] = issued,
            ["expires"] = expires
        }
    end
end

function players.isMuted(clientId, type)
    if type == nil then
        return data[clientId] ~= nil and data[clientId]["mute"] ~= nil
    elseif type == players.MUTE_CHAT then
        return data[clientId] ~= nil and data[clientId]["mute"] ~= nil and bits.hasbit(data[clientId]["mute"]["type"], players.MUTE_CHAT)
    elseif type == players.MUTE_VOICE then
        return data[clientId] ~= nil and data[clientId]["mute"] ~= nil and bits.hasbit(data[clientId]["mute"]["type"], players.MUTE_VOICE)
    end

    return false
end

function players.getMuteType(clientId)
    return data[clientId] and data[clientId]["mute"] and data[clientId]["mute"]["type"]
end

function players.getMuteIssuedAt(clientId)
    return data[clientId] and data[clientId]["mute"] and data[clientId]["mute"]["issued"]
end

function players.getMuteExpiresAt(clientId)
    return data[clientId] and data[clientId]["mute"] and data[clientId]["mute"]["expires"]
end

function players.setTeamLocked(clientId, state)
    if data[clientId] then
        data[clientId]["teamlock"] = state
    end
end

function players.isTeamLocked(clientId)
    return data[clientId] and data[clientId]["teamlock"]
end

function players.onClientConnect(clientId, firstTime, isBot)
    local clientInfo = et.trap_GetUserinfo(clientId)

    -- name is NOT yet set in pers.netname, so get all info out of infostring
    data[clientId] = {}

    -- data[clientId]["name"] is cached version for detecting namechanges, do not
    -- use it to retrieve a player's name
    data[clientId]["name"] = et.Info_ValueForKey(clientInfo, "name")
    data[clientId]["guid"] = et.Info_ValueForKey(clientInfo, "cl_guid")
    data[clientId]["ip"] = string.gsub(et.Info_ValueForKey(clientInfo, "ip"), ":%d*", "")
    data[clientId]["protocol"] = tonumber(et.Info_ValueForKey(clientInfo, "protocol"))
    data[clientId]["bot"] = isBot
    data[clientId]["team"] = tonumber(et.gentity_get(clientId, "sess.sessionTeam"))

    if firstTime then
        data[clientId]["new"] = true
    end

    if db.isConnected() then
        local player = db.getPlayer(data[clientId]["guid"])

        if player then
            if firstTime then
                db.updatePlayer(data[clientId]["guid"], data[clientId]["ip"], os.time())
            end

            local alias = db.getAliasByName(player["id"], data[clientId]["name"])

            if alias and firstTime then
                db.updateAlias(alias["id"], os.time())
            elseif not alias then
                db.addAlias(player["id"], data[clientId]["name"], os.time())
            end
        elseif not player then
            db.addPlayer(data[clientId]["guid"], data[clientId]["ip"], os.time(), 1)

            local player = db.getPlayer(data[clientId]["guid"])
            db.addAlias(player["id"], data[clientId]["name"], os.time())
        end
    end
end
events.handle("onClientConnect", players.onClientConnect)

function players.onClientBegin(clientId)
    if not data[clientId] then
        return
    end

    events.trigger("onPlayerReady", clientId, data[clientId]["new"])

    data[clientId]["new"] = false

    -- this is now available
    local clientInfo = et.trap_GetUserinfo(clientId)
end
events.handle("onClientBegin", players.onClientBegin)

function players.onClientDisconnect(clientId)
    data[clientId] = nil
end
events.handle("onClientDisconnect", players.onClientDisconnect)

function players.onClientInfoChange(clientId)
    if not data[clientId] then
        return
    end

    local oldTeam = data[clientId]["team"]
    local newTeam = tonumber(et.gentity_get(clientId, "sess.sessionTeam"))

    if newTeam ~= oldTeam then
        data[clientId]["team"] = newTeam

        events.trigger("onClientTeamChange", clientId, oldTeam, newTeam)
    end

    local oldName = data[clientId]["name"]
    local newName = et.gentity_get(clientId, "pers.netname")

    if newName ~= oldName then
        data[clientId]["name"] = newName

        events.trigger("onClientNameChange", clientId, oldName, newName)
    end
end
events.handle("onClientInfoChange", players.onClientInfoChange)

return players
