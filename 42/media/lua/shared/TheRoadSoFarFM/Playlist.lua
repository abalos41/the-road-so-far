TheRoadSoFarFMPlaylist = TheRoadSoFarFMPlaylist or {}
TheRoadSoFarFMConfig = TheRoadSoFarFMConfig or {}

local function randomIndex(limit)
    if ZombRand then
        return ZombRand(limit) + 1
    end
    return math.random(limit)
end

local function configuredTracks(config)
    local tracks = {}
    local seen = {}
    local configuredList = config and config.Tracks or TheRoadSoFarFMConfig.Tracks or {}
    for _, track in ipairs(configuredList) do
        if not seen[track] then
            tracks[#tracks + 1] = track
            seen[track] = true
        end
    end
    return tracks
end

local function shuffledTracks(previousTrack, config)
    local tracks = configuredTracks(config)

    for i = #tracks, 2, -1 do
        local j = randomIndex(i)
        tracks[i], tracks[j] = tracks[j], tracks[i]
    end

    if #tracks > 1 and tracks[1] == previousTrack then
        tracks[1], tracks[2] = tracks[2], tracks[1]
    end
    return tracks
end

local function nextSong(state, config)
    if state.trackIndex > #state.tracks then
        state.tracks = shuffledTracks(state.lastTrack, config)
        state.trackIndex = 1
    end

    state.sound = state.tracks[state.trackIndex]
    state.lastTrack = state.sound
    state.trackIndex = state.trackIndex + 1
    state.kind = "song"
end

local function welcomeHasPlayed()
    if not ModData or not ModData.getOrCreate then
        error("[TheRoadSoFarFM] Global mod data is unavailable.")
    end

    local data = ModData.getOrCreate("TheRoadSoFarFM")
    return data.welcomeMessageVersion == 2
end

local function markWelcomePlayed()
    local data = ModData.getOrCreate("TheRoadSoFarFM")
    data.welcomeMessageVersion = 2
    if isServer and isServer() and ModData.transmit then
        ModData.transmit("TheRoadSoFarFM")
    end
end

function TheRoadSoFarFMPlaylist.createState(config)
    local tracks = configuredTracks(config)
    if #tracks == 0 then
        error("[TheRoadSoFarFM] Playlist has no tracks.")
    end

    local playWelcome = not welcomeHasPlayed()
    local shuffled = shuffledTracks(nil, config)
    if playWelcome then
        markWelcomePlayed()
        for i = #shuffled, 1, -1 do
            if shuffled[i] == "TRSF_KansasCarryOnWaywardSon" then
                table.remove(shuffled, i)
            end
        end
    end

    local state = {
        tracks = shuffled,
        trackIndex = 1,
        songsSinceCommercial = 0,
        commercialPlayed = false,
        version = 1,
        lastTrack = nil,
        config = config,
        welcome = playWelcome,
    }
    if playWelcome then
        state.sound = "TRSF_KansasCarryOnWaywardSon"
        state.lastTrack = state.sound
        state.kind = "song"
    else
        nextSong(state, config)
    end
    return state
end

function TheRoadSoFarFMPlaylist.advance(state, config)
    config = config or state.config
    local songsBeforeCommercial = config and config.SongsBeforeCommercial
        or TheRoadSoFarFMConfig.SongsBeforeCommercial
    local initialChancePercent = config and config.InitialCommercialChancePercent
        or config and config.CommercialChancePercent
        or TheRoadSoFarFMConfig.InitialCommercialChancePercent
        or TheRoadSoFarFMConfig.CommercialChancePercent
    local repeatChancePercent = config and config.RepeatCommercialChancePercent
        or TheRoadSoFarFMConfig.RepeatCommercialChancePercent
        or 10
    local commercial = config and config.Commercial or TheRoadSoFarFMConfig.Commercial
    local rewind = config and config.Rewind or TheRoadSoFarFMConfig.Rewind

    state.welcome = false
    if state.kind == "commercial" then
        state.sound = rewind
        state.kind = "rewind"
    elseif state.kind == "rewind" then
        state.songsSinceCommercial = 0
        nextSong(state, config)
    else
        state.songsSinceCommercial = state.songsSinceCommercial + 1
        if state.songsSinceCommercial >= songsBeforeCommercial then
            state.songsSinceCommercial = 0
            local chancePercent = state.commercialPlayed
                and repeatChancePercent
                or initialChancePercent
            if randomIndex(100) <= chancePercent then
                state.sound = commercial
                state.kind = "commercial"
                state.commercialPlayed = true
            else
                nextSong(state, config)
            end
        else
            nextSong(state, config)
        end
    end

    state.version = state.version + 1
    return state
end

function TheRoadSoFarFMPlaylist.forceCommercial(state, config)
    config = config or state.config
    state.sound = config and config.Commercial or TheRoadSoFarFMConfig.Commercial
    state.kind = "commercial"
    state.welcome = false
    state.songsSinceCommercial = 0
    state.commercialPlayed = true
    state.version = state.version + 1
    return state
end
