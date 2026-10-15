local MODULE = "TheRoadSoFarFM"
local RADIO_FREQUENCY = 99600

-- registry[kind][id][onlineId] = { x, y, seenAt }
local registry = { radio = {}, cassette = {} }

local Listeners = {}
TheRoadSoFarFMListeners = Listeners

local function validDeviceId(value)
    return type(value) == "string"
        and #value > 0
        and #value <= 64
        and value:match("^[%w_:%-%.]+$") ~= nil
end

local function validTarget(kind, id)
    if kind == "radio" then
        return id == RADIO_FREQUENCY
    end
    return kind == "cassette" and validDeviceId(id)
end

-- The game's Lua has no global next(), so emptiness is checked with pairs().
local function isEmpty(group)
    for _ in pairs(group) do
        return false
    end
    return true
end

local function prune(group, now)
    local timeout = TheRoadSoFarFMSync.ListenerTimeoutMs
    for onlineId, entry in pairs(group) do
        if now - entry.seenAt > timeout then
            group[onlineId] = nil
        end
    end
end

function Listeners.touch(kind, id, player)
    local group = registry[kind][id]
    if not group then
        group = {}
        registry[kind][id] = group
    end
    group[player:getOnlineID()] = {
        x = player:getX(),
        y = player:getY(),
        seenAt = getTimestampMs(),
    }
end

function Listeners.remove(kind, id, player)
    local group = registry[kind][id]
    if group then
        group[player:getOnlineID()] = nil
        if isEmpty(group) then
            registry[kind][id] = nil
        end
    end
end

-- Returns whether any other player is listening, and whether one is within hearing distance.
function Listeners.summary(kind, id, player)
    local group = registry[kind][id]
    if not group then
        return false, false
    end

    prune(group, getTimestampMs())
    local ownId = player:getOnlineID()
    local px, py = player:getX(), player:getY()
    local radius = TheRoadSoFarFMSync.NearbyRadius
    local anyOther, nearby = false, false
    for onlineId, entry in pairs(group) do
        if onlineId ~= ownId then
            anyOther = true
            local dx, dy = entry.x - px, entry.y - py
            if dx * dx + dy * dy <= radius * radius then
                nearby = true
                break
            end
        end
    end
    return anyOther, nearby
end

function Listeners.hasAny(kind, id)
    local group = registry[kind][id]
    if not group then
        return false
    end
    prune(group, getTimestampMs())
    return not isEmpty(group)
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or type(args) ~= "table" or not player then
        return
    end
    if command ~= "listenHeartbeat" and command ~= "listenStop" then
        return
    end
    if not validTarget(args.kind, args.id) then
        return
    end

    if command == "listenHeartbeat" then
        Listeners.touch(args.kind, args.id, player)
    else
        Listeners.remove(args.kind, args.id, player)
    end
end

local function pruneAll()
    local now = getTimestampMs()
    for _, groups in pairs(registry) do
        for id, group in pairs(groups) do
            prune(group, now)
            if isEmpty(group) then
                groups[id] = nil
            end
        end
    end
end

Events.OnClientCommand.Add(onClientCommand)
Events.EveryOneMinute.Add(pruneAll)
