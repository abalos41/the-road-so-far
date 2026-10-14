local MODULE = "TheRoadSoFarFM"
local activeStations = {}
local lastNoiseEventAt = {}
local NOISE_COMMAND_COOLDOWN_MS = 1000
local worldSoundApiWarningReported = false

local function zombieAttractionDisabled()
    return SandboxVars and SandboxVars.TheRoadSoFarFM
        and SandboxVars.TheRoadSoFarFM.DisableZombieAttraction == true
end

local function isFiniteNumber(value)
    return type(value) == "number" and value == value
        and value ~= math.huge and value ~= -math.huge
end

local function emitRadioNoise(args)
    if zombieAttractionDisabled() or not activeStations[args.frequency] then
        return
    end

    if not isFiniteNumber(args.x) or not isFiniteNumber(args.y)
        or not isFiniteNumber(args.z) or not isFiniteNumber(args.radius)
        or not isFiniteNumber(args.volume) then
        return
    end

    local x, y, z = math.floor(args.x), math.floor(args.y), math.floor(args.z)
    local radius = math.floor(args.radius)
    local volume = math.floor(args.volume)
    if math.abs(x) > 1000000 or math.abs(y) > 1000000 or z < 0 or z > 1000
        or radius < 1 or radius > 10000 or volume < 1 or volume > 100 then
        return
    end

    local now = getTimestampMs()
    local lastEventAt = lastNoiseEventAt[args.key]
    if lastEventAt and now - lastEventAt < NOISE_COMMAND_COOLDOWN_MS then
        return
    end

    local worldSoundManager = getWorldSoundManager and getWorldSoundManager()
    if not worldSoundManager or not worldSoundManager.addSoundRepeating then
        if not worldSoundApiWarningReported then
            print("[TheRoadSoFarFM] Repeating world sound API is unavailable; zombie attraction sound was not emitted.")
            worldSoundApiWarningReported = true
        end
        return
    end

    worldSoundManager:addSoundRepeating(nil, x, y, z, radius, volume, volume > 50)
    lastNoiseEventAt[args.key] = now
end

local function playlistConfigForFrequency(frequency)
    if frequency == 99600 then
        return TheRoadSoFarFMConfig
    end
    return nil
end

local function sendPlayback(player, frequency, state, broadcast)
    local args = {
        frequency = frequency,
        sound = state.sound,
        kind = state.kind,
        version = state.version,
        welcome = state.welcome == true,
    }
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
            activeStations[args.frequency] = state
        end
        print("[TheRoadSoFarFM][MP] Sending station state: "
            .. state.sound .. " on " .. tostring(args.frequency) .. ".")
        sendPlayback(player, args.frequency, state, false)
    elseif command == "requestAdvance" then
        local state = activeStations[args.frequency]
        if state and type(args.version) == "number" and args.version == state.version then
            TheRoadSoFarFMPlaylist.advance(state)
            sendPlayback(nil, args.frequency, state, true)
        end
    elseif command == "debugCommercial" then
        local state = activeStations[args.frequency]
        if state and type(args.version) == "number" and args.version == state.version then
            TheRoadSoFarFMPlaylist.forceCommercial(state)
            sendPlayback(nil, args.frequency, state, true)
        end
    elseif command == "radioNoise" then
        if type(args.frequency) == "number" and args.frequency == 99600
            and type(args.key) == "string" and #args.key <= 128 then
            emitRadioNoise(args)
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
print("[TheRoadSoFarFM][MP] Server radio command handler loaded.")
