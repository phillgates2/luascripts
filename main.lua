
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

local admin
local balancer
local banners
local bans
local history
local mutes
local rules
local subnetbans

local auth

local db

local commands

local bots
local fireteams
local game
local gameplay
local honors
local sprees
local teams
local voting

local greetings
local players
local stats

local bits
local constants
local events
local files
local logs
local pagination
local settings
local tables
local timers
local util

local version = "1.2.1"
local release = "14 April 2020"

local basepath
local homepath
local lualibspath
local luamodspath

-- Every et_* callback below runs on a VM the engine created, and the engine
-- creates that VM from G_LuaInit() - not from et_InitGame(). et_InitGame() is
-- only ever called by G_LuaHook_InitGame(), at the very end of G_InitGame()
-- (g_main.c), while G_LuaInit() runs in the middle of it. A VM can therefore
-- exist, with this file already loaded and all callbacks registered, in these
-- situations:
--
--   * `lua_init`    -> G_LuaInit()      (handled in g_svcmds.c's ConsoleCommand())
--   * `lua_restart` -> G_LuaRestart()   (G_LuaShutdown() + G_LuaInit())
--   * `gLoadLua`    -> Svcmd_LoadLua_f() -> G_LuaRunIsolated()
--
-- None of those three fires et_InitGame(), so on a running map the module is
-- loaded but has no `events` (and no `game`, `commands`, ...) behind it, until
-- the next map load. The engine keeps calling the callbacks:
--
--   * console/rcon commands go through Cmd_ExecuteString() -> SV_GameCommand()
--     -> GAME_CONSOLE_COMMAND -> ConsoleCommand() -> G_LuaHook_ConsoleCommand()
--     -> et_ConsoleCommand() (qcommon/cmd.c, sv_game.c, g_svcmds.c, g_lua.c);
--   * G_Printf() during G_InitGame() reaches G_LuaHook_Print() -> et_Print()
--     before G_LuaHook_InitGame() has run;
--   * G_RunFrame() calls G_LuaHook_RunFrame() -> et_RunFrame() every frame.
--
-- The old code indexed `events`/`game` directly in those callbacks, which is
-- what the live server reported as
--
--   Lua 5.4 API: et_ConsoleCommand error running lua script:
--   '[string "luascripts/wolfadmin/main.lua"]:171: attempt to index a nil value
--   (upvalue 'events')'
--
-- ET:Legacy's own position is that the module has to check for this
-- (etlegacy/etlegacy#1426: "proper checks must be done to prevent the lua error
-- if [the hook] was called before et_InitGame").
--
-- `initialized` is set at the end of et_InitGame(), so a module tree that fails
-- to load half way through (a syntax error, a missing lua library, a bad
-- database setting...) also leaves the callbacks inert instead of turning every
-- command and every frame into another traceback. In that case the engine has
-- already printed the *real* failure once, from G_LuaCall() on et_InitGame() -
-- that first line is the one to fix.
local initialized = false
local warnedUninitialized = false

-- One line to the server console, the first time a callback is used on a module
-- that is not (yet) initialized: an admin who reloaded the scripts at runtime
-- needs to know the module is dormant, and why.
local function warnUninitialized(hook)
    if warnedUninitialized then
        return
    end

    warnedUninitialized = true

    if not et or type(et.G_Print) ~= "function" then
        return
    end

    local why
    if events then
        why = "et_InitGame() did not finish loading the modules - fix the error printed above and load a map"
    else
        why = "the scripts were loaded outside a map load (lua_init, lua_restart and gLoadLua do not call et_InitGame()) - load a map to activate WolfAdmin"
    end

    et.G_Print("[WolfAdmin] warning: "..hook.."() called on an uninitialized module; "..why.."\n")
end

-- Guard for the engine callbacks. Returns false when the module tree is not
-- loaded yet (reporting the first such call), so the caller can hand the engine
-- its own "not handled" answer instead of raising a Lua error per command or
-- frame. The engine only ever treats the integer 1 as an interception and a
-- string as a client rejection (see the G_LuaHook_* functions in g_lua.c), so
-- both 0 and nil mean "carry on".
local function ready(hook)
    if initialized then
        return true
    end

    warnUninitialized(hook)

    return false
end

-- need to do this somewhere else
function wolfa_getVersion()
    return version
end

function wolfa_getRelease()
    return release
end

function wolfa_getBasePath()
    return basepath
end

function wolfa_getHomePath()
    return homepath
end

function wolfa_getLuaLibsPath()
    return lualibspath
end

function wolfa_getLuaModsPath()
    return luamodspath
end

function wolfa_requireLib(lib)
    return require(wolfa_getLuaLibsPath().."/"..string.gsub(lib, "%.", "/"))
end

function wolfa_requireModule(module)
    return require(wolfa_getLuaModsPath().."/"..string.gsub(module, "%.", "/"))
end

function et_InitGame(levelTime, randomSeed, restartMap)
    -- set up paths
    basepath = string.gsub(et.trap_Cvar_Get("fs_basepath"), "\\", "/").."/"..et.trap_Cvar_Get("fs_game").."/"
    homepath = string.gsub(et.trap_Cvar_Get("fs_homepath"), "\\", "/").."/"..et.trap_Cvar_Get("fs_game").."/"
    lualibspath = "lualibs"
    luamodspath = "luascripts/wolfadmin"

    if debug then
        luamodspath = string.sub(debug.getinfo(1).source, 0, -10)
    end

    -- load modules
    -- util first, so event bus exists before game modules register
    wolfa_requireModule("util.debug")

    bits = wolfa_requireModule("util.bits")
    constants = wolfa_requireModule("util.constants")
    events = wolfa_requireModule("util.events")
    files = wolfa_requireModule("util.files")
    logs = wolfa_requireModule("util.logs")
    pagination = wolfa_requireModule("util.pagination")
    settings = wolfa_requireModule("util.settings")
    tables = wolfa_requireModule("util.tables")
    timers = wolfa_requireModule("util.timers")
    util = wolfa_requireModule("util.util")

    admin = wolfa_requireModule("admin.admin")
    balancer = wolfa_requireModule("admin.balancer")
    banners = wolfa_requireModule("admin.banners")
    bans = wolfa_requireModule("admin.bans")
    history = wolfa_requireModule("admin.history")
    mutes = wolfa_requireModule("admin.mutes")
    rules = wolfa_requireModule("admin.rules")
    subnetbans = wolfa_requireModule("admin.subnetbans")

    auth = wolfa_requireModule("auth.auth")

    db = wolfa_requireModule("db.db")

    commands = wolfa_requireModule("commands.commands")

    bots = wolfa_requireModule("game.bots")
    botvote = wolfa_requireModule("game.botvote")
    doublejump = wolfa_requireModule("game.doublejump")
    game = wolfa_requireModule("game.game")
    gameplay = wolfa_requireModule("game.gameplay")
    honors = wolfa_requireModule("game.honors")
    fireteams = wolfa_requireModule("game.fireteams")
    sprees = wolfa_requireModule("game.sprees")
    teams = wolfa_requireModule("game.teams")
    voting = wolfa_requireModule("game.voting")

    greetings = wolfa_requireModule("players.greetings")
    players = wolfa_requireModule("players.players")
    stats = wolfa_requireModule("players.stats")

    -- register the module
    et.RegisterModname("WolfAdmin "..wolfa_getVersion())
    et.trap_SendConsoleCommand(et.EXEC_APPEND, "sets mod_wolfadmin "..wolfa_getVersion()..";")

    outputDebug("Module "..wolfa_getVersion().." ("..wolfa_getRelease()..") loaded successfully. Created by Timo 'Timothy' Smit.")

    -- the whole module tree is loaded: from here on the engine callbacks may
    -- reach it (see the note above `initialized`)
    initialized = true
    warnedUninitialized = false

    events.trigger("onGameInit", levelTime, randomSeed, (restartMap == 1))
end

function et_ShutdownGame(restartMap)
    -- only the event bus is needed here: when et_InitGame() failed half way
    -- through, the modules that did load still get their onGameShutdown
    if events then
        events.trigger("onGameShutdown", (restartMap == 1))
    end
end

function et_ConsoleCommand(cmdText)
    if not ready("et_ConsoleCommand") then
        return 0
    end

    return events.trigger("onServerCommand", cmdText)
end

function et_ClientConnect(clientId, firstTime, isBot)
    if not ready("et_ClientConnect") then
        return
    end

    return events.trigger("onClientConnectAttempt", clientId, (firstTime == 1), (isBot == 1))
end

function et_ClientBegin(clientId)
    if not ready("et_ClientBegin") then
        return
    end

    events.trigger("onClientBegin", clientId)
end

function et_ClientDisconnect(clientId)
    if not ready("et_ClientDisconnect") then
        return
    end

    events.trigger("onClientDisconnect", clientId)
end

function et_ClientUserinfoChanged(clientId)
    if not ready("et_ClientUserinfoChanged") then
        return
    end

    events.trigger("onClientInfoChange", clientId)
end

function et_ClientCommand(clientId, cmdText)
    if not ready("et_ClientCommand") then
        return 0
    end

    return events.trigger("onClientCommand", clientId, cmdText)
end

function et_RunFrame(levelTime)
    if not ready("et_RunFrame") then
        return
    end

    local gameState = tonumber(et.trap_Cvar_Get("gamestate"))
    
    if game.getState() ~= gameState then
        events.trigger("onGameStateChange", gameState)
    end
    
    events.trigger("onGameFrame", levelTime)
end

-- no callbacks defined for these things, so had to invent some special regexes
-- note for etlegacy team: please take a look at this, might come in handy :-)
-- The engine calls this while the map's entity definition is parsed
-- (G_SpawnEntitiesFromString, g_spawn.c): level.spawning is still qtrue, which
-- makes it the ONLY moment et.G_CreateEntity() is legal - at any other time
-- G_SpawnGEntityFromSpawnVars() hits G_SpawnString()'s "called while not
-- spawning" G_Error and takes the whole server down (CRASH-REPORT.md).
--
-- This is also the engine's FIRST Lua callback: the modules - and the event
-- bus with them - only load in et_InitGame(), which the engine fires after
-- the map ents are done. So the throwable-knife entity reserve is built here,
-- directly, and handed to game/gameplay.lua through the wolfa_knife_reserve
-- global; gameplay adopts and re-verifies it in onGameInit. Keep this
-- dependency-free on purpose.
function et_SpawnEntitiesFromString()
    wolfa_knife_reserve = nil
    if type(et.G_CreateEntity) ~= "function" then return end

    local KNIFE_MAX_LIVE          = 12   -- keep in step with game/gameplay.lua
    local KNIFE_MIN_FREE_ENTITIES = 8
    local parked = "0 0 -4096"           -- knife.PARKED in game/gameplay.lua

    -- G_Spawn() G_Errors on an empty pool even at map load: never build the
    -- reserve down past the safety margin
    local needed = KNIFE_MAX_LIVE
    local ok, free = pcall(et.G_EntitiesFree)
    if ok and type(free) == "number" then
        needed = math.min(needed, math.max(0, free - KNIFE_MIN_FREE_ENTITIES))
    end

    local reserve = {}
    for _ = 1, needed do
        local okc, ent = pcall(et.G_CreateEntity,
            'classname target_position origin "' .. parked .. '"')
        if not okc or type(ent) ~= "number" then break end
        -- the C glue does g_entities + n raw: never keep a number outside
        -- the array (slots below MAX_CLIENTS are the players')
        if ent < (et.MAX_CLIENTS or 64) or ent >= (et.MAX_GENTITIES or 1024) then break end
        -- G_SpawnGEntityFromSpawnVars() frees the entity again when the
        -- classname has no spawn function: verify the slot is really ours
        local oki, inuse = pcall(et.gentity_get, ent, "inuse")
        if not oki or inuse ~= 1 then break end
        pcall(et.trap_UnlinkEntity, ent)   -- G_Lua_CreateEntity linked it
        reserve[#reserve + 1] = ent
    end
    wolfa_knife_reserve = reserve
end

function et_Print(consoleText)
    -- G_Printf() reaches this hook while a map is still being initialized
    -- (G_InitGame() prints long before G_LuaHook_InitGame() runs), and the
    -- engine returns the first string back as the replacement line
    if not ready("et_Print") then
        return
    end

    local result, poll

    if et.trap_Cvar_Get("fs_game") == "legacy" then
        result, poll = string.match(consoleText, "^Vote (%w+): %(Y:%d+-N:%d+%) %[poll%] ([%w%s]+)\n$")
    else
        result, poll = string.match(consoleText, "^Vote (%w+): %[poll%] ([%w%s]+)\n$")
    end

    if result then
        events.trigger("onPollFinish", (result == "Passed"), poll)
    end
    
    local clientMedic, clientVictim = string.match(consoleText, "^Medic_Revive:%s+(%d+)%s+(%d+)\n$")
    clientMedic = tonumber(clientMedic)
    clientVictim = tonumber(clientVictim)
    if clientMedic and clientVictim then
        events.trigger("onPlayerRevive", clientMedic, clientVictim)
    end
end

function et_Obituary(victimId, killerId, mod)
    if not ready("et_Obituary") then
        return
    end

    events.trigger("onPlayerDeath", victimId, killerId, mod)
end

function et_ClientSpawn(clientId, revived)
    if not ready("et_ClientSpawn") then
        return
    end

    -- Always fire the event (revived==0 fresh spawn, revived==1 after a
    -- medic revive). Several gameplay tweaks (weapon grants, state resets)
    -- need to run after revive as well as after a fresh spawn, and handlers
    -- receive the `revived` flag so they can distinguish the two cases.
    events.trigger("onPlayerSpawn", clientId, (revived == 1))
end

function et_Damage(targetId, attackerId, damage, damageFlags, meansOfDeath)
    if not ready("et_Damage") then
        return 0
    end

    return events.trigger("onDamage", targetId, attackerId, damage, damageFlags, meansOfDeath)
end

function et_WeaponFire(clientId, weapon)
    if not ready("et_WeaponFire") then
        return 0
    end

    return events.trigger("onWeaponFire", clientId, weapon)
end
