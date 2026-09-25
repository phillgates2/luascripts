
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

-- Double jump in the shape jaymod (github.com/budjb/jaymod) gives it: one extra
-- jump per time in the air, inside a short window after the player left the
-- ground, at 1.4 times the normal jump velocity, and only for a player who is
-- alive, upright and off the floor.
--
-- jaymod does it inside the player move. PM_CheckDoubleJump()
-- (src/bgame/bg_pmove.cpp:816) is called from PM_AirMove() and wants the
-- MISC_DOUBLEJUMP bit of its bg_misc cvar, no PMF_DOUBLEJUMPING yet, no
-- EF_PRONE, no PMF_RESPAWNED, upmove >= 10 with PMF_JUMP_HELD clear - the
-- player has to let go of jump and press it again - and less than 850 ms since
-- pmext->jumpTime. On success it writes velocity[2] = JUMP_VELOCITY * 1.4f,
-- adds EV_JUMP and starts the jump animation; PM_AirMove() then sets
-- PMF_DOUBLEJUMPING so it cannot happen twice, and PM_WalkMove() clears that
-- flag again once the player is on the ground.
--
-- ET:Legacy has no such check anywhere in bg_pmove.c, and its Lua API cannot
-- grow one. etlib[] (g_lua.c) exposes no trap_GetUsercmd() and no button,
-- upmove or usercmd state of any kind, and the engine only ever sets
-- PMF_JUMP_HELD in PM_CheckJump(), which PM_WalkMove() calls and PM_AirMove()
-- does not (bg_pmove.c:1306). A jump press in mid air therefore leaves nothing
-- a Lua module can read: PmoveSingle() clears the flag when the key comes up
-- (bg_pmove.c:5214) and an air press sets nothing again. What Lua can see is
-- the take-off (PMF_JUMP_HELD rising, or ps.velocity[3] snapping back up to
-- JUMP_VELOCITY), the airborne state (a trace down from the feet) and the duck
-- flag, which PM_CheckDuck() sets in the air as well (bg_pmove.c:2027).
--
-- So the second jump is asked for from the client and applied by the server,
-- with jaymod's numbers and jaymod's limits:
--
--   g_doublejump         0 = off, 1 = on            (default 1, !doublejump)
--   g_doublejump_mode    command | crouch | auto    (default command)
--   g_doublejump_window  ms after take-off           (default 850)
--   g_doublejump_boost   multiplier on the jump      (default 1.4)
--   g_doublejump_sound   sound to play, "" for none  (default "")
--   g_doublejump_announce 0 = do not push the bind on players (default 1)
--
--   command - the player binds a key to the client command "djump". Bound next
--             to jump, as in  bind SPACE "+moveup;djump"  it plays like
--             jaymod's own double jump: hold to jump, tap again in the air.
--   crouch  - ducking in mid air fires it. No bind needed, at the cost of
--             owning air-crouching.
--   auto    - every take-off is boosted. No second input at all, and so not a
--             double jump so much as a higher one.
--
-- Because an air press is invisible, command mode only works once each player
-- has bound "djump" to something. The first spawn pushes that bind twice where
-- it cannot be missed - a centre print and a message-line copy, both off with
-- g_doublejump_announce 0. Server text cannot show quote characters (the
-- client tokenizer's own note: "this doesn't handle \" escaping"), so the hint
-- prints the runnable  bind MOUSE3 djump  and describes the jump-key bind in
-- words. The exact line to type there is:
-- bind SPACE "+moveup;djump"
--
-- Two things a server owner should know. The velocity is written server side,
-- so the client's own prediction is corrected on the next snapshot - the same
-- snap WolfAdmin's !throw and !launch have always had. And the engine's jump
-- animation and EV_JUMP cannot be triggered from Lua: etlib[] exposes
-- G_AddEvent() but none of the EV_* constants, so g_doublejump_sound is the
-- only feedback this module can give.

local bits = wolfa_requireModule("util.bits")

local constants = wolfa_requireModule("util.constants")
local events = wolfa_requireModule("util.events")
local players = wolfa_requireModule("players.players")
local timers = wolfa_requireModule("util.timers")

local doublejump = {}

-- bg_local.h:53 and bg_pmove.c:72. PM_JUMP_DELAY is the engine's own minimum
-- gap between two jumps, which is the same 850 ms jaymod gives its double jump.
local JUMP_VELOCITY = 270
local PM_JUMP_DELAY = 850

-- bg_public.h:530-538
local PMF_DUCKED = 1
local PMF_JUMP_HELD = 2
local PMF_RESPAWNED = 512

-- bg_public.h:725-752
local EF_DEAD = 0x00000001
local EF_PRONE = 0x00080000

-- bg_public.h:489-497: PM_NORMAL 0, PM_NOCLIP 1, PM_SPECTATOR 2, PM_DEAD 3,
-- PM_FREEZE 4, PM_INTERMISSION 5
local PM_NORMAL = 0

-- the ground probe: how far below the feet to look, and how far the box reaches
-- around them. A player less than GROUND_PROBE units off the floor reads as
-- standing on it, which is what the engine's own ground trace tolerates. The
-- feet are not at ps.origin: the player box's z mins is -24 (bg_pmove.c:427),
-- so the soles sit FEET_OFFSET below the origin. Probing around the origin
-- itself, as this first did, made every player read as airborne all the time.
local FEET_OFFSET = 24
local GROUND_PROBE = 4
local GROUND_LIFT = 1
local PROBE_MINS = { -15, -15, -1 }
local PROBE_MAXS = { 15, 15, 1 }

-- one extra jump per time in the air, as jaymod's PMF_DOUBLEJUMPING gives it
local MAX_AIR_JUMPS = 1

-- A take-off is recognised two ways, and the second one needs a latch: the
-- module's own air jump leaves ps.velocity[3] above the jump impulse too, so
-- the impulse only counts again once the player has been seen below it. That
-- holds whatever the boost and the server gravity are set to, where a fixed
-- quiet period would not.
local IMPULSE_TOLERANCE = 60

local MASK_GROUND = (et and et.MASK_SOLID) or (et and et.CONTENTS_SOLID) or 1

local CVARS = {
    g_doublejump = "1",
    g_doublejump_mode = "command",
    g_doublejump_window = tostring(PM_JUMP_DELAY),
    g_doublejump_boost = "1.4",
    g_doublejump_sound = "",
    g_doublejump_announce = "1",
}

local MODES = { command = true, crouch = true, auto = true }

-- [clientId] = { takeoff, jumps, held, ducked, seenBelow, told }
local state = {}

local function cvar(name)
    local value = et.trap_Cvar_Get(name)

    if value == nil or value == "" then
        return CVARS[name]
    end

    return value
end

local function cvarNumber(name, default)
    return tonumber(cvar(name)) or default
end

function doublejump.isEnabled()
    return cvarNumber("g_doublejump", 1) ~= 0
end

function doublejump.setEnabled(enable)
    et.trap_Cvar_Set("g_doublejump", enable and "1" or "0")

    return enable and true or false
end

function doublejump.getMode()
    local mode = string.lower(cvar("g_doublejump_mode"))

    return MODES[mode] and mode or CVARS.g_doublejump_mode
end

function doublejump.setMode(mode)
    mode = string.lower(tostring(mode or ""))

    if not MODES[mode] then
        return nil
    end

    et.trap_Cvar_Set("g_doublejump_mode", mode)

    return mode
end

function doublejump.getWindow()
    return cvarNumber("g_doublejump_window", PM_JUMP_DELAY)
end

function doublejump.getBoost()
    return cvarNumber("g_doublejump_boost", 1.4)
end

function doublejump.getStatus()
    return {
        enabled = doublejump.isEnabled(),
        mode = doublejump.getMode(),
        window = doublejump.getWindow(),
        boost = doublejump.getBoost(),
        sound = cvar("g_doublejump_sound"),
        announce = cvarNumber("g_doublejump_announce", 1) ~= 0,
        jumpVelocity = JUMP_VELOCITY,
        maxAirJumps = MAX_AIR_JUMPS,
    }
end

function doublejump.reset(clientId)
    state[clientId] = nil
end

local function track(clientId)
    local s = state[clientId]

    if not s then
        s = {
            takeoff = 0, jumps = 0, held = false, ducked = false,
            seenBelow = true, told = false,
        }
        state[clientId] = s
    end

    return s
end

-- Is the player off the floor? The engine does not expose ps.groundEntityNum to
-- Lua (only s.groundEntityNum, which ClientSpawn() sets once and nothing keeps
-- in step), so this sweeps a short box down from the feet and ignores the
-- player's own body. The soles sit FEET_OFFSET below ps.origin.
function doublejump.isAirborne(clientId)
    local origin = et.gentity_get(clientId, "ps.origin")

    if type(origin) ~= "table" then
        return false
    end

    if type(et.trap_Trace) ~= "function" then
        return false
    end

    local feet = origin[3] - FEET_OFFSET

    local ok, tr = pcall(et.trap_Trace,
        { origin[1], origin[2], feet + GROUND_LIFT }, PROBE_MINS, PROBE_MAXS,
        { origin[1], origin[2], feet - GROUND_PROBE }, clientId, MASK_GROUND)

    if not ok or type(tr) ~= "table" then
        return false
    end

    return (tr.fraction or 0) >= 1 and not tr.startsolid and not tr.allsolid
end

-- jaymod's list of reasons not to double jump, in the order that costs least to
-- check. Returns nil plus a reason, or the tracked state when it is allowed.
-- Which input the server listens to is not part of these rules: the frame loop
-- asks them for the crouch trigger and the command handler asks them for the
-- key, so both get the same answer about the player.
function doublejump.check(clientId, levelTime)
    if not doublejump.isEnabled() then
        return nil, "double jump is off on this server"
    end

    if not players.isConnected(clientId) then
        return nil, "not connected"
    end

    local s = state[clientId]

    if not s or s.takeoff == 0 then
        return nil, "no take-off seen yet"
    end

    if s.jumps >= MAX_AIR_JUMPS then
        return nil, "already used"
    end

    if levelTime - s.takeoff > doublejump.getWindow() then
        return nil, "too late"
    end

    local team = et.gentity_get(clientId, "sess.sessionTeam")

    if team ~= constants.TEAM_AXIS and team ~= constants.TEAM_ALLIES then
        return nil, "not playing"
    end

    if (tonumber(et.gentity_get(clientId, "health")) or 0) <= 0 then
        return nil, "not alive"
    end

    -- anything but PM_NORMAL is a player the engine will not move for us:
    -- noclip, spectator, dead, frozen or in intermission (bg_public.h:489-497)
    local pmType = tonumber(et.gentity_get(clientId, "ps.pm_type")) or PM_NORMAL

    if pmType ~= PM_NORMAL then
        return nil, "cannot move right now"
    end

    local flags = tonumber(et.gentity_get(clientId, "ps.pm_flags")) or 0
    local eFlags = tonumber(et.gentity_get(clientId, "ps.eFlags")) or 0

    -- jaymod refuses both of these: PMF_RESPAWNED until the buttons come up,
    -- and a prone player, who has no jump to double
    if bits.hasbit(flags, PMF_RESPAWNED) or bits.hasbit(eFlags, EF_PRONE) or bits.hasbit(eFlags, EF_DEAD) then
        return nil, "not upright"
    end

    if not doublejump.isAirborne(clientId) then
        return nil, "on the ground"
    end

    return s, nil
end

-- The air jump itself: keep the horizontal momentum the player has, the way
-- PM_AirMove() would, and replace the vertical component with jaymod's boosted
-- jump velocity.
function doublejump.apply(clientId, levelTime, s)
    local velocity = et.gentity_get(clientId, "ps.velocity")

    if type(velocity) ~= "table" then
        return false
    end

    local boosted = JUMP_VELOCITY * doublejump.getBoost()

    local ok = pcall(et.gentity_set, clientId, "ps.velocity",
        { velocity[1] or 0, velocity[2] or 0, boosted })

    if not ok then
        return false
    end

    s = s or track(clientId)
    s.jumps = s.jumps + 1

    -- this boost is itself an upward impulse; do not read it as a take-off
    s.seenBelow = false

    local sound = cvar("g_doublejump_sound")

    if sound ~= "" then
        et.trap_SendConsoleCommand(et.EXEC_APPEND,
            "playsound "..clientId.." \""..sound.."\";")
    end

    return true
end

-- One poll per client per frame. Two field reads: pm_flags for the jump flag
-- and ps.velocity for the jump impulse.
local function poll(clientId, levelTime, mode)
    local s = track(clientId)

    local flags = tonumber(et.gentity_get(clientId, "ps.pm_flags")) or 0
    local velocity = et.gentity_get(clientId, "ps.velocity")
    local up = (type(velocity) == "table" and velocity[3]) or 0

    local held = bits.hasbit(flags, PMF_JUMP_HELD)
    local impulse = up >= JUMP_VELOCITY - IMPULSE_TOLERANCE

    if not impulse then
        s.seenBelow = true
    end

    if (held and not s.held) or (impulse and s.seenBelow) then
        -- PM_Jump() sets PMF_JUMP_HELD and only PM_WalkMove() calls it, so a
        -- rising edge is a jump off the ground (bg_pmove.c:826-828). A player
        -- who keeps the key held through a bunny hop never gives that edge, and
        -- for them the velocity snapping back up to the jump impulse is the
        -- same moment - by the time this frame is polled the engine has already
        -- taken some gravity off it, hence the tolerance.
        s.takeoff = levelTime
        s.jumps = 0
        s.seenBelow = false
    end

    s.held = held

    if mode == "auto" then
        -- boost every take-off the moment it happens
        if s.takeoff == levelTime and s.jumps == 0 then
            doublejump.apply(clientId, levelTime, s)
        end

        return s
    end

    if mode == "crouch" then
        -- PM_CheckDuck() needs no ground, so PMF_DUCKED does rise in mid air
        local ducked = bits.hasbit(flags, PMF_DUCKED)

        if ducked and not s.ducked and doublejump.isAirborne(clientId) then
            local allowed = doublejump.check(clientId, levelTime)

            if allowed then
                doublejump.apply(clientId, levelTime, allowed)
            end
        end

        s.ducked = ducked
    end

    return s
end

function doublejump.ongameframe(levelTime)
    if not doublejump.isEnabled() then
        return
    end

    levelTime = tonumber(levelTime) or 0

    local mode = doublejump.getMode()
    local maxClients = tonumber(et.trap_Cvar_Get("sv_maxclients")) or 0

    for clientId = 0, maxClients - 1 do
        if players.isConnected(clientId) then
            poll(clientId, levelTime, mode)
        end
    end
end
events.handle("onGameFrame", doublejump.ongameframe)

-- Tell a player once per map how to get the second jump, so the feature is not
-- invisible to everybody who has not read the release notes. A console print
-- scrolls past unseen in a firefight - and the old one truncated at the first
-- quote it tried to show - so the hint goes where it is seen: a centre print,
-- and a copy on the message line that also lands in the console for copying.
local function announce(clientId)
    if cvarNumber("g_doublejump_announce", 1) == 0 then
        return
    end

    local mode = doublejump.getMode()

    if mode == "command" then
        local hint = "^ddouble jump^7: jump, then tap jump again in mid air. " ..
            "One-time setup in the console: ^3bind MOUSE3 djump^7 - " ..
            "or bind your jump key to ^3+moveup;djump^7 as one quoted command."

        et.trap_SendServerCommand(clientId, "cp \""..hint.."\"")
        et.trap_SendServerCommand(clientId, "cpm \""..hint.."\"")
    elseif mode == "crouch" then
        local hint = "^ddouble jump^7: duck (^3crouch^7) in mid air, within " ..
            doublejump.getWindow().." ms of leaving the ground."

        et.trap_SendServerCommand(clientId, "cp \""..hint.."\"")
        et.trap_SendServerCommand(clientId, "cpm \""..hint.."\"")
    end
end

function doublejump.onclientcommand(clientId)
    if not doublejump.isEnabled() then
        return 0
    end

    local command = et.trap_Argv(0)

    if command ~= "djump" then
        return 0
    end

    -- a client command runs between frames, so the level clock to measure the
    -- jump window against is the one util.timers carries from et_RunFrame()
    local levelTime = timers.getLevelTime()

    local mode = doublejump.getMode()

    -- a key this server does not listen to is worth saying out loud, once
    if mode ~= "command" then
        et.trap_SendServerCommand(clientId, "cp \""..(mode == "auto"
            and "double jump is automatic on this server, no key needed"
            or "this server fires the double jump on a duck in mid air").."\"")

        return 1
    end

    local s = doublejump.check(clientId, levelTime)

    if not s then
        -- the rest are normal play - too late, already used, on the ground -
        -- and repeating them would only spam somebody mashing the bind
        return 1
    end

    doublejump.apply(clientId, levelTime, s)

    return 1
end
events.handle("onClientCommand", doublejump.onclientcommand)

function doublejump.onplayerspawn(clientId)
    local s = track(clientId)

    -- a fresh spawn has no take-off yet, and PMF_RESPAWNED is set until the
    -- player lets go of the buttons
    s.takeoff = 0
    s.jumps = 0
    s.held = false
    s.ducked = false
    s.seenBelow = true

    if doublejump.isEnabled() and not s.told then
        s.told = true

        announce(clientId)
    end
end
events.handle("onPlayerSpawn", doublejump.onplayerspawn)

function doublejump.onclientdisconnect(clientId)
    doublejump.reset(clientId)
end
events.handle("onClientDisconnect", doublejump.onclientdisconnect)

function doublejump.oninit(levelTime, randomSeed, restartMap)
    -- register the cvars, but never over a value the server configuration
    -- already set: an empty read means nothing has claimed the name yet
    for name, value in pairs(CVARS) do
        if et.trap_Cvar_Get(name) == "" then
            et.trap_Cvar_Set(name, value)
        end
    end

    for clientId, _ in pairs(state) do
        doublejump.reset(clientId)
    end
end
events.handle("onGameInit", doublejump.oninit)

return doublejump
