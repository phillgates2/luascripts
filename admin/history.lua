
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

local history = {}

function history.get(clientId, historyId)
    return db.getHistoryItem(historyId)
end

function history.getCount(clientId)
    local playerId = db.getPlayerId(clientId)

    return db.getHistoryCount(playerId)
end

function history.getList(clientId, start, limit)
    local playerId = db.getPlayerId(clientId)

    return db.getHistory(playerId, start, limit)
end

function history.add(victimId, invokerId, type, reason)
    local victimPlayerId = db.getPlayerId(victimId)
    local invokerPlayerId = db.getPlayerId(invokerId)

    -- the history row references both players: without a row for one of them
    -- (the console on a database without its player record, a client with no
    -- GUID) the insert would concatenate a nil into the SQL and throw, taking
    -- the command that was already carried out down with it
    if not victimPlayerId or not invokerPlayerId then
        outputDebug("history.add: no database record for "..(victimPlayerId and "invoker "..tostring(invokerId) or "victim "..tostring(victimId))..", '"..tostring(type).."' entry not stored", 3)

        return false
    end

    db.addHistory(victimPlayerId, invokerPlayerId, type, os.time(), reason or "")

    return true
end

function history.remove(clientId, historyId)
    db.removeHistory(historyId)
end

return history
