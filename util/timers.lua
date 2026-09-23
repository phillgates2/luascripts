
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

local events = wolfa_requireModule("util.events")
local tables = wolfa_requireModule("util.tables")

local timers = {}

local data = {}
local nextId = 0

-- The level clock: the reading the engine compares entity timestamps against.
-- G_InitGame() hands it to Lua as et_InitGame(levelTime, ...) and every frame
-- as et_RunFrame(levelTime), where level.time = the server's own svs.time
-- (g_main.c:4635, vmMain's GAME_RUN_FRAME case). The engine's checks all use
-- it: s.onFireEnd > level.time in the burn loop (g_active.c:206), pers.*EndTime
-- deadlines, pain_debounce_time, and so on.
--
-- It is NOT the same reading as et.trap_Milliseconds(), which is
-- Sys_Milliseconds() - the process clock. The two only agree while
-- sv_serverTimeReset is 0 and the server has not been up long enough to hit
-- the 0x70000000 wrap that forces a reset anyway (sv_init.c:656). With
-- sv_serverTimeReset 1 the level clock restarts at every map change while
-- trap_Milliseconds() keeps counting, so a timestamp written with the process
-- clock lands minutes or hours in the future of the level clock.
--
-- Anything Lua writes to a field the engine later compares against level.time
-- has to be stamped from here. See GAMEPLAY-FIX.md sections 8.5 and 9.
local levelTime = 0

-- timers.getLevelTime(): milliseconds on the level clock, as of the last frame
-- the engine ran. Use this instead of et.trap_Milliseconds() whenever the value
-- is stored somewhere the engine reads back.
function timers.getLevelTime()
    return levelTime
end

function timers.add(func, interval, rep, ...)
    local args = {...}
    
    table.insert(data, {
        ["id"] = nextId,
        ["function"] = func,
        ["start"] = et.trap_Milliseconds(),
        ["interval"] = interval,
        ["iteration"] = 0,
        ["repeat"] = rep,
        ["args"] = args
    })
    
    nextId = nextId + 1
    
    return nextId - 1
end

function timers.remove(id)
    for i = 1, #data do
        if data[i]["id"] == id then
            table.remove(data, i)
            
            return
        end
    end
end

function timers.oninit(initLevelTime)
    -- et_InitGame(levelTime, ...) carries the level clock, so a command that
    -- runs before the first frame still stamps from the right base.
    levelTime = tonumber(initLevelTime) or 0
end
events.handle("onGameInit", timers.oninit)

function timers.ongameframe(frameLevelTime)
    -- refresh the shared clock before anything else reads it this frame; this
    -- handler is registered when util.timers loads, which main.lua does before
    -- the game modules, so it is the first onGameFrame handler to run.
    levelTime = tonumber(frameLevelTime) or levelTime

    for id, timer in pairs(data) do
        if (et.trap_Milliseconds() - timer["start"]) > timer["interval"] then
            timer["function"](tables.unpack(timer["args"]))
            timer["iteration"] = timer["iteration"] + 1
            
            if timer["repeat"] == 0 or timer["iteration"] < timer["repeat"] then
                timer["start"] = et.trap_Milliseconds()
            else
                timers.remove(timer["id"])
            end
        end
    end
end
events.handle("onGameFrame", timers.ongameframe)

return timers
