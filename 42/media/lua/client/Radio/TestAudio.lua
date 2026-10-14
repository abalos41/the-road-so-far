TheRoadSoFarFMTestAudio = TheRoadSoFarFMTestAudio or {}

local testEmitter
local testSound
local activeTracks = {}
local localPlaylists = {}
local pendingStarts = {}
local pendingStops = {}
local approvedStarts = {}
local approvedStations = {}
local worldSoundCounters = {}
local pendingInitialAnnouncement
local initialAnnouncementDisplayed = false
local RADIO_RANGE_MULTIPLIER = 3.5
local RADIO_GAIN_MULTIPLIER = 0.75
local MODULE = "TheRoadSoFarFM"
local ROAD_SO_FAR_FREQUENCY = 99600
local USER_TRACKS_FREQUENCY = 100200
local RADIO_DEVICE_HANDOFF_WINDOW_MS = 5000
local STATION_START_RETRY_MS = 3000
local INITIAL_ANNOUNCEMENT_DELAY = 300
local missingUserTracksPlaylistReported = false
local worldSoundApiWarningReported = false
local deviceSoundRangeWarningReported = false
local freeEmitterWarningReported = false
local emitterPositionWarningReported = false
local emitter3DWarningReported = false
local soundWarmupQueue = {}
local queuedSoundWarmups = {}
local warmedSoundNames = {}
local soundWarmupScheduled = false
local soundWarmupSuccesses = 0
local soundWarmupFailures = 0
local SLOW_AUDIO_OPERATION_THRESHOLD_MS = 16

local function logSlowAudioOperation(operation, soundName, startedAt)
    local duration = getTimestampMs() - startedAt
    if duration >= SLOW_AUDIO_OPERATION_THRESHOLD_MS then
        print(string.format(
            "[TheRoadSoFarFM][AudioPerf] %s for %s took %d ms.",
            operation,
            tostring(soundName),
            duration
        ))
    end
end

local function warmSoundClip(soundName)
    if not GameSounds or not GameSounds.getSound then
        return false, "GameSounds API is unavailable."
    end

    local gameSound = GameSounds.getSound(soundName)
    if not gameSound or not gameSound.getRandomClip then
        return false, "sound event or clip API is unavailable."
    end

    local clip = gameSound:getRandomClip()
    if not clip then
        return false, "sound event has no clip."
    end

    local world = IsoWorld and IsoWorld.instance
    if not world or not world.getFreeEmitter then
        return false, "world free-emitter API is unavailable."
    end

    local emitter = world:getFreeEmitter()
    if not emitter or not emitter.playClip or not emitter.setVolume or not emitter.stopSound then
        return false, "sound emitter clip playback API is unavailable."
    end

    local soundHandle = emitter:playClip(clip, nil)
    if not soundHandle or soundHandle == 0 then
        return false, "playClip did not return a sound handle."
    end

    local volumeSet, volumeError = pcall(function()
        emitter:setVolume(soundHandle, 0)
    end)
    local soundStopped, stopError = pcall(function()
        emitter:stopSound(soundHandle)
    end)
    if not soundStopped then
        return false, "could not stop warm-up clip: " .. tostring(stopError)
    end
    if not volumeSet then
        return false, "could not mute warm-up clip: " .. tostring(volumeError)
    end

    return true
end

local function queueAllSoundWarmup()
    if soundWarmupScheduled then
        return
    end
    soundWarmupScheduled = true

    local radioCount = 0
    local userTracksCount = 0
    local cassetteCount = 0
    local function queueSound(soundName)
        if type(soundName) ~= "string" or soundName == ""
            or warmedSoundNames[soundName] or queuedSoundWarmups[soundName] then
            return false
        end
        queuedSoundWarmups[soundName] = true
        soundWarmupQueue[#soundWarmupQueue + 1] = soundName
        return true
    end

    local radioConfig = TheRoadSoFarFMConfig
    if radioConfig and type(radioConfig.Tracks) == "table" then
        for _, soundName in ipairs(radioConfig.Tracks) do
            if queueSound(soundName) then
                radioCount = radioCount + 1
            end
        end
        if queueSound(radioConfig.Commercial) then
            radioCount = radioCount + 1
        end
        if queueSound(radioConfig.Rewind) then
            radioCount = radioCount + 1
        end
    else
        print("[TheRoadSoFarFM] Cannot warm radio clips: playlist configuration is unavailable.")
    end

    local isMultiplayerClient = isClient and isClient()
    local userTracksConfig = TheRoadSoFarFMUserTracksConfig
    if not isMultiplayerClient and userTracksConfig and type(userTracksConfig.Tracks) == "table" then
        for _, soundName in ipairs(userTracksConfig.Tracks) do
            if queueSound(soundName) then
                userTracksCount = userTracksCount + 1
            end
        end
    end

    local cassettePlaylist = TheRoadSoFarFMCassette
    if cassettePlaylist then
        if queueSound(cassettePlaylist.InsertingSound) then
            cassetteCount = cassetteCount + 1
        end
        for _, track in ipairs(cassettePlaylist.Tracks or {}) do
            if type(track) == "table" and queueSound(track.Sound) then
                cassetteCount = cassetteCount + 1
            end
        end
    else
        print("[TheRoadSoFarFM] Cannot warm cassette clips: playlist configuration is unavailable.")
    end

    print(string.format(
        "[TheRoadSoFarFM] Queued pre-map clip warm-up: %d radio, %d User Tracks, %d cassette (%d total).",
        radioCount,
        userTracksCount,
        cassetteCount,
        #soundWarmupQueue
    ))
end

local function warmNextSoundClip()
    if #soundWarmupQueue == 0 then
        return
    end

    local soundName = table.remove(soundWarmupQueue, 1)
    queuedSoundWarmups[soundName] = nil
    local startedAt = getTimestampMs()
    local callSucceeded, warmed, errorMessage = pcall(warmSoundClip, soundName)
    logSlowAudioOperation("playClip warmup", soundName, startedAt)

    if not callSucceeded then
        soundWarmupFailures = soundWarmupFailures + 1
        print("[TheRoadSoFarFM] Unexpected error warming " .. soundName .. ": " .. tostring(warmed))
    elseif not warmed then
        soundWarmupFailures = soundWarmupFailures + 1
        print("[TheRoadSoFarFM] Could not warm " .. soundName .. ": " .. tostring(errorMessage))
    else
        soundWarmupSuccesses = soundWarmupSuccesses + 1
        warmedSoundNames[soundName] = true
    end

    if #soundWarmupQueue == 0 then
        print(string.format(
            "[TheRoadSoFarFM] Pre-map clip warm-up completed: %d succeeded, %d failed.",
            soundWarmupSuccesses,
            soundWarmupFailures
        ))
    end
end

local function warmAllSoundClipsBeforeMapLoad()
    queueAllSoundWarmup()
    while #soundWarmupQueue > 0 do
        warmNextSoundClip()
    end
end

local function getFreeEmitterAt(x, y, z, soundDescription)
    local world = getWorld and getWorld()
    if not world or not world.getFreeEmitter then
        if not freeEmitterWarningReported then
            print("[TheRoadSoFarFM] Cannot play " .. soundDescription .. ": world free-emitter API is unavailable.")
            freeEmitterWarningReported = true
        end
        return nil
    end

    local startedAt = getTimestampMs()
    local emitter = world:getFreeEmitter(x, y, z)
    logSlowAudioOperation("getFreeEmitter", soundDescription, startedAt)
    if not emitter then
        print("[TheRoadSoFarFM] Cannot play " .. soundDescription .. ": no free sound emitter is available.")
        return nil
    end
    if not emitter.setPos then
        if not emitterPositionWarningReported then
            print("[TheRoadSoFarFM] Cannot play " .. soundDescription .. ": sound emitter position API is unavailable.")
            emitterPositionWarningReported = true
        end
        return nil
    end

    startedAt = getTimestampMs()
    emitter:setPos(x, y, z)
    logSlowAudioOperation("setPos", soundDescription, startedAt)
    return emitter
end

local function setEmitter3D(emitter, soundHandle, is3D, soundDescription)
    if not emitter.set3D then
        if not emitter3DWarningReported then
            print("[TheRoadSoFarFM] Cannot configure " .. soundDescription .. ": sound emitter 3D API is unavailable.")
            emitter3DWarningReported = true
        end
        return false
    end

    local startedAt = getTimestampMs()
    emitter:set3D(soundHandle, is3D)
    logSlowAudioOperation("set3D", soundDescription, startedAt)
    return true
end

local function zombieAttractionDisabled()
    return SandboxVars and SandboxVars.TheRoadSoFarFM
        and SandboxVars.TheRoadSoFarFM.DisableZombieAttraction == true
end

local function announceTrackTitle(title, device, deviceData, player, isUserTracksTrack)
    if type(title) ~= "string" or title == "" then
        return
    end

    local red, green, blue = 0.53, 0.81, 0.92
    if isUserTracksTrack then
        red, green, blue = 1, 0, 0
    end

    if instanceof(device, "Radio") then
        local startedAt = getTimestampMs()
        player:SayRadio(
            title,
            red,
            green,
            blue,
            UIFont.Medium,
            deviceData:getDeviceVolumeRange(),
            deviceData:getChannel(),
            "radio"
        )
        logSlowAudioOperation("SayRadio", title, startedAt)
        return
    end

    if not device or not device.AddDeviceText then
        print("[TheRoadSoFarFM] Cannot announce track title: radio device text API is unavailable.")
        return
    end

    local codes = ""
    local startedAt = getTimestampMs()
    if instanceof(device, "VehiclePart") then
        device:AddDeviceText(title, red, green, blue, nil, codes, -1)
    else
        device:AddDeviceText(player, title, red, green, blue, nil, codes, -1)
    end
    logSlowAudioOperation("AddDeviceText", title, startedAt)
end

local WELCOME_MESSAGE = "Welcome to The Road So Far FM. Enjoy the mod!"

local function getPlaylistConfig(frequency)
    if frequency == ROAD_SO_FAR_FREQUENCY then
        return TheRoadSoFarFMConfig
    end

    if frequency ~= USER_TRACKS_FREQUENCY then
        return nil
    end

    if isClient() then
        return nil
    end

    local userTracksPlaylist = TheRoadSoFarFMUserTracksConfig
    if userTracksPlaylist and type(userTracksPlaylist.Tracks) == "table"
        and #userTracksPlaylist.Tracks > 0 then
        return userTracksPlaylist
    end
    if not missingUserTracksPlaylistReported then
        print("[TheRoadSoFarFM] User Tracks has no generated songs. Add tracks to UserTracks and run the playlist BAT.")
        missingUserTracksPlaylistReported = true
    end
    return nil
end

function TheRoadSoFarFMTestAudio.play()
    local player = getPlayer()
    if not player then
        print("[TheRoadSoFarFM] Cannot play test audio: no player is available.")
        return
    end

    if testSound and testEmitter then
        testEmitter:stopSound(testSound)
    end
    testEmitter = nil
    testSound = nil

    testEmitter = getFreeEmitterAt(
        player:getX(),
        player:getY(),
        player:getZ(),
        "test audio"
    )
    if not testEmitter then
        return
    end
    local playlistConfig = TheRoadSoFarFMConfig
    testSound = testEmitter:playSound(playlistConfig.Tracks[1])
    if not testSound then
        print("[TheRoadSoFarFM] Failed to start the first playlist track.")
        testEmitter = nil
    elseif not setEmitter3D(testEmitter, testSound, false, "test audio") then
        testEmitter:stopSound(testSound)
        testEmitter = nil
        testSound = nil
    end
end

function TheRoadSoFarFMTestAudio.stop()
    if testSound and testEmitter then
        testEmitter:stopSound(testSound)
    end
    testEmitter = nil
    testSound = nil
end

local function portableRadioID(device)
    if instanceof(device, "Radio") then
        return device:getID()
    end
    local modData = device.getModData and device:getModData()
    return modData and modData.RadioItemID
end

local function radioKey(device)
    if instanceof(device, "VehiclePart") then
        local vehicle = device:getVehicle()
        if vehicle then
            return "vehicle:" .. tostring(vehicle:getMechanicalID())
        end
    end

    local radioItemID = portableRadioID(device)
    if radioItemID then
        return "item:" .. tostring(radioItemID)
    end

    local square = device:getSquare()
    if square then
        return string.format(
            "world:%d:%d:%d",
            square:getX(),
            square:getY(),
            square:getZ()
        )
    end

    return nil
end

local function playbackKey(deviceData, deviceIdentity, channel, currentDevices)
    local key = deviceIdentity .. ":channel:" .. tostring(channel)
    if activeTracks[key] then
        return key
    end

    local matchingKey
    for activeKey, track in pairs(activeTracks) do
        local previousRadioID = track.device and portableRadioID(track.device)
        local samePortableRadio = previousRadioID
            and "item:" .. tostring(previousRadioID) == deviceIdentity
        local sameDeviceData = track.deviceData == deviceData

        if track.channel == channel and not currentDevices[activeKey]
            and (sameDeviceData or samePortableRadio) then
            if matchingKey then
                return key
            end
            matchingKey = activeKey
        end
    end

    return matchingKey or key
end

local function stopTrack(key)
    local track = activeTracks[key]
    if track then
        track.emitter:stopSound(track.soundHandle)
        activeTracks[key] = nil
    end
end

local function isInventoryDevice(deviceData)
    return deviceData.isInventoryDevice and deviceData:isInventoryDevice()
end

local function devicePosition(device, player, inventoryDevice)
    local deviceData = device:getDeviceData()
    if inventoryDevice == true
        or inventoryDevice == nil and isInventoryDevice(deviceData) then
        return player:getX(), player:getY(), player:getZ()
    end

    if instanceof(device, "VehiclePart") then
        local vehicle = device:getVehicle()
        if vehicle then
            return vehicle:getX(), vehicle:getY(), vehicle:getZ()
        end
    end

    if not device.getSquare or not device:getSquare() then
        return player:getX(), player:getY(), player:getZ()
    end

    local x = device:getX()
    local y = device:getY()
    local z = device:getZ()
    if type(x) ~= "number" then
        x = player:getX()
    end
    if type(y) ~= "number" then
        y = player:getY()
    end
    if type(z) ~= "number" then
        z = player:getZ()
    end
    return x, y, z
end

local function updateTrackEmitter(track, player)
    local x, y, z = devicePosition(track.device, player, track.inventoryDevice)
    if track.emitterX ~= x or track.emitterY ~= y or track.emitterZ ~= z then
        track.emitter:setPos(x, y, z)
        track.emitterX = x
        track.emitterY = y
        track.emitterZ = z
    end

    local is3D = not track.inventoryDevice
    if track.emitterIs3D ~= is3D then
        if not setEmitter3D(track.emitter, track.soundHandle, is3D, track.soundName) then
            return false
        end
        track.emitterIs3D = is3D
    end
    return true
end

local function updateZombieAttraction(player, key, device, deviceData, inventoryDevice)
    if zombieAttractionDisabled() then
        worldSoundCounters[key] = nil
        return
    end

    local deviceVolume = deviceData:getDeviceVolume()
    if type(deviceVolume) ~= "number" or deviceVolume <= 0 then
        worldSoundCounters[key] = nil
        return
    end

    if inventoryDevice and deviceData:getHeadphoneType() >= 0 then
        worldSoundCounters[key] = nil
        return
    end

    if not deviceData.getDeviceSoundVolumeRange then
        if not deviceSoundRangeWarningReported then
            print("[TheRoadSoFarFM] Device sound range API is unavailable; zombie attraction sound was not emitted.")
            deviceSoundRangeWarningReported = true
        end
        return
    end

    local range = deviceData:getDeviceSoundVolumeRange()
    local volume = math.floor(100 * deviceVolume)
    if type(range) ~= "number" or range <= 0 or volume <= 0 then
        return
    end

    local counter = worldSoundCounters[key]
    if counter then
        counter = counter - 1.25 * getGameTime():getMultiplier()
        if counter > 0 then
            worldSoundCounters[key] = counter
            return
        end
    end

    local x, y, z = devicePosition(device, player, inventoryDevice)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    if isClient() and not inventoryDevice then
        sendClientCommand(player, MODULE, "radioNoise", {
            key = key,
            frequency = deviceData:getChannel(),
            x = x,
            y = y,
            z = z,
            radius = range,
            volume = volume,
        })
    else
        local worldSoundManager = getWorldSoundManager and getWorldSoundManager()
        if not worldSoundManager or not worldSoundManager.addSoundRepeating then
            if not worldSoundApiWarningReported then
                print("[TheRoadSoFarFM] Repeating world sound API is unavailable; zombie attraction sound was not emitted.")
                worldSoundApiWarningReported = true
            end
            return
        end

        local source = inventoryDevice and player or device
        if instanceof(device, "VehiclePart") then
            source = device:getVehicle()
        end
        local startedAt = getTimestampMs()
        worldSoundManager:addSoundRepeating(source, x, y, z, range, volume, volume > 50)
        logSlowAudioOperation("addSoundRepeating", "radio noise", startedAt)
    end

    local randomDelay = ZombRand and ZombRand(300) or math.random(0, 299)
    worldSoundCounters[key] = 300 + randomDelay
end

local function updateTrackVolume(track, player)
    if not updateTrackEmitter(track, player) then
        return
    end

    local deviceX, deviceY, deviceZ = devicePosition(track.device, player, track.inventoryDevice)
    local dx = player:getX() - deviceX
    local dy = player:getY() - deviceY
    local dz = (player:getZ() - deviceZ) * 3
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    local deviceVolume = track.deviceData:getDeviceVolume()
    local volume
    if track.inventoryDevice then
        volume = deviceVolume * RADIO_GAIN_MULTIPLIER
    else
        local range = track.deviceData:getBaseVolumeRange() * deviceVolume * RADIO_RANGE_MULTIPLIER
        volume = 0
        if range > 0 then
            volume = deviceVolume * math.max(0, 1 - distance / range) * RADIO_GAIN_MULTIPLIER
        end
    end

    if track.volume ~= volume then
        local startedAt = getTimestampMs()
        track.emitter:setVolume(track.soundHandle, volume)
        logSlowAudioOperation("setVolume update", track.soundName, startedAt)
        track.volume = volume
    end
end

local function logInventoryRadioAudioPath(track)
    if not track.inventoryDevice or track.inventoryAudioPathLogged then
        return
    end

    track.inventoryAudioPathLogged = true
    print("[TheRoadSoFarFM] Using inventory radio audio path for "
        .. track.soundName .. " at device volume "
        .. tostring(track.deviceData:getDeviceVolume()) .. ".")
end

local function startTrack(key, device, deviceData, player, playback, inventoryDevice)
    local existing = activeTracks[key]
    if existing then
        if existing.version == playback.version and existing.soundName == playback.soundName then
            existing.device = device
            existing.deviceData = deviceData
            existing.inventoryDevice = inventoryDevice
            existing.missingSince = nil
            if existing.unavailable then
                if not existing.emitter:isPlaying(existing.soundHandle) then
                    local startedAt = getTimestampMs()
                    local soundHandle = existing.emitter:playSound(existing.soundName)
                    logSlowAudioOperation("playSound resume", existing.soundName, startedAt)
                    if not soundHandle then
                        print("[TheRoadSoFarFM] Failed to resume sound " .. existing.soundName .. ".")
                        return nil
                    end
                    existing.soundHandle = soundHandle
                    existing.emitterIs3D = nil
                end
                existing.unavailable = false
                existing.volume = nil
            end
            logInventoryRadioAudioPath(existing)
            return existing
        end
        stopTrack(key)
    end

    local x, y, z = devicePosition(device, player, inventoryDevice)
    local emitter = getFreeEmitterAt(x, y, z, playback.soundName)
    if not emitter then
        return nil
    end

    local startedAt = getTimestampMs()
    local soundHandle = emitter:playSound(playback.soundName)
    logSlowAudioOperation("playSound start", playback.soundName, startedAt)
    if not soundHandle then
        print("[TheRoadSoFarFM] Failed to start sound " .. playback.soundName .. ".")
        return nil
    end
    local is3D = not inventoryDevice
    if not setEmitter3D(emitter, soundHandle, is3D, playback.soundName) then
        emitter:stopSound(soundHandle)
        return nil
    end
    if isClient() then
        print("[TheRoadSoFarFM][MP] Started local playback for "
            .. playback.soundName .. " on "
            .. string.format("%.1f MHz", deviceData:getChannel() / 1000)
            .. " (" .. (inventoryDevice and "inventory" or "world") .. ").")
    end

    local track = {
        device = device,
        deviceData = deviceData,
        inventoryDevice = inventoryDevice,
        channel = deviceData:getChannel(),
        deviceIdentity = radioKey(device),
        emitter = emitter,
        soundHandle = soundHandle,
        soundName = playback.soundName,
        title = playback.title,
        kind = playback.kind,
        version = playback.version,
        advanceRequested = false,
        volume = nil,
        emitterIs3D = is3D,
        emitterX = x,
        emitterY = y,
        emitterZ = z,
    }
    activeTracks[key] = track
    logInventoryRadioAudioPath(track)
    local announcement
    if playback.welcome then
        announcement = WELCOME_MESSAGE
    elseif playback.kind == "song" then
        local title = playback.title
        if not title then
            local playlistConfig = getPlaylistConfig(deviceData:getChannel()) or TheRoadSoFarFMConfig
            title = playlistConfig.TrackTitles and playlistConfig.TrackTitles[playback.soundName]
        end
        announcement = title
    end

    if announcement then
        local isUserTracksTrack = not playback.welcome
            and playback.kind == "song"
            and deviceData:getChannel() == USER_TRACKS_FREQUENCY
        if initialAnnouncementDisplayed then
            announceTrackTitle(announcement, device, deviceData, player, isUserTracksTrack)
        else
            pendingInitialAnnouncement = {
                title = announcement,
                player = player,
                device = device,
                deviceData = deviceData,
                ticksRemaining = INITIAL_ANNOUNCEMENT_DELAY,
                isUserTracksTrack = isUserTracksTrack,
            }
        end
    end
    return track
end

local function setApprovedPlayback(key, soundName, version, kind, title, welcome)
    approvedStarts[key] = {
        soundName = soundName,
        version = version,
        kind = kind,
        title = title,
        welcome = welcome == true,
    }
end

local function setApprovedStation(frequency, soundName, version, kind, title, welcome)
    approvedStations[frequency] = {
        soundName = soundName,
        version = version,
        kind = kind,
        title = title,
        welcome = welcome == true,
    }
end

local function onServerCommand(module, command, args)
    if module ~= MODULE or type(args) ~= "table" then
        return
    end

    if command == "play" and type(args.sound) == "string" and type(args.version) == "number" then
        if isClient() and type(args.frequency) == "number" then
            print("[TheRoadSoFarFM][MP] Received station state: "
                .. args.sound .. " on " .. tostring(args.frequency) .. ".")
            local current = approvedStations[args.frequency]
            pendingStarts[args.frequency] = nil
            pendingStops[args.frequency] = nil
            setApprovedStation(
                args.frequency,
                args.sound,
                args.version,
                args.kind,
                args.title,
                args.welcome
            )
            if not current or current.version ~= args.version then
                local keysToStop = {}
                for key, track in pairs(activeTracks) do
                    if track.channel == args.frequency then
                        keysToStop[#keysToStop + 1] = key
                    end
                end
                for _, key in ipairs(keysToStop) do
                    stopTrack(key)
                end
            end
        elseif type(args.key) == "string" then
            pendingStarts[args.key] = nil
            pendingStops[args.key] = nil
            setApprovedPlayback(
                args.key,
                args.sound,
                args.version,
                args.kind,
                args.title,
                args.welcome
            )
            stopTrack(args.key)
        end
    elseif command == "stop" and type(args.key) == "string" then
        pendingStarts[args.key] = nil
        pendingStops[args.key] = nil
        approvedStarts[args.key] = nil
        localPlaylists[args.key] = nil
        stopTrack(args.key)
    end
end

local function requestStart(player, key, device, deviceData, playlistConfig)
    if isClient() then
        local frequency = deviceData:getChannel()
        if frequency == USER_TRACKS_FREQUENCY or approvedStations[frequency] then
            return
        end
        local now = getTimestampMs()
        local lastRequestAt = pendingStarts[frequency]
        if not lastRequestAt or now - lastRequestAt >= STATION_START_RETRY_MS then
            pendingStarts[frequency] = now
            print("[TheRoadSoFarFM][MP] Requesting station state for "
                .. tostring(frequency) .. ".")
            sendClientCommand(player, MODULE, "requestStart", {
                frequency = frequency,
            })
        end
        return
    end

    if approvedStarts[key] then
        return
    else
        local state = localPlaylists[key]
        if not state then
            state = TheRoadSoFarFMPlaylist.createState(playlistConfig)
            localPlaylists[key] = state
        end
        local config = state.config or TheRoadSoFarFMConfig
        local title = config.TrackTitles and config.TrackTitles[state.sound]
        setApprovedPlayback(key, state.sound, state.version, state.kind, title, state.welcome)
    end
end

local function requestAdvance(key, track)
    if track.advanceRequested then
        return
    end
    track.advanceRequested = true

    if isClient() then
        sendClientCommand(getPlayer(), MODULE, "requestAdvance", {
            frequency = track.channel,
            version = track.version,
        })
        return
    end

    local state = localPlaylists[key]
    if state and state.version == track.version then
        TheRoadSoFarFMPlaylist.advance(state, state.config)
        local config = state.config or TheRoadSoFarFMConfig
        local title = config.TrackTitles and config.TrackTitles[state.sound]
        setApprovedPlayback(key, state.sound, state.version, state.kind, title, state.welcome)
        stopTrack(key)
    end
end

function TheRoadSoFarFMTestAudio.skip()
    local keys = {}
    for key in pairs(activeTracks) do
        keys[#keys + 1] = key
    end

    if #keys == 0 then
        print("[TheRoadSoFarFM] No active station track to skip.")
        return
    end

    for _, key in ipairs(keys) do
        local track = activeTracks[key]
        if track then
            requestAdvance(key, track)
        end
    end

    print("[TheRoadSoFarFM] Debug skip requested for " .. #keys .. " active station(s).")
end

function TheRoadSoFarFMTestAudio.forceCommercial()
    local keys = {}
    for key in pairs(activeTracks) do
        keys[#keys + 1] = key
    end

    if #keys == 0 then
        print("[TheRoadSoFarFM] No active station track for the debug commercial.")
        return
    end

    for _, key in ipairs(keys) do
        local track = activeTracks[key]
        if track then
            track.advanceRequested = true
            if isClient() then
                sendClientCommand(getPlayer(), MODULE, "debugCommercial", {
                    frequency = track.channel,
                    version = track.version,
                })
            else
                local state = localPlaylists[key]
                if state and state.version == track.version then
                    TheRoadSoFarFMPlaylist.forceCommercial(state, state.config)
                    setApprovedPlayback(key, state.sound, state.version, state.kind, nil, false)
                    stopTrack(key)
                end
            end
        end
    end

    print("[TheRoadSoFarFM] Debug commercial requested for " .. #keys .. " active station(s).")
end

local function requestStop(key, player)
    if isClient() then
        pendingStops[key] = nil
        stopTrack(key)
        return
    end

    approvedStarts[key] = nil
    pendingStarts[key] = nil
    localPlaylists[key] = nil
    stopTrack(key)
end

local function stopLocalTracksForDevice(device, deviceData)
    if not device or not deviceData then
        return
    end

    local identity = radioKey(device)
    local portableId = portableRadioID(device)
    local channel = deviceData:getChannel()
    local keysToStop = {}
    for key, track in pairs(activeTracks) do
        local sameDeviceData = track.deviceData == deviceData
        local sameIdentity = identity and track.deviceIdentity == identity
        local trackPortableId = track.device and portableRadioID(track.device)
        local samePortableId = portableId and trackPortableId == portableId
        if track.channel == channel and (sameDeviceData or sameIdentity or samePortableId) then
            keysToStop[#keysToStop + 1] = key
        end
    end

    for _, key in ipairs(keysToStop) do
        local track = activeTracks[key]
        if track then
            print("[TheRoadSoFarFM][MP] Stopping local emitter after radio shutdown: "
                .. track.soundName .. " (" .. key .. ").")
            stopTrack(key)
            worldSoundCounters[key] = nil
        end
    end
end

local function stopRadioTracksAfterDeath(player)
    local localPlayer = getPlayer()
    if localPlayer and player ~= localPlayer then
        return
    end

    local keysToStop = {}
    for key, track in pairs(activeTracks) do
        keysToStop[#keysToStop + 1] = key
    end

    for _, key in ipairs(keysToStop) do
        local track = activeTracks[key]
        if track and track.inventoryDevice then
            if isClient() then
                pendingStarts[track.channel] = nil
                stopTrack(key)
            else
                requestStop(key, player)
            end
            print("[TheRoadSoFarFM] Stopped inventory radio track after player death: "
                .. track.soundName .. ".")
        elseif track then
            stopTrack(key)
            if isClient() then
                pendingStarts[track.channel] = nil
            else
                pendingStarts[key] = nil
            end
            print("[TheRoadSoFarFM] Stopped local radio playback after player death: "
                .. track.soundName .. ".")
        end
        worldSoundCounters[key] = nil
    end

    pendingInitialAnnouncement = nil
end

require "RadioCom/ISRadioAction"

if not ISRadioAction.TheRoadSoFarFMRadioShutdownHooked then
    local originalToggleOnOff = ISRadioAction.performToggleOnOff
    ISRadioAction.performToggleOnOff = function(action)
        originalToggleOnOff(action)
        local deviceData = action.deviceData
        if isClient() and deviceData and not deviceData:getIsTurnedOn() then
            stopLocalTracksForDevice(action.device, deviceData)
        end
    end
    ISRadioAction.TheRoadSoFarFMRadioShutdownHooked = true
end

local function stopOtherChannelTracks(deviceData, device, deviceIdentity, channel)
    local currentRadioID = portableRadioID(device)
    local keysToStop = {}
    for key, track in pairs(activeTracks) do
        local previousRadioID = track.device and portableRadioID(track.device)
        local samePortableRadio = currentRadioID and previousRadioID == currentRadioID
        local sameDeviceData = track.deviceData == deviceData
        local sameIdentity = track.deviceIdentity == deviceIdentity
        if track.channel ~= channel and (sameDeviceData or samePortableRadio or sameIdentity) then
            keysToStop[#keysToStop + 1] = key
        end
    end

    for _, key in ipairs(keysToStop) do
        requestStop(key)
    end
end

local function updateRadioTracks(player)
    if player ~= getPlayer() then
        return
    end

    if player:isDead() then
        stopRadioTracksAfterDeath(player)
        return
    end

    if pendingInitialAnnouncement and pendingInitialAnnouncement.player == player then
        pendingInitialAnnouncement.ticksRemaining = pendingInitialAnnouncement.ticksRemaining - 1
        if pendingInitialAnnouncement.ticksRemaining <= 0 then
            local announcement = pendingInitialAnnouncement
            pendingInitialAnnouncement = nil
            announceTrackTitle(
                announcement.title,
                announcement.device,
                announcement.deviceData,
                player,
                announcement.isUserTracksTrack
            )
            initialAnnouncementDisplayed = true
            print("[TheRoadSoFarFM] Issued initial radio announcement: " .. announcement.title)
        end
    end

    local radio = getZomboidRadio()
    if not radio then
        return
    end

    local currentDevices = {}
    local processedDevices = {}
    local inventoryDevices = {}
    local inventoryRadioIds = {}
    local function markInventoryDevice(device)
        if not device then
            return
        end

        inventoryDevices[device] = true
        if instanceof(device, "Radio") then
            local radioId = portableRadioID(device)
            if radioId then
                inventoryRadioIds[tostring(radioId)] = true
            end
        end
        if device.getDeviceData then
            local deviceData = device:getDeviceData()
            if deviceData then
                inventoryDevices[deviceData] = true
            end
        end
    end
    local function markInventoryDevices(container)
        if not container then
            return
        end

        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if instanceof(item, "Radio") then
                markInventoryDevice(item)
            elseif item.getInventory then
                markInventoryDevices(item:getInventory())
            end
        end
    end
    markInventoryDevices(player:getInventory())
    markInventoryDevice(player:getPrimaryHandItem())
    markInventoryDevice(player:getSecondaryHandItem())
    markInventoryDevice(player:getClothingItem_Back())

    local function processDevice(device)
        if not device or not device.getDeviceData or processedDevices[device] then
            return
        end
        processedDevices[device] = true

        local deviceData = device:getDeviceData()
        if deviceData then
            local deviceIdentity = radioKey(device)
            if deviceIdentity then
                local channel = deviceData:getChannel()
                stopOtherChannelTracks(deviceData, device, deviceIdentity, channel)
                local key = playbackKey(deviceData, deviceIdentity, channel, currentDevices)
                local radioId = portableRadioID(device)
                local inPlayerInventory = inventoryDevices[device]
                    or inventoryDevices[deviceData]
                    or (radioId and inventoryRadioIds[tostring(radioId)])
                local inventoryDevice
                if isClient() then
                    inventoryDevice = inPlayerInventory == true
                else
                    inventoryDevice = isInventoryDevice(deviceData) == true
                end
                local isPlayingStation = deviceData:getIsTurnedOn()
                    and (channel == ROAD_SO_FAR_FREQUENCY or channel == USER_TRACKS_FREQUENCY)
                local playlistConfig = getPlaylistConfig(channel)
                if channel == USER_TRACKS_FREQUENCY and not playlistConfig then
                    isPlayingStation = false
                end
                if isPlayingStation then
                    currentDevices[key] = true
                    requestStart(player, key, device, deviceData, playlistConfig)
                    updateZombieAttraction(player, key, device, deviceData, inventoryDevice)
                    local playback
                    if isClient() then
                        playback = approvedStations[channel]
                    else
                        playback = approvedStarts[key]
                    end
                    if playback then
                        local track = startTrack(
                            key,
                            device,
                            deviceData,
                            player,
                            playback,
                            inventoryDevice
                        )
                        if track then
                            updateTrackVolume(track, player)
                            if not track.emitter:isPlaying(track.soundHandle) then
                                requestAdvance(key, track)
                            end
                        end
                    end
                elseif inventoryDevice
                    and (activeTracks[key] or approvedStarts[key]
                        or (isClient() and approvedStations[channel]))
                    and (not isClient() or deviceData:getIsTurnedOn()) then
                    local track = activeTracks[key]
                    if track then
                        track.unavailable = true
                    end
                elseif activeTracks[key] or approvedStarts[key] then
                    requestStop(key)
                end
            end
        end
    end

    local function processInventory(container)
        if not container then
            return
        end

        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if instanceof(item, "Radio") then
                processDevice(item)
            elseif item.getInventory then
                processInventory(item:getInventory())
            end
        end
    end

    processInventory(player:getInventory())
    processDevice(player:getPrimaryHandItem())
    processDevice(player:getSecondaryHandItem())
    processDevice(player:getClothingItem_Back())

    local devices = radio:getDevices()
    for i = 0, devices:size() - 1 do
        processDevice(devices:get(i))
    end

    for key in pairs(worldSoundCounters) do
        if not currentDevices[key] then
            worldSoundCounters[key] = nil
        end
    end

    local unavailableTracks = {}
    local now = getTimestampMs()
    for key, track in pairs(activeTracks) do
        if not currentDevices[key] then
            if isClient() then
                track.missingSince = track.missingSince or now
                if now - track.missingSince >= RADIO_DEVICE_HANDOFF_WINDOW_MS then
                    unavailableTracks[#unavailableTracks + 1] = key
                end
            else
                track.unavailable = true
            end
        end
    end
    for _, key in ipairs(unavailableTracks) do
        stopTrack(key)
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnPlayerUpdate.Add(updateRadioTracks)
Events.OnPlayerDeath.Add(stopRadioTracksAfterDeath)
Events.OnPreMapLoad.Add(warmAllSoundClipsBeforeMapLoad)
