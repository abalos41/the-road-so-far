TheRoadSoFarFMCassette = {
    MediaId = "TheRoadSoFarFM_DeansTop13ZeppTraxx",
    ItemType = "TheRoadSoFarFM.DeansTop13ZeppTraxx",
    Title = "Dean's Top 13 Zepp Traxx",
    Description = "It's a gift. You keep those.",
    InsertingSound = "TRSF_Cassette_Inserting",
    InsertingFile = "Extra/inserting-cassette.ogg",
    Tracks = {
        { Sound = "TRSF_Cassette_WholeLottaLove", File = "Whole Lotta Love.ogg" },
        { Sound = "TRSF_Cassette_StairwayToHeaven", File = "Stairway to Heaven.ogg" },
        { Sound = "TRSF_Cassette_RambleOn", File = "Ramble On.ogg" },
        { Sound = "TRSF_Cassette_RockAndRoll", File = "Rock and Roll.ogg" },
        { Sound = "TRSF_Cassette_ImmigrantSong", File = "Immigrant Song.ogg" },
        { Sound = "TRSF_Cassette_DazedAndConfused", File = "Dazed and Confused.ogg" },
        { Sound = "TRSF_Cassette_WhatIsAndWhatShouldNeverBe", File = "What Is and What Should Never Be.ogg" },
        { Sound = "TRSF_Cassette_WhenTheLeveeBreaks", File = "When the Levee Breaks.ogg" },
        { Sound = "TRSF_Cassette_GoodTimesBadTimes", File = "Good Times Bad Times.ogg" },
        { Sound = "TRSF_Cassette_BlackDog", File = "Black Dog.ogg" },
        { Sound = "TRSF_Cassette_GoingToCalifornia", File = "Going to California.ogg" },
        { Sound = "TRSF_Cassette_Kashmir", File = "Kashmir.ogg" },
        { Sound = "TRSF_Cassette_TheOcean", File = "The Ocean.ogg" },
    },
}

-- Stable id of a device holding the cassette, shared by clients and the server so both name
-- the same device the same way (portable radios keep their item id when placed in the world).
function TheRoadSoFarFMCassette.deviceId(device)
    if not device then
        return nil
    end

    if device.getID then
        local id = device:getID()
        if id ~= nil then
            return "item:" .. tostring(id)
        end
    end

    local modData = device.getModData and device:getModData()
    if modData and modData.RadioItemID then
        return "item:" .. tostring(modData.RadioItemID)
    end

    if instanceof(device, "VehiclePart") then
        local vehicle = device:getVehicle()
        if vehicle and vehicle.getMechanicalID then
            return "vehicle:" .. tostring(vehicle:getMechanicalID())
                .. ":" .. tostring(device:getId())
        end
    end

    local square = device.getSquare and device:getSquare()
    if square then
        local objectIndex = device.getObjectIndex and device:getObjectIndex() or 0
        return string.format(
            "world:%d:%d:%d:%d",
            square:getX(),
            square:getY(),
            square:getZ(),
            objectIndex
        )
    end
    return nil
end

function TheRoadSoFarFMCassette.onCreateItem(item)
    local radio = getZomboidRadio and getZomboidRadio()
    local recordedMedia = radio and radio:getRecordedMedia()
    local mediaData = recordedMedia and recordedMedia:getMediaData(TheRoadSoFarFMCassette.MediaId)
    if not mediaData then
        print("[TheRoadSoFarFM] Could not assign recorded media data to Dean's Top 13 Zepp Traxx.")
        return
    end

    item:setRecordedMediaData(mediaData)
end
