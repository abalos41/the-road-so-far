local MODULE = "TheRoadSoFarFM"
local cassetteStates = {}

local function validDeviceId(value)
    return type(value) == "string"
        and #value > 0
        and #value <= 64
        and value:match("^[%w_:%-%.]+$") ~= nil
end

local function sendCassetteState(player, deviceId, state, broadcast)
    local args = {
        deviceId = deviceId,
        trackIndex = state.trackIndex,
        version = state.version,
        playing = state.playing == true,
    }
    if broadcast then
        sendServerCommand(MODULE, "cassetteState", args)
    else
        sendServerCommand(player, MODULE, "cassetteState", args)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or type(args) ~= "table" or not validDeviceId(args.deviceId) then
        return
    end

    if command == "cassetteRequestState" then
        local state = cassetteStates[args.deviceId]
        if not state then
            state = { trackIndex = 1, version = 1, playing = false }
            cassetteStates[args.deviceId] = state
        end
        sendCassetteState(player, args.deviceId, state, false)
    elseif command == "cassetteStart" or command == "cassetteStop" then
        local state = cassetteStates[args.deviceId]
        if not state then
            state = { trackIndex = 1, version = 1, playing = false }
            cassetteStates[args.deviceId] = state
        end
        local shouldPlay = command == "cassetteStart"
        if state.playing ~= shouldPlay then
            state.playing = shouldPlay
            state.version = state.version + 1
        end
        sendCassetteState(nil, args.deviceId, state, true)
    elseif command == "cassetteAdvance" then
        local state = cassetteStates[args.deviceId]
        local trackCount = #TheRoadSoFarFMCassette.Tracks
        if state and state.playing
            and type(args.trackIndex) == "number"
            and args.trackIndex == state.trackIndex
            and type(args.version) == "number"
            and args.version == state.version then
            state.trackIndex = state.trackIndex % trackCount + 1
            state.version = state.version + 1
            sendCassetteState(nil, args.deviceId, state, true)
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
