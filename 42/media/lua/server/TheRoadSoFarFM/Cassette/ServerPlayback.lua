local MODULE = "TheRoadSoFarFM"
local cassetteStates = {}

-- Used by the noise module to check that a cassette is really playing.
TheRoadSoFarFMCassetteServer = {
    isPlaying = function(deviceId)
        local state = cassetteStates[deviceId]
        return state ~= nil and state.playing == true
    end,
}

local function validDeviceId(value)
    return type(value) == "string"
        and #value > 0
        and #value <= 64
        and value:match("^[%w_:%-%.]+$") ~= nil
end

local function newState()
    return { trackIndex = 1, version = 1, playing = false }
end

-- The track starts after the inserting sound, so everybody hears the insertion first.
local function insertLeadInMs()
    return TheRoadSoFarFMSync.durationMs(TheRoadSoFarFMCassette.InsertingSound) or 0
end

local function stampState(state, leadInMs)
    local track = TheRoadSoFarFMCassette.Tracks[state.trackIndex]
    state.startedAtMs = getTimestampMs() + (leadInMs or 0)
    state.durationMs = track and TheRoadSoFarFMSync.durationMs(track.Sound) or nil
end

local function sendCassetteState(player, deviceId, state, broadcast, join, reply)
    local args = {
        deviceId = deviceId,
        trackIndex = state.trackIndex,
        version = state.version,
        playing = state.playing == true,
        join = join or "start",
        reply = reply == true,
    }
    if state.playing and state.durationMs and state.startedAtMs then
        local now = getTimestampMs()
        args.durationMs = state.durationMs
        args.elapsedMs = math.max(0, now - state.startedAtMs)
        if state.startedAtMs > now then
            args.leadInMs = state.startedAtMs - now
        end
    end
    if broadcast then
        sendServerCommand(MODULE, "cassetteState", args)
    else
        sendServerCommand(player, MODULE, "cassetteState", args)
    end
end

local function cassetteExpired(state, now)
    return state.playing and state.durationMs ~= nil
        and now - state.startedAtMs >= state.durationMs + TheRoadSoFarFMSync.AdvanceMarginMs
end

local function advanceCassette(deviceId, state)
    state.trackIndex = state.trackIndex % #TheRoadSoFarFMCassette.Tracks + 1
    state.version = state.version + 1
    stampState(state)
    sendCassetteState(nil, deviceId, state, true)
end

-- The same track starts again from its beginning, like pressing stop and play.
local function restartCassette(deviceId, state)
    state.version = state.version + 1
    stampState(state)
    sendCassetteState(nil, deviceId, state, true)
end

-- The server is the cassette clock: it advances tracks on its own while someone is listening.
local lastClockCheckAt = 0
local CLOCK_CHECK_INTERVAL_MS = 250

local function onClockTick()
    local now = getTimestampMs()
    if now - lastClockCheckAt < CLOCK_CHECK_INTERVAL_MS then
        return
    end
    lastClockCheckAt = now

    for deviceId, state in pairs(cassetteStates) do
        if cassetteExpired(state, now)
            and TheRoadSoFarFMListeners.hasAny("cassette", deviceId) then
            advanceCassette(deviceId, state)
        end
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or type(args) ~= "table" or not validDeviceId(args.deviceId) then
        return
    end

    if command == "cassetteRequestState" then
        local state = cassetteStates[args.deviceId]
        if not state then
            state = newState()
            cassetteStates[args.deviceId] = state
        end

        local now = getTimestampMs()
        if cassetteExpired(state, now) then
            advanceCassette(args.deviceId, state)
        end

        local join = "start"
        local elapsed = 0
        local audible = args.audible == true
        if audible and state.playing and state.durationMs then
            elapsed = now - state.startedAtMs
            if elapsed > TheRoadSoFarFMSync.StartThresholdMs then
                local anyOther = TheRoadSoFarFMListeners.summary(
                    "cassette", args.deviceId, player)
                if not anyOther then
                    -- Nobody else is listening: keep the same track and start it again
                    -- instead of skipping to the next one.
                    TheRoadSoFarFMListeners.touch("cassette", args.deviceId, player)
                    restartCassette(args.deviceId, state)
                    print("[TheRoadSoFarFM][MP][Sync] No listeners: restarted cassette track "
                        .. tostring(state.trackIndex) .. " on " .. args.deviceId .. ".")
                    return
                end
                join = "offset"
            end
        end

        if audible and state.playing then
            TheRoadSoFarFMListeners.touch("cassette", args.deviceId, player)
            print("[TheRoadSoFarFM][MP][Sync] Sending cassette state: track "
                .. tostring(state.trackIndex) .. " on " .. args.deviceId .. ", elapsed="
                .. tostring(math.floor(elapsed)) .. " ms, join=" .. join .. ".")
        end
        sendCassetteState(player, args.deviceId, state, false, join, true)
    elseif command == "cassetteStart" or command == "cassetteStop" then
        local state = cassetteStates[args.deviceId]
        if not state then
            state = newState()
            cassetteStates[args.deviceId] = state
        end
        local shouldPlay = command == "cassetteStart"
        if state.playing ~= shouldPlay then
            state.playing = shouldPlay
            state.version = state.version + 1
            if shouldPlay then
                stampState(state, insertLeadInMs())
            end
        end
        sendCassetteState(nil, args.deviceId, state, true)
    elseif command == "cassetteAdvance" then
        local state = cassetteStates[args.deviceId]
        if state and state.playing
            and type(args.trackIndex) == "number"
            and args.trackIndex == state.trackIndex
            and type(args.version) == "number"
            and args.version == state.version then
            advanceCassette(args.deviceId, state)
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
if isServer and isServer() then
    Events.OnTick.Add(onClockTick)
end
