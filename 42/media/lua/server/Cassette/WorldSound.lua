local MODULE = "TheRoadSoFarFM"
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

local function emitCassetteNoise(player, args)
    if zombieAttractionDisabled()
        or type(args.key) ~= "string" or #args.key > 64
        or not isFiniteNumber(args.x) or not isFiniteNumber(args.y)
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

    local playerId = tostring(player:getOnlineID())
    local now = getTimestampMs()
    local lastEventAt = lastNoiseEventAt[playerId]
    if lastEventAt and now - lastEventAt < NOISE_COMMAND_COOLDOWN_MS then
        return
    end

    local worldSoundManager = getWorldSoundManager and getWorldSoundManager()
    if not worldSoundManager or not worldSoundManager.addSoundRepeating then
        if not worldSoundApiWarningReported then
            print("[TheRoadSoFarFM] Repeating world sound API is unavailable; cassette noise was not emitted.")
            worldSoundApiWarningReported = true
        end
        return
    end

    worldSoundManager:addSoundRepeating(nil, x, y, z, radius, volume, volume > 50)
    lastNoiseEventAt[playerId] = now
end

local function onClientCommand(module, command, player, args)
    if module == MODULE and command == "cassetteNoise" and type(args) == "table" then
        emitCassetteNoise(player, args)
    end
end

Events.OnClientCommand.Add(onClientCommand)
