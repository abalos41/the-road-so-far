-- Overall volume of the mod's music (radio and cassette), set by the Sandbox option
-- VolumePercent. At the default of 100 nothing changes.
TheRoadSoFarFMVolume = TheRoadSoFarFMVolume or {}

function TheRoadSoFarFMVolume.scale()
    local options = SandboxVars and SandboxVars.TheRoadSoFarFM
    local percent = options and options.VolumePercent
    if type(percent) ~= "number" or percent ~= percent then
        return 1
    end
    return math.max(0, math.min(100, percent)) / 100
end
