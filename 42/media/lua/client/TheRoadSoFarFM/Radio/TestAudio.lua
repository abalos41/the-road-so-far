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
local TRACK_HOP_VOLUME_MARGIN = 0.05
local TRACK_HOP_COOLDOWN_MS = 1000
-- Waiting sounds are not started when less than this is left before the sync cue.
local WAITING_MIN_FILLER_MS = 2500
local stationClocks = {}
local joinDecisions = {}
local lastHeartbeatAt = {}
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
    if isMultiplayerClient and TheRoadSoFarFMSync then
        for _, soundName in ipairs(TheRoadSoFarFMSync.allSoundNames()) do
            if queueSound(soundName) then
                radioCount = radioCount + 1
            end
        end
    end
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

-- Plays a sound on a free world emitter for this client only. In multiplayer the plain
-- playSound() would also send it to every other nearby client (PlayWorldSound), where it
-- could neither be stopped nor follow the device volume; playSoundImpl() is the local one
-- the base game's own radios use. The (name, nil) form is ambiguous between the IsoObject and
-- IsoGridSquare overloads and throws a NullPointerException, so the 3-argument one is used.
local function playLocalSound(emitter, soundName)
    if isClient() then
        if emitter.playSoundImpl then
            local handle = emitter:playSoundImpl(soundName, false, nil)
            if handle and handle ~= 0 then
                return handle
            end
        end
        return nil
    end
    return emitter:playSound(soundName)
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
    testSound = playLocalSound(testEmitter, playlistConfig.Tracks[1])
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
        if track.cueHandle then
            (track.cueEmitter or track.emitter):stopSound(track.cueHandle)
        end
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
        -- The server works out volume and range itself; it only needs to know which device.
        local target = TheRoadSoFarFMNoise.target(device)
        if not target then
            return
        end
        target.kind = "radio"
        sendClientCommand(player, MODULE, "deviceNoise", target)
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

local function computeTrackVolume(deviceData, device, player, inventoryDevice)
    local deviceVolume = deviceData:getDeviceVolume()
    local gain = RADIO_GAIN_MULTIPLIER * TheRoadSoFarFMVolume.scale()
    if inventoryDevice then
        return deviceVolume * gain
    end

    local deviceX, deviceY, deviceZ = devicePosition(device, player, inventoryDevice)
    local dx = player:getX() - deviceX
    local dy = player:getY() - deviceY
    local dz = (player:getZ() - deviceZ) * 3
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    local range = deviceData:getBaseVolumeRange() * deviceVolume * RADIO_RANGE_MULTIPLIER
    if range > 0 then
        return deviceVolume * math.max(0, 1 - distance / range) * gain
    end
    return 0
end

-- Milliseconds until the server advances the station, or nil when the clock is unknown.
local function stationRemainingMs(channel, version)
    local clock = stationClocks[channel]
    if not clock or clock.version ~= version or not clock.durationMs then
        return nil
    end
    return clock.startedLocalMs + clock.durationMs + TheRoadSoFarFMSync.AdvanceMarginMs
        - getTimestampMs()
end

-- Next waiting sound of the given kind ("tuning" or "edit"). Every sound of a kind plays
-- once before any repeats, and sounds that finish before the sync cue are preferred.
local waitingBags
local function takeWaitingSound(kind, remaining)
    local sync = TheRoadSoFarFMSync
    if not waitingBags then
        waitingBags = {
            tuning = sync.newBag(sync.Sounds.radio.tunings),
            edit = sync.newBag(sync.Sounds.radio.edits),
        }
    end

    local available
    if remaining then
        local _, cueMs = sync.radioCue()
        if cueMs then
            available = remaining - (cueMs + sync.CueEarlyMs)
        end
    end
    return sync.bagTake(waitingBags[kind], available)
end

local function otherWaitingKind(kind)
    return kind == "tuning" and "edit" or "tuning"
end

local function startWaitingCue(track, cueSound, now)
    -- Its own emitter: the one of the filler may already be back in the engine's pool.
    local x, y, z = devicePosition(track.device, getPlayer(), track.inventoryDevice)
    local emitter = getFreeEmitterAt(x, y, z, cueSound)
    local handle = emitter and playLocalSound(emitter, cueSound)
    if not handle then
        track.cueSkipped = true
        return
    end
    if not setEmitter3D(emitter, handle, not track.inventoryDevice, cueSound) then
        emitter:stopSound(handle)
        track.cueSkipped = true
        return
    end
    track.cueEmitter = emitter
    track.cueHandle = handle
    track.cueStartedAt = now
    track.cueX, track.cueY, track.cueZ = x, y, z
    print("[TheRoadSoFarFM][MP][Sync] Sync cue " .. cueSound .. " started on "
        .. tostring(track.channel) .. ".")
end

-- A free emitter only stays active while it has sounds: when the last one ends the engine
-- takes it back and stops processing it. Every waiting sound therefore gets a fresh emitter.
local function startNextWaitingSound(track, remaining, now)
    local kind = track.nextWaitingKind or "tuning"
    local soundName = takeWaitingSound(kind, remaining)
    local x, y, z = devicePosition(track.device, getPlayer(), track.inventoryDevice)
    local emitter = soundName and getFreeEmitterAt(x, y, z, soundName)
    local handle = emitter and playLocalSound(emitter, soundName)
    if not handle then
        track.nextWaitingAt = now + 2000
        return
    end
    local is3D = not track.inventoryDevice
    if not setEmitter3D(emitter, handle, is3D, soundName) then
        emitter:stopSound(handle)
        track.nextWaitingAt = now + 2000
        return
    end
    track.emitter = emitter
    track.emitterX, track.emitterY, track.emitterZ = x, y, z
    track.emitterIs3D = is3D
    track.soundHandle = handle
    track.fillerSound = soundName
    track.nextWaitingKind = otherWaitingKind(kind)
    track.fillerVolume = nil
    track.fillerStopped = false
    print("[TheRoadSoFarFM][MP][Sync] Waiting sound " .. soundName .. " (" .. kind .. ") on "
        .. tostring(track.channel) .. ", remaining="
        .. tostring(remaining and math.floor(remaining) or "?") .. " ms.")
end

-- Late joiners hear tuning sounds and edits alternately; the shortest tuning sound is the
-- sync cue, timed to end exactly as the next track begins.
local function updateWaitingAudio(track, volume)
    local sync = TheRoadSoFarFMSync
    local now = getTimestampMs()
    local remaining = stationRemainingMs(track.channel, track.version)

    if not track.cueHandle and not track.cueSkipped and remaining then
        local cueSound, cueMs = sync.radioCue()
        if cueSound and remaining <= cueMs + sync.CueEarlyMs then
            if remaining >= sync.CueMinRemainingMs then
                startWaitingCue(track, cueSound, now)
            else
                track.cueSkipped = true
            end
        end
    end

    -- A filler that the sync cue would cut within moments is not started at all.
    local fillerFits = true
    if remaining and not track.cueStartedAt then
        local _, cueMs = sync.radioCue()
        if cueMs and remaining - (cueMs + sync.CueEarlyMs) < WAITING_MIN_FILLER_MS then
            fillerFits = false
        end
    end

    if not track.cueStartedAt and not track.cueSkipped and fillerFits
        and not track.emitter:isPlaying(track.soundHandle)
        and (not track.nextWaitingAt or now >= track.nextWaitingAt) then
        startNextWaitingSound(track, remaining, now)
    end

    local fillerFactor = 1
    if track.cueStartedAt then
        fillerFactor = math.max(0, 1 - (now - track.cueStartedAt) / sync.FillerFadeMs)
    end
    local fillerVolume = volume * sync.FillerGain * fillerFactor
    if track.fillerVolume ~= fillerVolume then
        if fillerFactor <= 0 then
            if not track.fillerStopped then
                track.emitter:stopSound(track.soundHandle)
                track.fillerStopped = true
            end
        else
            track.emitter:setVolume(track.soundHandle, fillerVolume)
        end
        track.fillerVolume = fillerVolume
    end
    if track.cueHandle then
        local cueEmitter = track.cueEmitter or track.emitter
        local x, y, z = devicePosition(track.device, getPlayer(), track.inventoryDevice)
        if track.cueX ~= x or track.cueY ~= y or track.cueZ ~= z then
            cueEmitter:setPos(x, y, z)
            track.cueX, track.cueY, track.cueZ = x, y, z
        end
        if track.cueVolume ~= volume then
            cueEmitter:setVolume(track.cueHandle, volume * sync.CueGain)
            track.cueVolume = volume
        end
    end
    track.volume = volume
end

local function updateTrackVolume(track, player)
    if not updateTrackEmitter(track, player) then
        return
    end

    local volume = computeTrackVolume(track.deviceData, track.device, player, track.inventoryDevice)
    if track.waiting then
        updateWaitingAudio(track, volume)
        return
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

local function startTrack(key, device, deviceData, player, playback, inventoryDevice, joinMode)
    local waiting = joinMode == "wait"
    local existing = activeTracks[key]
    if existing then
        if existing.version == playback.version and existing.soundName == playback.soundName then
            existing.device = device
            existing.deviceData = deviceData
            existing.inventoryDevice = inventoryDevice
            existing.missingSince = nil
            if existing.unavailable then
                -- A waiting track chains its own sounds, so only real tracks are resumed here.
                if not existing.waiting and not existing.emitter:isPlaying(existing.soundHandle) then
                    local startedAt = getTimestampMs()
                    local soundHandle = playLocalSound(existing.emitter, existing.soundName)
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
                existing.fillerVolume = nil
            end
            logInventoryRadioAudioPath(existing)
            return existing
        end
        stopTrack(key)
    end

    local x, y, z = devicePosition(device, player, inventoryDevice)
    local soundToPlay = playback.soundName
    if waiting then
        soundToPlay = takeWaitingSound("tuning", stationRemainingMs(deviceData:getChannel(), playback.version))
        if not soundToPlay then
            return nil
        end
    end
    local emitter = getFreeEmitterAt(x, y, z, soundToPlay)
    if not emitter then
        return nil
    end

    local startedAt = getTimestampMs()
    local soundHandle = playLocalSound(emitter, soundToPlay)
    logSlowAudioOperation("playSound start", soundToPlay, startedAt)
    if not soundHandle then
        print("[TheRoadSoFarFM] Failed to start sound " .. soundToPlay .. ".")
        return nil
    end
    local is3D = not inventoryDevice
    if not setEmitter3D(emitter, soundHandle, is3D, soundToPlay) then
        emitter:stopSound(soundHandle)
        return nil
    end
    if isClient() then
        print("[TheRoadSoFarFM][MP] Started local playback for "
            .. soundToPlay .. " on "
            .. string.format("%.1f MHz", deviceData:getChannel() / 1000)
            .. " (" .. (inventoryDevice and "inventory" or "world") .. ")"
            .. (joinMode and (", join=" .. joinMode) or "") .. ".")
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
        waiting = waiting,
        fillerSound = waiting and soundToPlay or nil,
        nextWaitingKind = waiting and "edit" or nil,
        joinMode = joinMode,
    }
    activeTracks[key] = track
    if isClient() and joinMode and joinMode ~= "start" then
        joinDecisions[track.channel] = { version = playback.version, mode = joinMode }
    end
    logInventoryRadioAudioPath(track)
    if waiting then
        return track
    end
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
            local sync = TheRoadSoFarFMSync
            if sync.isValidMs(args.elapsedMs) and sync.isValidMs(args.durationMs)
                and args.durationMs > 0 then
                stationClocks[args.frequency] = {
                    version = args.version,
                    startedLocalMs = getTimestampMs() - args.elapsedMs,
                    durationMs = args.durationMs,
                }
            else
                stationClocks[args.frequency] = nil
            end
            local decision = joinDecisions[args.frequency]
            if decision and decision.version ~= args.version then
                joinDecisions[args.frequency] = nil
            end
            if args.reply == true and (args.join == "offset" or args.join == "wait") then
                joinDecisions[args.frequency] = { version = args.version, mode = args.join }
            end
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

-- Multiplayer: how a new local track should join the station. Returns nil while the server
-- still has to decide (late joiner, no decision cached for the current track yet).
local function joinModeFor(frequency, station)
    local decision = joinDecisions[frequency]
    if decision and decision.version == station.version then
        return decision.mode
    end

    local clock = stationClocks[frequency]
    if not clock or clock.version ~= station.version then
        return "start"
    end
    if getTimestampMs() - clock.startedLocalMs <= TheRoadSoFarFMSync.StartThresholdMs then
        return "start"
    end
    return nil
end

-- Multiplayer: a muted track may only start when the current station track began moments
-- ago (known clock); starting later would leave it out of step with everyone else.
local function canStartSilently(frequency)
    local station = approvedStations[frequency]
    local clock = stationClocks[frequency]
    return station ~= nil and clock ~= nil and clock.version == station.version
        and getTimestampMs() - clock.startedLocalMs <= TheRoadSoFarFMSync.StartThresholdMs
end

-- Multiplayer: a client hears a station through a single source (one track), whatever the
-- number of radios tuned to it. The track follows the player to whichever radio sounds
-- louder, and when the radio that carries it is switched off the track passes to another
-- radio of the station instead of stopping and asking the server again.
local function channelTrackKey(channel)
    for key, track in pairs(activeTracks) do
        if track.channel == channel then
            return key
        end
    end
    return nil
end

-- True when the radio carrying the track can no longer play it: it was switched off, tuned
-- elsewhere or is not around any more. Any other radio of the station may then take it over.
local function trackOwnerInvalid(track)
    if track.ownerInvalid or track.missingSince then
        return true
    end
    local deviceData = track.deviceData
    return deviceData ~= nil
        and (not deviceData:getIsTurnedOn() or deviceData:getChannel() ~= track.channel)
end

local function canTakeOver(donorKey, newVolume)
    local track = activeTracks[donorKey]
    if trackOwnerInvalid(track) then
        return true
    end

    local now = getTimestampMs()
    if track.lastHopAt and now - track.lastHopAt < TRACK_HOP_COOLDOWN_MS then
        return false
    end
    return (track.volume or 0) + TRACK_HOP_VOLUME_MARGIN < newVolume
end

local function adoptTrack(donorKey, key, device, deviceData, inventoryDevice)
    local track = activeTracks[donorKey]
    activeTracks[donorKey] = nil
    activeTracks[key] = track
    track.device = device
    track.deviceData = deviceData
    track.inventoryDevice = inventoryDevice
    track.deviceIdentity = radioKey(device)
    track.missingSince = nil
    track.ownerInvalid = nil
    track.unavailable = false
    track.silentSince = nil
    track.lastHopAt = getTimestampMs()
    -- Force position, 3D mode and volumes to be re-applied for the new source.
    track.emitterX, track.emitterY, track.emitterZ = nil, nil, nil
    track.emitterIs3D = nil
    track.volume = nil
    track.fillerVolume = nil
    track.cueVolume = nil
    print("[TheRoadSoFarFM][MP][Sync] Station " .. tostring(track.channel)
        .. " playback moved to another radio (" .. tostring(donorKey) .. " -> " .. tostring(key) .. ").")
end

local function requestStart(player, key, device, deviceData, playlistConfig)
    if isClient() then
        local frequency = deviceData:getChannel()
        if frequency == USER_TRACKS_FREQUENCY then
            return
        end
        local station = approvedStations[frequency]
        if station and (activeTracks[key] or joinModeFor(frequency, station)) then
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
        -- Multiplayer: another radio of the station may still take the track over this
        -- same tick, so it is only flagged here and stopped at the end of the update.
        local track = activeTracks[key]
        if track then
            track.ownerInvalid = true
        end
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
            print("[TheRoadSoFarFM][MP] Radio shut down, releasing playback: "
                .. track.soundName .. " (" .. key .. ").")
            -- Flagged instead of stopped: the next update hands it to another radio of the
            -- station if there is one, or stops it.
            track.ownerInvalid = true
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
                    -- Multiplayer: an audible device asks the server how to join. A silent
                    -- one only starts (muted) if the current track began moments ago, so it
                    -- stays aligned with the server clock until the player gets close.
                    local mayStart = true
                    local silentStart = false
                    if isClient() and not activeTracks[key] then
                        local ownVolume = computeTrackVolume(deviceData, device, player, inventoryDevice)
                        local donorKey = channelTrackKey(channel)
                        if donorKey then
                            -- The station already plays through another radio: this one only
                            -- takes it over when that radio can no longer carry it or when
                            -- this one clearly sounds louder; otherwise it stays silent.
                            if canTakeOver(donorKey, ownVolume) then
                                adoptTrack(donorKey, key, device, deviceData, inventoryDevice)
                            else
                                mayStart = false
                            end
                        else
                            mayStart = ownVolume > 0
                            if not mayStart then
                                silentStart = canStartSilently(channel)
                                mayStart = silentStart
                            end
                        end
                    end
                    if mayStart and not silentStart then
                        requestStart(player, key, device, deviceData, playlistConfig)
                    end
                    updateZombieAttraction(player, key, device, deviceData, inventoryDevice)
                    local playback
                    if isClient() then
                        playback = approvedStations[channel]
                    else
                        playback = approvedStarts[key]
                    end
                    local joinMode
                    if playback and mayStart and isClient() and not activeTracks[key] then
                        joinMode = silentStart and "start" or joinModeFor(channel, playback)
                        if not joinMode then
                            playback = nil
                        end
                    end
                    if playback and mayStart then
                        local track = startTrack(
                            key,
                            device,
                            deviceData,
                            player,
                            playback,
                            inventoryDevice,
                            joinMode
                        )
                        if track then
                            updateTrackVolume(track, player)
                            -- Only a track that is out of step with the server clock is dropped
                            -- when out of range; aligned and waiting tracks keep running muted.
                            if isClient() and track.joinMode == "offset" and not track.inventoryDevice
                                and track.volume ~= nil and track.volume <= 0 then
                                local silentNow = getTimestampMs()
                                track.silentSince = track.silentSince or silentNow
                                if silentNow - track.silentSince >= TheRoadSoFarFMSync.SilentStopMs then
                                    print("[TheRoadSoFarFM][MP][Sync] Out of range, stopping unsynced local track on "
                                        .. tostring(channel) .. ".")
                                    stopTrack(key)
                                    track = nil
                                end
                            elseif track.silentSince then
                                track.silentSince = nil
                            end
                        end
                        if track and not track.waiting
                            and not track.emitter:isPlaying(track.soundHandle) then
                            requestAdvance(key, track)
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
        if isClient() and track.ownerInvalid then
            -- No other radio of the station took the track over during this update.
            print("[TheRoadSoFarFM][MP][Sync] No radio left to carry the station "
                .. tostring(track.channel) .. ", stopping " .. tostring(track.soundName)
                .. " (" .. tostring(key) .. ").")
            unavailableTracks[#unavailableTracks + 1] = key
        elseif not currentDevices[key] then
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

    if isClient() then
        local sync = TheRoadSoFarFMSync
        local activeFrequencies = {}
        local audibleFrequencies = {}
        for _, track in pairs(activeTracks) do
            activeFrequencies[track.channel] = true
            if track.volume ~= nil and track.volume > 0 then
                audibleFrequencies[track.channel] = true
            end
        end

        -- A join decision only applies to the current approach; forget it once nothing plays.
        for frequency in pairs(joinDecisions) do
            if not activeFrequencies[frequency] then
                joinDecisions[frequency] = nil
            end
        end

        for frequency in pairs(audibleFrequencies) do
            local last = lastHeartbeatAt[frequency]
            if not last or now - last >= sync.ListenerHeartbeatMs then
                lastHeartbeatAt[frequency] = now
                sendClientCommand(player, MODULE, "listenHeartbeat", {
                    kind = "radio",
                    id = frequency,
                })
            end
        end
        for frequency in pairs(lastHeartbeatAt) do
            if not audibleFrequencies[frequency] then
                lastHeartbeatAt[frequency] = nil
                sendClientCommand(player, MODULE, "listenStop", {
                    kind = "radio",
                    id = frequency,
                })
            end
        end
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnPlayerUpdate.Add(updateRadioTracks)
Events.OnPlayerDeath.Add(stopRadioTracksAfterDeath)
Events.OnPreMapLoad.Add(warmAllSoundClipsBeforeMapLoad)
