local function registerTheRoadSoFarFM(scriptManager)
    local channel = DynamicRadioChannel.new(
        "The Road So Far FM",
        99600,
        ChannelCategory.Radio,
        "TRSF-099600"
    )
    scriptManager:AddChannel(channel, false)
end

Events.OnLoadRadioScripts.Add(registerTheRoadSoFarFM)
