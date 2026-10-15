local MODULE = "TheRoadSoFarFM"
local activeStations = {}

-- Used by the noise module to check that a station is really on the air.
TheRoadSoFarFMRadioServer = {
    isStationActive = function(frequency)
        return activeStations[frequency] ~= nil
    end,
}

local function playlistConfigForFrequency(frequency)
    if frequency == 99600 then
        return TheRoadSoFarFMConfig
    end
    return nil
end

local function stampState(state)
    state.startedAtMs = getTimestampMs()
    state.durationMs = TheRoadSoFarFMSync.durationMs(state.sound)
end

local function sendPlayback(player, frequency, state, broadcast, join, reply)
    local args = {
        frequency = frequency,
        sound = state.sound,
        kind = state.kind,
        version = state.version,
        welcome = state.welcome == true,
        join = join or "start",
        reply = reply == true,
    }
    if state.durationMs and state.startedAtMs then
        args.durationMs = state.durationMs
        args.elapsedMs = math.max(0, getTimestampMs() - state.startedAtMs)
    end
    if state.kind == "song" then
        local config = state.config or TheRoadSoFarFMConfig
        args.title = config.TrackTitles and config.TrackTitles[state.sound]
    end
    if broadcast then
        sendServerCommand(MODULE, "play", args)
    else
        sendServerCommand(player, MODULE, "play", args)
    end
end

local function stationExpired(state, now)
    return state.durationMs ~= nil
        and now - state.startedAtMs >= state.durationMs + TheRoadSoFarFMSync.AdvanceMarginMs
end

local function advanceAndBroadcast(frequency, state)
    TheRoadSoFarFMPlaylist.advance(state)
    stampState(state)
    sendPlayback(nil, frequency, state, true)
end

-- The server is the station clock: it advances tracks on its own while someone is listening.
local lastClockCheckAt = 0
local CLOCK_CHECK_INTERVAL_MS = 250

local function onClockTick()
    local now = getTimestampMs()
    if now - lastClockCheckAt < CLOCK_CHECK_INTERVAL_MS then
        return
    end
    lastClockCheckAt = now

    for frequency, state in pairs(activeStations) do
        if stationExpired(state, now)
            and TheRoadSoFarFMListeners.hasAny("radio", frequency) then
            advanceAndBroadcast(frequency, state)
        end
    end
end

local function onClientCommand(module, command, player, args)
    if command == "requestStart" then
        print("[TheRoadSoFarFM][MP] Server received requestStart: module="
            .. tostring(module) .. ", frequency="
            .. tostring(type(args) == "table" and args.frequency or nil) .. ".")
    end

    if module ~= MODULE or type(args) ~= "table" then
        return
    end

    if command == "requestStart" then
        local config = playlistConfigForFrequency(args.frequency)
        if not config then
            print("[TheRoadSoFarFM][MP] Rejected station-state request for frequency "
                .. tostring(args.frequency) .. ".")
            return
        end

        local state = activeStations[args.frequency]
        if not state then
            state = TheRoadSoFarFMPlaylist.createState(config)
            stampState(state)
            activeStations[args.frequency] = state
        end

        local now = getTimestampMs()
        if stationExpired(state, now) then
            advanceAndBroadcast(args.frequency, state)
        end

        local join = "start"
        local elapsed = state.durationMs and now - state.startedAtMs or 0
        if state.durationMs and elapsed > TheRoadSoFarFMSync.StartThresholdMs then
            local anyOther, nearby = TheRoadSoFarFMListeners.summary("radio", args.frequency, player)
            if not anyOther then
                -- Nobody is listening, so move on to the next track for the late joiner
                -- instead of repeating the current one.
                TheRoadSoFarFMListeners.touch("radio", args.frequency, player)
                advanceAndBroadcast(args.frequency, state)
                print("[TheRoadSoFarFM][MP][Sync] No listeners: advanced to " .. state.sound
                    .. " on " .. tostring(args.frequency) .. ".")
                return
            end
            join = nearby and "wait" or "offset"
        end

        TheRoadSoFarFMListeners.touch("radio", args.frequency, player)
        print("[TheRoadSoFarFM][MP][Sync] Sending station state: " .. state.sound .. " on "
            .. tostring(args.frequency) .. ", elapsed=" .. tostring(math.floor(elapsed))
            .. " ms, join=" .. join .. ".")
        sendPlayback(player, args.frequency, state, false, join, true)
    elseif command == "requestAdvance" then
        local state = activeStations[args.frequency]
        if state and type(args.version) == "number" and args.version == state.version then
            advanceAndBroadcast(args.frequency, state)
        end
    elseif command == "debugCommercial" then
        local state = activeStations[args.frequency]
        if state and type(args.version) == "number" and args.version == state.version then
            TheRoadSoFarFMPlaylist.forceCommercial(state)
            stampState(state)
            sendPlayback(nil, args.frequency, state, true)
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
if isServer and isServer() then
    Events.OnTick.Add(onClockTick)
end
print("[TheRoadSoFarFM][MP] Server radio command handler loaded.")
