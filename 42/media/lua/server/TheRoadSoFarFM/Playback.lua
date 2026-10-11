local MODULE = "TheRoadSoFarFM"
local activeRadios = {}

local function sendPlayback(player, key, state, broadcast)
    local args = {
        key = key,
        sound = state.sound,
        kind = state.kind,
        version = state.version,
        welcome = state.welcome == true,
    }
    if state.kind == "song" then
        args.title = TheRoadSoFarFMConfig.TrackTitles
            and TheRoadSoFarFMConfig.TrackTitles[state.sound]
    end
    if broadcast then
        sendServerCommand(MODULE, "play", args)
    else
        sendServerCommand(player, MODULE, "play", args)
    end
end

local function onClientCommand(module, command, player, args)
    if module ~= MODULE or not args or type(args.key) ~= "string" or #args.key > 128 then
        return
    end

    local key = args.key
    if command == "requestStart" then
        local state = activeRadios[key]
        if not state then
            state = TheRoadSoFarFMPlaylist.createState()
            activeRadios[key] = state
            sendPlayback(nil, key, state, true)
        else
            sendPlayback(player, key, state, false)
        end
    elseif command == "requestAdvance" then
        local state = activeRadios[key]
        if state and type(args.version) == "number" and args.version == state.version then
            TheRoadSoFarFMPlaylist.advance(state)
            sendPlayback(nil, key, state, true)
        end
    elseif command == "debugCommercial" then
        local state = activeRadios[key]
        if state and type(args.version) == "number" and args.version == state.version then
            TheRoadSoFarFMPlaylist.forceCommercial(state)
            sendPlayback(nil, key, state, true)
        end
    elseif command == "requestStop" and activeRadios[key] then
        activeRadios[key] = nil
        sendServerCommand(MODULE, "stop", { key = key })
    end
end

Events.OnClientCommand.Add(onClientCommand)
