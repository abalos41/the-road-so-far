TheRoadSoFarFMTestAudio = TheRoadSoFarFMTestAudio or {}

local testEmitter
local testSound
local activeTracks = {}
local localPlaylists = {}
local pendingStarts = {}
local pendingStops = {}
local approvedStarts = {}
local worldSoundCounters = {}
local pendingInitialAnnouncement
local initialAnnouncementDisplayed = false
local RADIO_RANGE_MULTIPLIER = 3.5
local RADIO_GAIN_MULTIPLIER = 0.75
local MODULE = "TheRoadSoFarFM"
local ROAD_SO_FAR_FREQUENCY = 99600
local USER_TRACKS_FREQUENCY = 100200
local WELCOME_ANNOUNCEMENT_DELAY = 120
local missingUserTracksPlaylistReported = false
local worldSoundApiWarningReported = false
local deviceSoundRangeWarningReported = false

local function zombieAttractionDisabled()
    return SandboxVars and SandboxVars.TheRoadSoFarFM
        and SandboxVars.TheRoadSoFarFM.DisableZombieAttraction == true
end

local function announceTrackTitle(title, device, deviceData, player)
    if type(title) ~= "string" or title == "" then
        return
    end

    if instanceof(device, "Radio") then
        player:SayRadio(
            title,
            0.53,
            0.81,
            0.92,
            UIFont.Medium,
            deviceData:getDeviceVolumeRange(),
            deviceData:getChannel(),
            "radio"
        )
        return
    end

    if not device or not device.AddDeviceText then
        print("[TheRoadSoFarFM] Cannot announce track title: radio device text API is unavailable.")
        return
    end

    local codes = ""
    if instanceof(device, "VehiclePart") then
        device:AddDeviceText(title, 0.53, 0.81, 0.92, nil, codes, -1)
    else
        device:AddDeviceText(player, title, 0.53, 0.81, 0.92, nil, codes, -1)
    end
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

    testEmitter = player:getEmitter()
    local playlistConfig = TheRoadSoFarFMConfig
    testSound = testEmitter:playSound(playlistConfig.Tracks[1])
    if not testSound then
        print("[TheRoadSoFarFM] Failed to start the first playlist track.")
        testEmitter = nil
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

local function devicePosition(device, player)
    local deviceData = device:getDeviceData()
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

local function updateZombieAttraction(player, key, device, deviceData)
    if zombieAttractionDisabled() then
        worldSoundCounters[key] = nil
        return
    end

    local deviceVolume = deviceData:getDeviceVolume()
    if type(deviceVolume) ~= "number" or deviceVolume <= 0 then
        worldSoundCounters[key] = nil
        return
    end

    if isInventoryDevice(deviceData) and deviceData:getHeadphoneType() >= 0 then
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

    local x, y, z = devicePosition(device, player)
    x, y, z = math.floor(x), math.floor(y), math.floor(z)
    if isClient() and not isInventoryDevice(deviceData) then
        sendClientCommand(player, MODULE, "radioNoise", {
            key = key,
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

        local source = isInventoryDevice(deviceData) and player or device
        if instanceof(device, "VehiclePart") then
            source = device:getVehicle()
        end
        worldSoundManager:addSoundRepeating(source, x, y, z, range, volume, volume > 50)
    end

    local randomDelay = ZombRand and ZombRand(300) or math.random(0, 299)
    worldSoundCounters[key] = 300 + randomDelay
end

local function updateTrackVolume(track, player)
    local deviceX, deviceY, deviceZ = devicePosition(track.device, player)
    local dx = player:getX() - deviceX
    local dy = player:getY() - deviceY
    local dz = (player:getZ() - deviceZ) * 3
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    local deviceVolume = track.deviceData:getDeviceVolume()
    local volume
    if isInventoryDevice(track.deviceData) then
        volume = deviceVolume * RADIO_GAIN_MULTIPLIER
    else
        local range = track.deviceData:getBaseVolumeRange() * deviceVolume * RADIO_RANGE_MULTIPLIER
        volume = 0
        if range > 0 then
            volume = deviceVolume * math.max(0, 1 - distance / range) * RADIO_GAIN_MULTIPLIER
        end
    end

    if track.volume ~= volume then
        track.emitter:setVolume(track.soundHandle, volume)
        track.volume = volume
    end
end

local function startTrack(key, device, deviceData, player, playback)
    local existing = activeTracks[key]
    if existing then
        if existing.version == playback.version and existing.soundName == playback.soundName then
            existing.device = device
            existing.deviceData = deviceData
            if existing.unavailable then
                if not existing.emitter:isPlaying(existing.soundHandle) then
                    local soundHandle = existing.emitter:playSound(existing.soundName)
                    if not soundHandle then
                        print("[TheRoadSoFarFM] Failed to resume sound " .. existing.soundName .. ".")
                        return nil
                    end
                    existing.soundHandle = soundHandle
                end
                existing.unavailable = false
                existing.volume = nil
            end
            return existing
        end
        stopTrack(key)
    end

    local emitter = player:getEmitter()
    if not emitter then
        print("[TheRoadSoFarFM] No sound emitter is available for " .. playback.soundName .. ".")
        return nil
    end

    local soundHandle = emitter:playSound(playback.soundName)
    if not soundHandle then
        print("[TheRoadSoFarFM] Failed to start sound " .. playback.soundName .. ".")
        return nil
    end

    local track = {
        device = device,
        deviceData = deviceData,
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
    }
    activeTracks[key] = track
    if isInventoryDevice(deviceData) then
        print("[TheRoadSoFarFM] Started inventory radio track " .. playback.soundName .. ".")
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
        if initialAnnouncementDisplayed then
            announceTrackTitle(announcement, device, deviceData, player)
        else
            pendingInitialAnnouncement = {
                title = announcement,
                player = player,
                device = device,
                deviceData = deviceData,
                ticksRemaining = WELCOME_ANNOUNCEMENT_DELAY,
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

local function onServerCommand(module, command, args)
    if module ~= MODULE or not args or type(args.key) ~= "string" then
        return
    end

    local key = args.key
    if command == "play" and type(args.sound) == "string" and type(args.version) == "number" then
        pendingStarts[key] = nil
        pendingStops[key] = nil
        setApprovedPlayback(key, args.sound, args.version, args.kind, args.title, args.welcome)
        stopTrack(key)
    elseif command == "stop" then
        pendingStarts[key] = nil
        pendingStops[key] = nil
        approvedStarts[key] = nil
        localPlaylists[key] = nil
        stopTrack(key)
    end
end

local function radioCoordinates(device, player)
    local x, y = devicePosition(device, player)
    return math.floor(x), math.floor(y)
end

local function requestStart(player, key, device, deviceData, playlistConfig)
    if approvedStarts[key] then
        return
    end

    if isClient() then
        if deviceData:getChannel() == USER_TRACKS_FREQUENCY then
            return
        end
        if not pendingStarts[key] then
            pendingStarts[key] = true
            local x, y = radioCoordinates(device, player)
            sendClientCommand(player, MODULE, "requestStart", {
                key = key,
                frequency = deviceData:getChannel(),
                x = x,
                y = y,
            })
        end
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
        local x, y = radioCoordinates(track.device, getPlayer())
        sendClientCommand(getPlayer(), MODULE, "requestAdvance", {
            key = key,
            version = track.version,
            x = x,
            y = y,
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
                    key = key,
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

local function requestStop(key)
    local hadPlaybackState = approvedStarts[key] ~= nil or pendingStarts[key] ~= nil
    approvedStarts[key] = nil
    pendingStarts[key] = nil
    localPlaylists[key] = nil
    stopTrack(key)
    if isClient() and hadPlaybackState and not pendingStops[key] then
        pendingStops[key] = true
        sendClientCommand(getPlayer(), MODULE, "requestStop", { key = key })
    end
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

    if pendingInitialAnnouncement and pendingInitialAnnouncement.player == player then
        pendingInitialAnnouncement.ticksRemaining = pendingInitialAnnouncement.ticksRemaining - 1
        if pendingInitialAnnouncement.ticksRemaining <= 0 then
            local announcement = pendingInitialAnnouncement
            pendingInitialAnnouncement = nil
            announceTrackTitle(
                announcement.title,
                announcement.device,
                announcement.deviceData,
                player
            )
            initialAnnouncementDisplayed = true
            print("[TheRoadSoFarFM] Displayed initial radio announcement: " .. announcement.title)
        end
    end

    local radio = getZomboidRadio()
    if not radio then
        return
    end

    local currentDevices = {}
    local processedDevices = {}
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
                local inventoryDevice = isInventoryDevice(deviceData)
                local isPlayingStation = deviceData:getIsTurnedOn()
                    and (channel == ROAD_SO_FAR_FREQUENCY or channel == USER_TRACKS_FREQUENCY)
                local playlistConfig = getPlaylistConfig(channel)
                if channel == USER_TRACKS_FREQUENCY and not playlistConfig then
                    isPlayingStation = false
                end
                if isPlayingStation then
                    currentDevices[key] = true
                    requestStart(player, key, device, deviceData, playlistConfig)
                    updateZombieAttraction(player, key, device, deviceData)
                    local playback = approvedStarts[key]
                    if playback then
                        local track = startTrack(key, device, deviceData, player, playback)
                        if track then
                            updateTrackVolume(track, player)
                            if not track.emitter:isPlaying(track.soundHandle) then
                                requestAdvance(key, track)
                            end
                        end
                    end
                elseif inventoryDevice and (activeTracks[key] or approvedStarts[key]) then
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

    local devices = radio:getDevices()
    for i = 0, devices:size() - 1 do
        processDevice(devices:get(i))
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

    for key in pairs(worldSoundCounters) do
        if not currentDevices[key] then
            worldSoundCounters[key] = nil
        end
    end

    for key in pairs(activeTracks) do
        if not currentDevices[key] then
            local track = activeTracks[key]
            track.unavailable = true
        end
    end
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnPlayerUpdate.Add(updateRadioTracks)
