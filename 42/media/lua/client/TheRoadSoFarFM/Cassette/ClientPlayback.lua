local CASSETTE_MEDIA_ID = "TheRoadSoFarFM_DeansTop13ZeppTraxx"
local DEVICE_HANDOFF_WINDOW_MS = 5000
-- A late arrival skips the inserting sound when less than this is left of it.
local INSERT_MIN_REMAINING_MS = 1000
local MODULE = "TheRoadSoFarFM"
local activePlayers = {}
local approvedCassetteStates = {}
local pendingCassetteStarts = {}
local unstableIdentityWarnings = {}
local missingMediaStateSetterWarningReported = false
local deviceSoundRangeWarningReported = false
local worldSoundApiWarningReported = false
local freeEmitterWarningReported = false
local emitterPositionWarningReported = false
local emitter3DWarningReported = false
local lastHeartbeatAt = {}
local CASSETTE_REQUEST_RETRY_MS = 3000
local CASSETTE_RANGE_MULTIPLIER = 3.5

local function getFreeEmitterAt(x, y, z, soundDescription)
    local world = getWorld and getWorld()
    if not world or not world.getFreeEmitter then
        if not freeEmitterWarningReported then
            print("[TheRoadSoFarFM] Cannot play " .. soundDescription .. ": world free-emitter API is unavailable.")
            freeEmitterWarningReported = true
        end
        return nil
    end

    local emitter = world:getFreeEmitter(x, y, z)
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

    emitter:setPos(x, y, z)
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

    emitter:set3D(soundHandle, is3D)
    return true
end

local function zombieAttractionDisabled()
    return SandboxVars and SandboxVars.TheRoadSoFarFM
        and SandboxVars.TheRoadSoFarFM.DisableZombieAttraction == true
end

local function isInventoryDevice(deviceData)
    return deviceData.isInventoryDevice and deviceData:isInventoryDevice()
end

local function cassetteNetworkId(device)
    if not isClient() or not device then
        return nil
    end
    return TheRoadSoFarFMCassette.deviceId(device)
end

local function requestCassetteState(player, networkId, audible)
    if not networkId then
        return
    end
    local now = getTimestampMs()
    local lastRequestAt = pendingCassetteStarts[networkId]
    if lastRequestAt and now - lastRequestAt < CASSETTE_REQUEST_RETRY_MS then
        return
    end
    pendingCassetteStarts[networkId] = now
    sendClientCommand(player, MODULE, "cassetteRequestState", {
        deviceId = networkId,
        audible = audible == true,
    })
end

local function requestCassetteAdvance(state)
    if state.waitingForServer or not state.cassetteServerId then
        return
    end
    state.waitingForServer = true
    sendClientCommand(state.player, MODULE, "cassetteAdvance", {
        deviceId = state.cassetteServerId,
        trackIndex = state.trackIndex,
        version = state.cassetteServerVersion,
    })
end

local function cassetteSoundSource(deviceData, state)
    if isInventoryDevice(deviceData) then
        return state.player
    end

    if instanceof(state.device, "VehiclePart") then
        local vehicle = state.device:getVehicle()
        if vehicle then
            return vehicle
        end
    elseif instanceof(state.device, "IsoObject") then
        return state.device
    end

    return state.player
end

local function playCassetteSound(deviceData, state, soundName)
    local emitter = state.emitter
    if emitter.playSoundImpl then
        local handle = emitter:playSoundImpl(soundName, cassetteSoundSource(deviceData, state))
        if handle and handle ~= 0 then
            return handle
        end
    end

    -- Plain playSound() would send the sound to every other nearby client in multiplayer.
    if emitter.playSound and not isClient() then
        local handle = emitter:playSound(soundName)
        if handle and handle ~= 0 then
            return handle
        end
    end

    return nil
end

local function devicePosition(device, deviceData, player)
    if isInventoryDevice(deviceData) then
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

    local x, y, z = device:getX(), device:getY(), device:getZ()
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

-- Multiplayer: whether the local player is close enough to hear the device at all.
local function cassetteAudible(device, deviceData, player)
    if isInventoryDevice(deviceData) then
        return true
    end

    local range = deviceData:getBaseVolumeRange()
        * deviceData:getDeviceVolume() * CASSETTE_RANGE_MULTIPLIER
    if range <= 0 then
        return false
    end

    local x, y, z = devicePosition(device, deviceData, player)
    local dx, dy = player:getX() - x, player:getY() - y
    local dz = (player:getZ() - z) * 3
    return math.sqrt(dx * dx + dy * dy + dz * dz) < range
end

-- Multiplayer: how a new local playback should join the shared cassette. Returns nil while
-- the server still has to decide (the track is already well under way).
local function cassetteJoinMode(sharedState)
    if sharedState.decision then
        return sharedState.decision.mode
    end
    if not sharedState.durationMs or not sharedState.startedLocalMs then
        return "start"
    end
    if getTimestampMs() - sharedState.startedLocalMs <= TheRoadSoFarFMSync.StartThresholdMs then
        return "start"
    end
    return nil
end

-- A muted playback may only start when the current track began moments ago (known clock).
local function cassetteCanStartSilently(sharedState)
    return sharedState.durationMs ~= nil and sharedState.startedLocalMs ~= nil
        and getTimestampMs() - sharedState.startedLocalMs <= TheRoadSoFarFMSync.StartThresholdMs
end

local function updateEmitterSpatialization(deviceData, state)
    local x, y, z = devicePosition(state.device, deviceData, state.player)
    if state.emitterX ~= x or state.emitterY ~= y or state.emitterZ ~= z then
        state.emitter:setPos(x, y, z)
        state.emitterX = x
        state.emitterY = y
        state.emitterZ = z
    end

    local is3D = not isInventoryDevice(deviceData)
    if state.emitterIs3D ~= is3D then
        if not setEmitter3D(state.emitter, state.handle, is3D, "cassette audio") then
            return false
        end
        state.emitterIs3D = is3D
    end
    return true
end

local function updateZombieAttraction(player, state, device, deviceData)
    if zombieAttractionDisabled() then
        state.worldSoundCounter = nil
        return
    end

    local deviceVolume = deviceData:getDeviceVolume()
    if type(deviceVolume) ~= "number" or deviceVolume <= 0 then
        state.worldSoundCounter = nil
        return
    end

    local inventoryDevice = isInventoryDevice(deviceData)
    if inventoryDevice and deviceData:getHeadphoneType() >= 0 then
        state.worldSoundCounter = nil
        return
    end

    if not deviceData.getDeviceSoundVolumeRange then
        if not deviceSoundRangeWarningReported then
            print("[TheRoadSoFarFM] Device sound range API is unavailable; cassette noise was not emitted.")
            deviceSoundRangeWarningReported = true
        end
        return
    end

    local range = deviceData:getDeviceSoundVolumeRange()
    local volume = math.floor(100 * deviceVolume)
    if type(range) ~= "number" or range <= 0 or volume <= 0 then
        return
    end

    local counter = state.worldSoundCounter
    if counter then
        counter = counter - 1.25 * getGameTime():getMultiplier()
        if counter > 0 then
            state.worldSoundCounter = counter
            return
        end
    end

    local x, y, z = devicePosition(device, deviceData, player)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    if isClient() and not inventoryDevice then
        -- The server works out volume and range itself; it only needs to know which device.
        local target = TheRoadSoFarFMNoise.target(device)
        if not target or not state.cassetteServerId then
            return
        end
        target.kind = "cassette"
        target.deviceId = state.cassetteServerId
        sendClientCommand(player, MODULE, "deviceNoise", target)
    else
        local worldSoundManager = getWorldSoundManager and getWorldSoundManager()
        if not worldSoundManager or not worldSoundManager.addSoundRepeating then
            if not worldSoundApiWarningReported then
                print("[TheRoadSoFarFM] Repeating world sound API is unavailable; cassette noise was not emitted.")
                worldSoundApiWarningReported = true
            end
            return
        end

        local source = inventoryDevice and player or device
        if instanceof(device, "VehiclePart") then
            source = device:getVehicle()
        end
        worldSoundManager:addSoundRepeating(source, x, y, z, range, volume, volume > 50)
    end

    local randomDelay = ZombRand and ZombRand(300) or math.random(0, 299)
    state.worldSoundCounter = 300 + randomDelay
end

local function stopPlayback(deviceData, state)
    if state.emitter then
        if state.handle then
            state.emitter:stopSound(state.handle)
        end
        if state.cueHandle then
            state.emitter:stopSound(state.cueHandle)
        end
    end
    if state.cassetteServerId then
        local sharedState = approvedCassetteStates[state.cassetteServerId]
        if sharedState then
            sharedState.decision = nil
        end
    end
    activePlayers[deviceData] = nil
end

local function stopCassettePlayback(deviceData)
    local state = activePlayers[deviceData]
    if not state then
        return false
    end

    stopPlayback(deviceData, state)
    if deviceData:isPlayingMedia() then
        deviceData:StopPlayMedia()
    end
    if deviceData.setIsPlayingMedia then
        deviceData:setIsPlayingMedia(false)
    end
    return true
end

local function restoreMediaPlayingState(deviceData)
    if not deviceData.setIsPlayingMedia then
        if not missingMediaStateSetterWarningReported then
            print("[TheRoadSoFarFM] Cannot sync cassette controls: radio media-state API is unavailable.")
            missingMediaStateSetterWarningReported = true
        end
        return false
    end

    deviceData:setIsPlayingMedia(true)
    return deviceData:isPlayingMedia()
end

local function announceTrackTitle(track, deviceData, state)
    local title = track.File:gsub("%.ogg$", "")
    local device = state.device
    local player = state.player

    if instanceof(device, "Radio") then
        if not player or not player.SayRadio then
            print("[TheRoadSoFarFM] Cannot display cassette track title: radio text API is unavailable.")
            return
        end
        player:SayRadio(
            title,
            1,
            1,
            0,
            UIFont.Medium,
            deviceData:getDeviceVolumeRange(),
            deviceData:getChannel(),
            "radio"
        )
        return
    end

    if not device or not device.AddDeviceText then
        print("[TheRoadSoFarFM] Cannot display cassette track title: radio device text API is unavailable.")
        return
    end

    local codes = ""
    if instanceof(device, "VehiclePart") then
        device:AddDeviceText(title, 1, 1, 0, nil, codes, -1)
    else
        device:AddDeviceText(player, title, 1, 1, 0, nil, codes, -1)
    end
end

local function startCurrentSound(deviceData, state)
    local soundName
    local soundDescription
    if state.stage == "inserting" then
        soundName = TheRoadSoFarFMCassette.InsertingSound
        soundDescription = "the inserting sound"
    else
        local track = TheRoadSoFarFMCassette.Tracks[state.trackIndex]
        if not track then
            state.complete = true
            return true
        end
        soundName = track.Sound
        soundDescription = "track " .. track.File
    end

    local x, y, z = devicePosition(state.device, deviceData, state.player)
    local emitter = getFreeEmitterAt(x, y, z, soundDescription)
    if not emitter then
        state.failed = true
        return false
    end
    state.emitter = emitter
    state.emitterX = x
    state.emitterY = y
    state.emitterZ = z
    state.emitterIs3D = nil

    state.handle = playCassetteSound(deviceData, state, soundName)
    if not state.handle then
        print("[TheRoadSoFarFM] Cassette playback failed to start " .. soundDescription .. ".")
        state.failed = true
        return false
    end
    if not updateEmitterSpatialization(deviceData, state) then
        state.emitter:stopSound(state.handle)
        state.handle = nil
        state.failed = true
        return false
    end
    state.emitter:setVolume(state.handle, deviceData:getDeviceVolume() * TheRoadSoFarFMVolume.scale())
    return true
end

local function startCassetteCue(deviceData, state, cueSound, now)
    local handle = playCassetteSound(deviceData, state, cueSound)
    if handle and setEmitter3D(
        state.emitter, handle, not isInventoryDevice(deviceData), cueSound) then
        state.cueHandle = handle
        state.cueStartedAt = now
        return true
    end
    if handle then
        state.emitter:stopSound(handle)
    end
    return false
end

-- A playback that joined mid-track (offset) is out of step with the others. Its track fades
-- out and the rewind sound plays so that it ends exactly as the server starts the next
-- track. Returns the volume factor to apply to the track.
local function offsetEndingFactor(deviceData, state, sharedState)
    local sync = TheRoadSoFarFMSync
    if state.joinMode ~= "offset" or not sharedState
        or not sharedState.durationMs or not sharedState.startedLocalMs then
        return 1
    end

    local rewindSound = sync.Sounds.cassette.rewind
    local rewindMs = sync.durationMs(rewindSound)
    if not rewindMs then
        return 1
    end

    local now = getTimestampMs()
    local remaining = sharedState.startedLocalMs + sharedState.durationMs
        + sync.AdvanceMarginMs - now
    local rewindStartRemaining = rewindMs + sync.CueEarlyMs

    if not state.cueHandle and not state.cueSkipped and remaining <= rewindStartRemaining then
        if remaining >= sync.CueMinRemainingMs and startCassetteCue(deviceData, state, rewindSound, now) then
            print("[TheRoadSoFarFM][MP][Sync] Cassette rewind started on "
                .. tostring(state.cassetteServerId) .. ", remaining=" .. tostring(math.floor(remaining)) .. " ms.")
        else
            state.cueSkipped = true
        end
    end

    if state.cueHandle then
        local volume = deviceData:getDeviceVolume() * TheRoadSoFarFMVolume.scale()
        if state.cueVolume ~= volume then
            state.emitter:setVolume(state.cueHandle, volume * sync.CueGain)
            state.cueVolume = volume
        end
    end

    return math.max(0, math.min(1, (remaining - rewindStartRemaining) / sync.OffsetFadeMs))
end

local function newPlaybackState(deviceData, player, device, joinMode)
    local networkId = cassetteNetworkId(device)
    local sharedState = networkId and approvedCassetteStates[networkId]
    local stage = sharedState and "tracks" or "inserting"
    -- Multiplayer: the inserting sound plays while the server's start of the track is still
    -- ahead, so the track begins after it for everybody.
    if sharedState and sharedState.leadInEndsLocalMs and joinMode ~= "offset"
        and sharedState.leadInEndsLocalMs - getTimestampMs() >= INSERT_MIN_REMAINING_MS then
        stage = "inserting"
    end
    local state = {
        trackIndex = sharedState and sharedState.trackIndex or 1,
        stage = stage,
        device = device,
        player = player,
        cassetteServerId = networkId,
        cassetteServerVersion = sharedState and sharedState.version,
        joinMode = joinMode,
    }
    if isClient() and joinMode then
        print("[TheRoadSoFarFM][MP][Sync] Cassette " .. tostring(networkId)
            .. " joining track " .. tostring(state.trackIndex) .. ", join=" .. joinMode
            .. (stage == "inserting" and ", with inserting sound" or "") .. ".")
    end
    startCurrentSound(deviceData, state)
    return state
end

local function playCurrentTrack(deviceData, state)
    state.stage = "tracks"
    local track = TheRoadSoFarFMCassette.Tracks[state.trackIndex]
    if not startCurrentSound(deviceData, state) then
        return
    end
    if track then
        announceTrackTitle(track, deviceData, state)
    end
end

-- When the item changes form (dropped, picked up, placed) the game hands the client a new
-- device object. The playback is moved to it, so nothing restarts or asks the server again.
-- In multiplayer only a playback of the very same cassette device (same id) is taken over.
local function takeTransferableState(deviceData, seenDevices, now, matchId)
    for previousDeviceData, state in pairs(activePlayers) do
        if state.missingSince and now - state.missingSince > DEVICE_HANDOFF_WINDOW_MS then
            stopPlayback(previousDeviceData, state)
        elseif previousDeviceData ~= deviceData
            and not seenDevices[previousDeviceData]
            and (not matchId or state.cassetteServerId == matchId)
            and (not state.missingSince or now - state.missingSince <= DEVICE_HANDOFF_WINDOW_MS) then
            activePlayers[previousDeviceData] = nil
            state.missingSince = nil
            return state
        end
    end
    return nil
end

local function processDevice(device, player, seenDevices)
    if not device or not device.getDeviceData then
        return
    end

    local deviceData = device:getDeviceData()
    if not deviceData then
        return
    end

    seenDevices[deviceData] = true
    local mediaData = deviceData:getMediaData()
    local isOurCassette = mediaData and mediaData:getId() == CASSETTE_MEDIA_ID
    local state = activePlayers[deviceData]
    local networkId = cassetteNetworkId(device)

    if isOurCassette and not state then
        if not isClient() then
            state = takeTransferableState(deviceData, seenDevices, getTimestampMs())
        elseif networkId then
            state = takeTransferableState(deviceData, seenDevices, getTimestampMs(), networkId)
        end
        if state then
            activePlayers[deviceData] = state
        end
    end
    if state then
        state.device = device
        state.player = player
    end

    if not isOurCassette then
        if state then
            stopPlayback(deviceData, state)
        end
        return
    end

    if not deviceData:getIsTurnedOn() then
        if state then
            stopPlayback(deviceData, state)
        end
        return
    end

    if isClient() and not networkId then
        if not unstableIdentityWarnings[deviceData] then
            print("[TheRoadSoFarFM] Cannot synchronize cassette playback: device has no stable multiplayer identity.")
            unstableIdentityWarnings[deviceData] = true
        end
        return
    end

    local sharedState = networkId and approvedCassetteStates[networkId]
    if isClient() and not sharedState then
        requestCassetteState(player, networkId, false)
        return
    end

    local canStartPlayback = isClient()
        and sharedState.playing == true
        or not isClient() and deviceData:isPlayingMedia()
    if isClient() and not sharedState.playing then
        if state then
            stopPlayback(deviceData, state)
        end
        return
    end

    local inventoryDevice = isInventoryDevice(deviceData) == true
    if state and not isClient() and not deviceData:isPlayingMedia() then
        restoreMediaPlayingState(deviceData)
    end

    if state and state.missingSince
        and getTimestampMs() - state.missingSince > DEVICE_HANDOFF_WINDOW_MS then
        stopPlayback(deviceData, state)
        state = nil
    end

    if not state then
        if not canStartPlayback then
            return
        end
        local joinMode
        if isClient() then
            if cassetteAudible(device, deviceData, player) then
                -- Audible: the server decides how to join.
                joinMode = cassetteJoinMode(sharedState)
                if not joinMode then
                    requestCassetteState(player, networkId, true)
                    return
                end
            elseif cassetteCanStartSilently(sharedState) then
                -- Muted start, aligned with the server clock until the player gets close.
                joinMode = "start"
            else
                return
            end
        end
        state = newPlaybackState(deviceData, player, device, joinMode)
        if not state then
            return
        end
        activePlayers[deviceData] = state
    end
    if sharedState and state.cassetteServerVersion ~= sharedState.version then
        if state.emitter then
            if state.handle then
                state.emitter:stopSound(state.handle)
            end
            if state.cueHandle then
                state.emitter:stopSound(state.cueHandle)
            end
        end
        state.handle = nil
        state.cueHandle = nil
        state.cueStartedAt = nil
        state.cueSkipped = nil
        state.cueVolume = nil
        state.joinMode = "start"
        state.silentSince = nil
        state.trackIndex = sharedState.trackIndex
        state.cassetteServerVersion = sharedState.version
        state.waitingForServer = false
        state.complete = false
        state.failed = false
        state.stage = "tracks"
    end
    if state.complete and canStartPlayback then
        state = newPlaybackState(deviceData, player, device)
        if not state then
            activePlayers[deviceData] = nil
            return
        end
        activePlayers[deviceData] = state
    end

    if state.failed or state.complete then
        return
    end

    if isClient() then
        local audible = cassetteAudible(device, deviceData, player)
        state.audible = audible
        if audible then
            state.silentSince = nil
        elseif state.joinMode == "offset" then
            -- Only a playback that is out of step with the server clock is dropped when out
            -- of range; aligned and waiting playbacks keep running muted.
            local silentNow = getTimestampMs()
            state.silentSince = state.silentSince or silentNow
            if silentNow - state.silentSince >= TheRoadSoFarFMSync.SilentStopMs then
                print("[TheRoadSoFarFM][MP][Sync] Out of range, stopping unsynced cassette playback on "
                    .. tostring(state.cassetteServerId) .. ".")
                stopPlayback(deviceData, state)
                return
            end
        end
    end

    updateZombieAttraction(player, state, device, deviceData)
    if state.waitingForServer then
        return
    end

    local tracks = TheRoadSoFarFMCassette.Tracks
    if state.trackIndex > #tracks then
        state.complete = true
        return
    end

    if state.handle then
        if state.emitter:isPlaying(state.handle) then
            if not updateEmitterSpatialization(deviceData, state) then
                state.emitter:stopSound(state.handle)
                state.handle = nil
                state.failed = true
                return
            end
            state.emitter:setVolume(
                state.handle,
                deviceData:getDeviceVolume() * TheRoadSoFarFMVolume.scale()
                    * offsetEndingFactor(deviceData, state, sharedState))
            return
        end
        state.handle = nil
        if state.stage == "inserting" then
            state.stage = "tracks"
        elseif state.cassetteServerId then
            requestCassetteAdvance(state)
            return
        else
            state.trackIndex = state.trackIndex + 1
        end
        if state.trackIndex > #tracks then
            state.complete = true
            return
        end
    end

    playCurrentTrack(deviceData, state)
end

local function onServerCommand(module, command, args)
    if module ~= MODULE or command ~= "cassetteState" or type(args) ~= "table"
        or type(args.deviceId) ~= "string"
        or type(args.trackIndex) ~= "number"
        or type(args.version) ~= "number" then
        return
    end

    local trackCount = #TheRoadSoFarFMCassette.Tracks
    if args.trackIndex < 1 or args.trackIndex > trackCount
        or args.trackIndex ~= math.floor(args.trackIndex)
        or args.version < 1 or args.version ~= math.floor(args.version) then
        return
    end

    local current = approvedCassetteStates[args.deviceId]
    if current and args.version < current.version then
        return
    end
    pendingCassetteStarts[args.deviceId] = nil
    local sync = TheRoadSoFarFMSync
    local entry = {
        trackIndex = args.trackIndex,
        version = args.version,
        playing = args.playing == true,
    }
    if entry.playing and sync.isValidMs(args.elapsedMs) and sync.isValidMs(args.durationMs)
        and args.durationMs > 0 then
        local leadInMs = 0
        if sync.isValidMs(args.leadInMs) and args.leadInMs <= 30000 then
            leadInMs = args.leadInMs
        end
        -- The track begins after the inserting sound, so its local start can lie ahead.
        entry.startedLocalMs = getTimestampMs() - args.elapsedMs + leadInMs
        entry.durationMs = args.durationMs
        if leadInMs > 0 then
            entry.leadInEndsLocalMs = entry.startedLocalMs
        end
    end
    if current and current.version == args.version then
        entry.decision = current.decision
    end
    if args.reply == true and args.join == "offset" then
        entry.decision = { mode = args.join }
    end
    approvedCassetteStates[args.deviceId] = entry
    if args.playing ~= true then
        local devicesToStop = {}
        for deviceData, state in pairs(activePlayers) do
            if state.cassetteServerId == args.deviceId then
                devicesToStop[#devicesToStop + 1] = deviceData
            end
        end
        for _, deviceData in ipairs(devicesToStop) do
            stopPlayback(deviceData, activePlayers[deviceData])
            if deviceData:isPlayingMedia() then
                deviceData:StopPlayMedia()
            end
            if deviceData.setIsPlayingMedia then
                deviceData:setIsPlayingMedia(false)
            end
        end
    end
end

function TheRoadSoFarFMCassette.skip()
    local skipped = 0
    for deviceData, state in pairs(activePlayers) do
        if not state.complete and not state.missingSince then
            if state.cassetteServerId then
                requestCassetteAdvance(state)
            else
                if state.handle then
                    state.emitter:stopSound(state.handle)
                    state.handle = nil
                end

                if state.stage == "inserting" then
                    state.stage = "tracks"
                else
                    state.trackIndex = state.trackIndex + 1
                end
                state.failed = false
                playCurrentTrack(deviceData, state)
            end
            skipped = skipped + 1
        end
    end

    if skipped == 0 then
        print("[TheRoadSoFarFM] No active cassette track to skip.")
        return
    end
    print("[TheRoadSoFarFM] Debug skip requested for " .. skipped .. " cassette playback(s).")
end

local stopCassettePlaybackAfterDeath

local function updateCassettePlayback(player)
    if player ~= getPlayer() then
        return
    end

    if player:isDead() then
        stopCassettePlaybackAfterDeath(player)
        return
    end

    local radio = getZomboidRadio()
    if not radio then
        return
    end

    local seenDevices = {}
    local processedDevices = {}
    local function process(device)
        if not device or processedDevices[device] then
            return
        end
        processedDevices[device] = true
        processDevice(device, player, seenDevices)
    end

    local devices = radio:getDevices()
    for i = 0, devices:size() - 1 do
        process(devices:get(i))
    end

    local function processInventory(container)
        if not container then
            return
        end
        local items = container:getItems()
        for i = 0, items:size() - 1 do
            local item = items:get(i)
            if instanceof(item, "Radio") then
                process(item)
            elseif item.getInventory then
                processInventory(item:getInventory())
            end
        end
    end

    processInventory(player:getInventory())
    process(player:getPrimaryHandItem())
    process(player:getSecondaryHandItem())
    process(player:getClothingItem_Back())

    local now = getTimestampMs()
    for deviceData, state in pairs(activePlayers) do
        if state.missingSince then
            if now - state.missingSince > DEVICE_HANDOFF_WINDOW_MS then
                stopPlayback(deviceData, state)
            end
        elseif not seenDevices[deviceData] then
            state.missingSince = now
        end
    end

    if isClient() then
        local sync = TheRoadSoFarFMSync
        local audibleIds = {}
        for _, state in pairs(activePlayers) do
            if state.cassetteServerId and not state.missingSince
                and state.audible and not state.failed then
                audibleIds[state.cassetteServerId] = true
            end
        end
        for deviceId in pairs(audibleIds) do
            local last = lastHeartbeatAt[deviceId]
            if not last or now - last >= sync.ListenerHeartbeatMs then
                lastHeartbeatAt[deviceId] = now
                sendClientCommand(player, MODULE, "listenHeartbeat", {
                    kind = "cassette",
                    id = deviceId,
                })
            end
        end
        for deviceId in pairs(lastHeartbeatAt) do
            if not audibleIds[deviceId] then
                lastHeartbeatAt[deviceId] = nil
                sendClientCommand(player, MODULE, "listenStop", {
                    kind = "cassette",
                    id = deviceId,
                })
            end
        end
    end
end

-- A dead player hears nothing, like the radio: every playback of this client stops. Carried
-- cassette players also get switched off, and the server is told so it does not keep a stale
-- "playing" state. A radio left in the world is not touched and plays again for whoever
-- comes near it (including the next character).
stopCassettePlaybackAfterDeath = function(player)
    local localPlayer = getPlayer()
    if localPlayer and player and player ~= localPlayer then
        return
    end

    local playerToStop = player or localPlayer
    local carried, placed = {}, {}
    for deviceData, state in pairs(activePlayers) do
        if not playerToStop or state.player == playerToStop then
            if isInventoryDevice(deviceData) then
                carried[#carried + 1] = deviceData
            else
                placed[#placed + 1] = deviceData
            end
        end
    end

    for _, deviceData in ipairs(carried) do
        local state = activePlayers[deviceData]
        local deviceId = state and state.cassetteServerId
        if stopCassettePlayback(deviceData) then
            print("[TheRoadSoFarFM] Stopped inventory cassette playback after player death.")
            if isClient() and deviceId then
                pcall(sendClientCommand, playerToStop or getPlayer(), MODULE, "cassetteStop", {
                    deviceId = deviceId,
                })
            end
        end
    end

    -- Multiplayer only: singleplayer keeps stopping just the carried cassette, as before.
    for _, deviceData in ipairs(isClient() and placed or {}) do
        local state = activePlayers[deviceData]
        if state then
            stopPlayback(deviceData, state)
            print("[TheRoadSoFarFM] Stopped local cassette playback after player death.")
        end
    end
end

Events.OnPlayerUpdate.Add(updateCassettePlayback)
Events.OnPlayerDeath.Add(stopCassettePlaybackAfterDeath)
Events.OnServerCommand.Add(onServerCommand)

require "RadioCom/ISRadioAction"

if not ISRadioAction.TheRoadSoFarFMCassetteHooked then
    local originalTogglePlayMedia = ISRadioAction.performTogglePlayMedia
    ISRadioAction.performTogglePlayMedia = function(action)
        local deviceData = action.deviceData
        local mediaData = deviceData and deviceData:getMediaData()
        if mediaData and mediaData:getId() == CASSETTE_MEDIA_ID then
            local deviceId = cassetteNetworkId(action.device)
            local sharedState = deviceId and approvedCassetteStates[deviceId]
            local shouldStop = activePlayers[deviceData] ~= nil
                or sharedState and sharedState.playing == true
                or not sharedState and deviceData:isPlayingMedia()
            if shouldStop then
                if not stopCassettePlayback(deviceData) then
                    if deviceData:isPlayingMedia() then
                        deviceData:StopPlayMedia()
                    end
                    if deviceData.setIsPlayingMedia then
                        deviceData:setIsPlayingMedia(false)
                    end
                end
                if isClient() and deviceId then
                    sendClientCommand(action.character or getPlayer(), MODULE, "cassetteStop", {
                        deviceId = deviceId,
                    })
                end
                return
            end

            originalTogglePlayMedia(action)
            if isClient() and deviceId then
                sendClientCommand(action.character or getPlayer(), MODULE, "cassetteStart", {
                    deviceId = deviceId,
                })
            end
            return
        end

        originalTogglePlayMedia(action)
    end
    ISRadioAction.TheRoadSoFarFMCassetteHooked = true
end

require "RadioCom/RadioWindowModules/RWMMedia"

if not RWMMedia.TheRoadSoFarFMCassetteHooked then
    local originalUpdate = RWMMedia.update
    local originalTogglePlayMedia = RWMMedia.togglePlayMedia

    RWMMedia.togglePlayMedia = function(panel)
        local deviceData = panel.deviceData
        local mediaData = deviceData and deviceData:getMediaData()
        local canInteract = panel.player
            and deviceData
            and deviceData:canPlayerRemoteInteract(panel.player)
            or panel:doWalkTo()

        if mediaData and mediaData:getId() == CASSETTE_MEDIA_ID
            and activePlayers[deviceData]
            and deviceData:getIsTurnedOn()
            and deviceData:hasMedia()
            and canInteract then
            local deviceId = cassetteNetworkId(panel.device)
            stopCassettePlayback(deviceData)
            if isClient() and deviceId then
                sendClientCommand(panel.player or getPlayer(), MODULE, "cassetteStop", {
                    deviceId = deviceId,
                })
            end
            return
        end

        originalTogglePlayMedia(panel)
    end

    RWMMedia.update = function(panel)
        originalUpdate(panel)

        local deviceData = panel.deviceData
        local mediaData = deviceData and deviceData:getMediaData()
        if mediaData and mediaData:getId() == CASSETTE_MEDIA_ID
            and activePlayers[deviceData]
            and panel.toggleOnOffButton then
            panel.toggleOnOffButton:setTitle(panel.textStop)
        end
    end
    RWMMedia.TheRoadSoFarFMCassetteHooked = true
end
