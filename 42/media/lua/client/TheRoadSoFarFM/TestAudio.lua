TheRoadSoFarFMTestAudio = TheRoadSoFarFMTestAudio or {}

local testEmitter
local testSound
local activeTracks = {}
local RADIO_RANGE_MULTIPLIER = 3.5
local RADIO_GAIN_MULTIPLIER = 1.5

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
    testSound = testEmitter:playSound("TheRoadSoFarFM_TestTrack")
    if not testSound then
        print("[TheRoadSoFarFM] Failed to start TheRoadSoFarFM_TestTrack.")
        testEmitter = nil
        return
    end
end

function TheRoadSoFarFMTestAudio.stop()
    if testSound and testEmitter then
        testEmitter:stopSound(testSound)
    end
    testEmitter = nil
    testSound = nil
end

local function stopTrack(deviceData)
    local track = activeTracks[deviceData]
    if track then
        track.emitter:stopSound(track.sound)
        activeTracks[deviceData] = nil
    end
end

local function updateTrackVolume(track, player)
    local device = track.device
    local dx = player:getX() - device:getX()
    local dy = player:getY() - device:getY()
    local dz = (player:getZ() - device:getZ()) * 3
    local distance = math.sqrt(dx * dx + dy * dy + dz * dz)
    local deviceVolume = track.deviceData:getDeviceVolume()
    local range = track.deviceData:getBaseVolumeRange() * deviceVolume * RADIO_RANGE_MULTIPLIER
    local volume = 0
    if range > 0 then
        volume = deviceVolume * math.max(0, 1 - distance / range) * RADIO_GAIN_MULTIPLIER
    end

    if track.volume ~= volume then
        track.emitter:setVolume(track.sound, volume)
        track.volume = volume
    end
end

local function updateRadioTracks(player)
    if player ~= getPlayer() then
        return
    end

    local radio = getZomboidRadio()
    if not radio then
        return
    end

    local devices = radio:getDevices()
    for i = 0, devices:size() - 1 do
        local device = devices:get(i)
        local deviceData = device and device:getDeviceData()
        if deviceData
            and deviceData:getIsTurnedOn()
            and deviceData:getChannel() == 99600 then
            local track = activeTracks[deviceData]
            if not track then
                stopTrack(deviceData)
                local emitter = player:getEmitter()
                local sound = emitter:playSound("TheRoadSoFarFM_TestTrack")
                if sound then
                    track = {
                        device = device,
                        deviceData = deviceData,
                        emitter = emitter,
                        sound = sound,
                        volume = nil,
                    }
                    activeTracks[deviceData] = track
                else
                    print("[TheRoadSoFarFM] Failed to start TheRoadSoFarFM_TestTrack on a radio.")
                end
            end

            if track then
                track.device = device
                updateTrackVolume(track, player)
            end
        end
    end

    for deviceData in pairs(activeTracks) do
        local track = activeTracks[deviceData]
        if not deviceData:getIsTurnedOn()
            or deviceData:getChannel() ~= 99600 then
            stopTrack(deviceData)
        elseif track then
            updateTrackVolume(track, player)
        end
    end
end

Events.OnPlayerUpdate.Add(updateRadioTracks)
