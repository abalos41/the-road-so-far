-- Zombie-attracting noise of radios and cassette players (multiplayer, fixed and vehicle
-- devices). The server decides everything: clients only say "this device is playing near me".
TheRoadSoFarFMNoise = TheRoadSoFarFMNoise or {}

local Noise = TheRoadSoFarFMNoise

-- The server emits a device's noise this often, like the base game does (4-8 s).
Noise.EmitMinMs = 4000
Noise.EmitSpreadMs = 4000
-- A device stops emitting this long after the last client report.
Noise.EntryTtlMs = 20000
-- A reporting player has to be within this many tiles of the device.
Noise.MaxPlayerDistance = 150
-- Reports per player are processed at most this often.
Noise.PlayerMinIntervalMs = 100
-- Safety caps on what the server will emit, whatever the device data says.
Noise.MaxRange = 150
Noise.MaxVolume = 100

-- What a client sends to identify a fixed device (square coordinates) or a vehicle device.
function Noise.target(device)
    if instanceof(device, "VehiclePart") then
        local vehicle = device:getVehicle()
        if not vehicle then
            return nil
        end
        return { vehicleId = vehicle:getId(), partId = device:getId() }
    end

    local square = device.getSquare and device:getSquare()
    if not square then
        return nil
    end
    return { x = square:getX(), y = square:getY(), z = square:getZ() }
end
