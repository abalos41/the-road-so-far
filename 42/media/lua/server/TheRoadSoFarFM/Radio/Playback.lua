local MODULE = "TheRoadSoFarFM"
local activeRadios = {}
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
    if zombieAttractionDisabled() or not activeRadios[args.key] then
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

local function sendPlayback(player, key, state, broadcast)
    local args = {
        key = key,
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
    if module ~= MODULE or not args or type(args.key) ~= "string" or #args.key > 128 then
        return
    end

    local key = args.key
    if command == "requestStart" then
        local config = playlistConfigForFrequency(args.frequency)
        if not config then
            return
        end

        local state = activeRadios[key]
        if not state then
            state = TheRoadSoFarFMPlaylist.createState(config)
            activeRadios[key] = state
            sendPlayback(nil, key, state, true)
        else
            sendPlayback(player, key, state, false)
        end
    elseif command == "requestAdvance" then
        local state = activeRadios[key]
        if state and type(args.version) == "number" and args.version == state.version then
            TheRoadSoFarFMPlaylist.advance(state)
            sendPlayback(nil, key, state, true)
        end
    elseif command == "debugCommercial" then
        local state = activeRadios[key]
        if state and type(args.version) == "number" and args.version == state.version then
            TheRoadSoFarFMPlaylist.forceCommercial(state)
            sendPlayback(nil, key, state, true)
        end
    elseif command == "requestStop" and activeRadios[key] then
        activeRadios[key] = nil
        lastNoiseEventAt[key] = nil
        sendServerCommand(MODULE, "stop", { key = key })
    elseif command == "radioNoise" then
        emitRadioNoise(args)
    end
end

Events.OnClientCommand.Add(onClientCommand)
