-- Multiplayer-only late-join synchronisation settings. Singleplayer never reads these.
TheRoadSoFarFMSync = TheRoadSoFarFMSync or {}

local Sync = TheRoadSoFarFMSync

-- A listener who joins this early into a track simply starts it from the beginning.
Sync.StartThresholdMs = 5000
-- Other listeners closer than this (tiles) make a late joiner wait for the next track.
Sync.NearbyRadius = 60
-- The server advances this long after the nominal track end, so clients can finish naturally.
Sync.AdvanceMarginMs = 400
Sync.ListenerHeartbeatMs = 8000
Sync.ListenerTimeoutMs = 25000
-- A client stops an out-of-step (offset) track it cannot hear for this long and re-joins on return.
Sync.SilentStopMs = 5000

Sync.CueEarlyMs = 250
Sync.CueMinRemainingMs = 1500
Sync.FillerFadeMs = 1000
Sync.FillerGain = 0.6
Sync.CueGain = 0.8
-- Cassette late joiners start the current track from 0 (offset) and fade it out over this
-- long, finishing just as the rewind sound starts.
Sync.OffsetFadeMs = 6000

-- Radio: late joiners hear tuning sounds and edits alternately (tuning first) while they wait,
-- followed by the shortest tuning sound as the sync cue. Cassette: the existing rewind sound.
Sync.Sounds = {
    radio = {
        tunings = {
            "TRSF_MP_Tuning_1",
            "TRSF_MP_Tuning_2",
            "TRSF_MP_Tuning_3",
        },
        edits = {
            "TRSF_MP_Edit_AirTonight",
            "TRSF_MP_Edit_BurningHeart",
            "TRSF_MP_Edit_Mmmbop",
            "TRSF_MP_Edit_Smokin",
            "TRSF_MP_Edit_Renegade",
            "TRSF_MP_Edit_TheTrooper",
            "TRSF_MP_Edit_SoloMarkKnopfler",
        },
    },
    cassette = {
        rewind = "TRSF_Rewind",
    },
}

function Sync.durationMs(soundName)
    local durations = TheRoadSoFarFMDurations
    local value = durations and durations[soundName]
    if type(value) == "number" and value > 0 then
        return value
    end
    return nil
end

function Sync.isValidMs(value)
    return type(value) == "number" and value == value
        and value >= 0 and value <= 36000000
end

-- Every sound name used by the sync feature, for the pre-map warm-up.
function Sync.allSoundNames()
    local names = {}
    for _, group in pairs(Sync.Sounds) do
        for _, entry in pairs(group) do
            if type(entry) == "table" then
                for _, soundName in ipairs(entry) do
                    names[#names + 1] = soundName
                end
            else
                names[#names + 1] = entry
            end
        end
    end
    return names
end

-- The radio sync cue is the shortest tuning sound.
function Sync.radioCue()
    local bestSound, bestMs
    for _, soundName in ipairs(Sync.Sounds.radio.tunings) do
        local ms = Sync.durationMs(soundName)
        if ms and (not bestMs or ms < bestMs) then
            bestSound, bestMs = soundName, ms
        end
    end
    return bestSound, bestMs
end

local function randomIndex(limit)
    if ZombRand then
        return ZombRand(limit) + 1
    end
    return math.random(limit)
end

-- A bag hands out every sound of a list once, in random order, before any repeats; the
-- sound that ended one round is never the first of the next.
function Sync.newBag(list)
    return { list = list, pool = {}, last = nil }
end

-- Takes one sound from the bag. Sounds that end before availableMs are preferred so they
-- are not cut off by the cue; if none does, any remaining sound is used.
function Sync.bagTake(bag, availableMs)
    if #bag.pool == 0 then
        for _, soundName in ipairs(bag.list) do
            bag.pool[#bag.pool + 1] = soundName
        end
        if #bag.list > 1 and bag.last then
            for i, soundName in ipairs(bag.pool) do
                if soundName == bag.last then
                    table.remove(bag.pool, i)
                    bag.excluded = soundName
                    break
                end
            end
        end
    end

    local candidates = {}
    for i, soundName in ipairs(bag.pool) do
        local ms = Sync.durationMs(soundName)
        if not availableMs or (ms and ms <= availableMs) then
            candidates[#candidates + 1] = i
        end
    end
    if #candidates == 0 then
        for i = 1, #bag.pool do
            candidates[#candidates + 1] = i
        end
    end
    if #candidates == 0 then
        return nil
    end

    local index = candidates[randomIndex(#candidates)]
    local soundName = table.remove(bag.pool, index)
    if bag.excluded then
        -- The sound held back at the start of the round is available again for later turns.
        bag.pool[#bag.pool + 1] = bag.excluded
        bag.excluded = nil
    end
    bag.last = soundName
    return soundName
end
