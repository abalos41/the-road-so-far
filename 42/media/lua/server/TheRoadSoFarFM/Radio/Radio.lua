local function registerTheRoadSoFarFM(scriptManager)
    local roadSoFarChannel = DynamicRadioChannel.new(
        "The Road So Far FM",
        99600,
        ChannelCategory.Radio,
        "TRSF-099600"
    )
    scriptManager:AddChannel(roadSoFarChannel, false)

    if isServer and isServer() then
        return
    end

    local userTracksConfig = TheRoadSoFarFMUserTracksConfig
    if not userTracksConfig or type(userTracksConfig.Tracks) ~= "table"
        or #userTracksConfig.Tracks == 0 then
        return
    end

    local userTracksChannel = DynamicRadioChannel.new(
        "User Tracks FM",
        100200,
        ChannelCategory.Radio,
        "TRSF-100200"
    )
    scriptManager:AddChannel(userTracksChannel, false)
end

Events.OnLoadRadioScripts.Add(registerTheRoadSoFarFM)
