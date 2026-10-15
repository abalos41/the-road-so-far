local MODULE = "TheRoadSoFarFM"
local RADIO_FREQUENCY = 99600
local Noise = TheRoadSoFarFMNoise

-- registry[deviceKey] = { kind, target, deviceId, seenAt, nextEmitAt }
-- Keys come from devices the server itself resolved, so clients cannot create arbitrary ones.
local registry = {}
local lastReportAt = {}
local rejectLoggedAt = {}
local lastTickAt = 0
local TICK_INTERVAL_MS = 500

local function zombieAttractionDisabled()
    return SandboxVars and SandboxVars.TheRoadSoFarFM
        and SandboxVars.TheRoadSoFarFM.DisableZombieAttraction == true
end

-- Rejections are logged at most once per reason per minute.
local function reject(reason)
    local now = getTimestampMs()
    local last = rejectLoggedAt[reason]
    if not last or now - last > 60000 then
        rejectLoggedAt[reason] = now
        print("[TheRoadSoFarFM][Noise] Report ignored: " .. reason .. ".")
    end
end

local function isCoordinate(value, min, max)
    return type(value) == "number" and value == value and value == math.floor(value)
        and value >= min and value <= max
end

local function validId(value, maxLength, pattern)
    return type(value) == "string" and #value > 0 and #value <= maxLength
        and value:match(pattern) ~= nil
end

local function readTarget(args)
    if args.vehicleId ~= nil then
        if not isCoordinate(args.vehicleId, 0, 1000000000)
            or not validId(args.partId, 32, "^[%w_]+$") then
            return nil
        end
        return { vehicleId = args.vehicleId, partId = args.partId }
    end

    if isCoordinate(args.x, -1000000, 1000000) and isCoordinate(args.y, -1000000, 1000000)
        and isCoordinate(args.z, 0, 15) then
        return { x = args.x, y = args.y, z = args.z }
    end
    return nil
end

local function acceptFor(kind, expectedDeviceId)
    if kind == "radio" then
        return function(deviceData)
            return deviceData:getIsTurnedOn() and deviceData:getDeviceVolume() > 0
                and deviceData:getChannel() == RADIO_FREQUENCY
                and TheRoadSoFarFMRadioServer ~= nil
                and TheRoadSoFarFMRadioServer.isStationActive(RADIO_FREQUENCY)
        end
    end

    return function(deviceData, deviceId)
        if deviceId ~= expectedDeviceId or not TheRoadSoFarFMCassetteServer
            or not TheRoadSoFarFMCassetteServer.isPlaying(deviceId) then
            return false
        end
        local mediaData = deviceData:getMediaData()
        return deviceData:getIsTurnedOn() and deviceData:getDeviceVolume() > 0
            and mediaData ~= nil and mediaData:getId() == TheRoadSoFarFMCassette.MediaId
    end
end

-- Returns the sound source, its device data, a stable key and its position, or nil.
local function resolveFixed(target, accept)
    local cell = getCell and getCell()
    local square = cell and cell:getGridSquare(target.x, target.y, target.z)
    if not square then
        return nil
    end

    local objects = square:getObjects()
    for i = 0, objects:size() - 1 do
        local object = objects:get(i)
        if instanceof(object, "IsoWaveSignal") then
            local deviceData = object:getDeviceData()
            if deviceData and accept(deviceData, TheRoadSoFarFMCassette.deviceId(object)) then
                local key = string.format(
                    "w:%d:%d:%d:%d", target.x, target.y, target.z, object:getObjectIndex())
                return object, deviceData, key, target.x, target.y, target.z
            end
        end
    end
    return nil
end

local function resolveVehicle(target, accept)
    local vehicle = getVehicleById and getVehicleById(target.vehicleId)
    local part = vehicle and vehicle:getPartById(target.partId)
    local deviceData = part and part:getDeviceData()
    if not deviceData then
        return nil
    end

    if not accept(deviceData, TheRoadSoFarFMCassette.deviceId(part)) then
        return nil
    end
    return vehicle, deviceData, "v:" .. tostring(target.vehicleId) .. ":" .. target.partId,
        math.floor(vehicle:getX()), math.floor(vehicle:getY()), math.floor(vehicle:getZ())
end

local function resolve(kind, target, deviceId)
    local accept = acceptFor(kind, deviceId)
    if target.vehicleId then
        return resolveVehicle(target, accept)
    end
    return resolveFixed(target, accept)
end

local function emit(entry)
    local ok, source, deviceData, _, x, y, z = pcall(resolve, entry.kind, entry.target, entry.deviceId)
    if not ok then
        reject("device lookup failed (" .. tostring(source) .. ")")
        return false
    end
    if not source then
        return false
    end

    local volume = math.min(Noise.MaxVolume, math.floor(100 * deviceData:getDeviceVolume()))
    local range = math.min(Noise.MaxRange, deviceData:getDeviceSoundVolumeRange())
    if volume < 1 or range < 1 then
        return false
    end

    local manager = getWorldSoundManager and getWorldSoundManager()
    if not manager or not manager.addSoundRepeating then
        reject("repeating world sound API is unavailable")
        return false
    end

    manager:addSoundRepeating(source, x, y, z, range, volume, volume > 50)
    if not entry.logged then
        entry.logged = true
        print("[TheRoadSoFarFM][Noise] " .. entry.kind .. " noise started: range=" .. range
            .. ", volume=" .. volume .. ".")
    end
    return true
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or command ~= "deviceNoise" or type(args) ~= "table" or not player then
        return
    end
    if zombieAttractionDisabled() then
        return
    end

    local kind = args.kind
    if kind ~= "radio" and kind ~= "cassette" then
        return
    end

    local now = getTimestampMs()
    local onlineId = player:getOnlineID()
    local lastAt = lastReportAt[onlineId]
    if lastAt and now - lastAt < Noise.PlayerMinIntervalMs then
        return
    end
    lastReportAt[onlineId] = now

    local target = readTarget(args)
    if not target then
        reject("malformed device reference")
        return
    end

    local deviceId
    if kind == "cassette" then
        if not validId(args.deviceId, 64, "^[%w_:%-%.]+$") then
            reject("malformed cassette id")
            return
        end
        deviceId = args.deviceId
    end

    local ok, source, _, key, x, y = pcall(resolve, kind, target, deviceId)
    if not ok then
        reject("device lookup failed (" .. tostring(source) .. ")")
        return
    end
    if not source then
        reject(kind .. " device not found, off, or not playing")
        return
    end

    local dx, dy = x - player:getX(), y - player:getY()
    if dx * dx + dy * dy > Noise.MaxPlayerDistance * Noise.MaxPlayerDistance then
        reject("reporting player is too far from the device")
        return
    end

    local entry = registry[key]
    if not entry then
        entry = { kind = kind, target = target, deviceId = deviceId, nextEmitAt = now }
        registry[key] = entry
    end
    entry.seenAt = now
end

-- One counter per device: the noise cadence no longer depends on how many players report it.
local function onTick()
    local now = getTimestampMs()
    if now - lastTickAt < TICK_INTERVAL_MS then
        return
    end
    lastTickAt = now

    local disabled = zombieAttractionDisabled()
    for key, entry in pairs(registry) do
        if disabled or now - entry.seenAt > Noise.EntryTtlMs then
            registry[key] = nil
        elseif now >= entry.nextEmitAt then
            entry.nextEmitAt = now + Noise.EmitMinMs + ZombRand(Noise.EmitSpreadMs)
            if not emit(entry) then
                registry[key] = nil
            end
        end
    end
end

local function pruneReports()
    local now = getTimestampMs()
    for onlineId, at in pairs(lastReportAt) do
        if now - at > 60000 then
            lastReportAt[onlineId] = nil
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
Events.EveryOneMinute.Add(pruneReports)
if isServer and isServer() then
    Events.OnTick.Add(onTick)
end
