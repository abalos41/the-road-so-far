local CASSETTE_MEDIA_ID = "TheRoadSoFarFM_DeansTop13ZeppTraxx"
local DEVICE_HANDOFF_WINDOW_MS = 5000
local MODULE = "TheRoadSoFarFM"
local activePlayers = {}
local missingEmitterWarningReported = false
local deviceSoundRangeWarningReported = false
local worldSoundApiWarningReported = false
local nextNoiseKey = 0

local function zombieAttractionDisabled()
    return SandboxVars and SandboxVars.TheRoadSoFarFM
        and SandboxVars.TheRoadSoFarFM.DisableZombieAttraction == true
end

local function isInventoryDevice(deviceData)
    return deviceData.isInventoryDevice and deviceData:isInventoryDevice()
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
    if not state.noiseKey then
        nextNoiseKey = nextNoiseKey + 1
        state.noiseKey = "cassette:" .. tostring(nextNoiseKey)
    end
    if isClient() and not inventoryDevice then
        sendClientCommand(player, MODULE, "cassetteNoise", {
            key = state.noiseKey,
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
    if state.handle and state.emitter then
        state.emitter:stopSound(state.handle)
    end
    activePlayers[deviceData] = nil
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

    state.handle = state.emitter:playSound(soundName)
    if not state.handle then
        print("[TheRoadSoFarFM] Cassette playback failed to start " .. soundDescription .. ".")
        state.failed = true
        return false
    end
    state.emitter:setVolume(state.handle, deviceData:getDeviceVolume())
    return true
end

local function newPlaybackState(deviceData, player, device)
    local emitter = player:getEmitter()
    if not emitter then
        if not missingEmitterWarningReported then
            print("[TheRoadSoFarFM] Cassette playback could not start: player sound emitter is unavailable.")
            missingEmitterWarningReported = true
        end
        return nil
    end

    local state = {
        emitter = emitter,
        trackIndex = 1,
        stage = "inserting",
        device = device,
        player = player,
    }
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

local function takeTransferableState(deviceData, seenDevices, now)
    for previousDeviceData, state in pairs(activePlayers) do
        if state.missingSince and now - state.missingSince > DEVICE_HANDOFF_WINDOW_MS then
            stopPlayback(previousDeviceData, state)
        elseif previousDeviceData ~= deviceData
            and not seenDevices[previousDeviceData]
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
    local canStartPlayback = isOurCassette
        and deviceData:getIsTurnedOn()
        and deviceData:isPlayingMedia()
    local state = activePlayers[deviceData]

    if isOurCassette and not state then
        state = takeTransferableState(deviceData, seenDevices, getTimestampMs())
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

    if state and state.missingSince
        and getTimestampMs() - state.missingSince > DEVICE_HANDOFF_WINDOW_MS then
        stopPlayback(deviceData, state)
        state = nil
    end

    if not state then
        if not canStartPlayback then
            return
        end
        state = newPlaybackState(deviceData, player, device)
        if not state then
            return
        end
        activePlayers[deviceData] = state
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

    updateZombieAttraction(player, state, device, deviceData)

    local tracks = TheRoadSoFarFMCassette.Tracks
    if state.trackIndex > #tracks then
        state.complete = true
        return
    end

    if state.handle then
        if state.emitter:isPlaying(state.handle) then
            state.emitter:setVolume(state.handle, deviceData:getDeviceVolume())
            return
        end
        state.handle = nil
        if state.stage == "inserting" then
            state.stage = "tracks"
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

function TheRoadSoFarFMCassette.skip()
    local skipped = 0
    for deviceData, state in pairs(activePlayers) do
        if not state.complete and not state.missingSince then
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
            skipped = skipped + 1
        end
    end

    if skipped == 0 then
        print("[TheRoadSoFarFM] No active cassette track to skip.")
        return
    end
    print("[TheRoadSoFarFM] Debug skip requested for " .. skipped .. " cassette playback(s).")
end

local function updateCassettePlayback(player)
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
end

Events.OnPlayerUpdate.Add(updateCassettePlayback)
