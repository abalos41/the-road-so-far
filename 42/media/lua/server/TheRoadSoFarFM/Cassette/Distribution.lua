-- Adds Dean's Top 13 Zepp Traxx as rare loot to the glove box of every vehicle type.
-- The value is the item weight of a glove box roll: it is roughly the percentage of
-- glove boxes that hold the cassette (0.2 = about 1 in 500), before the Sandbox loot
-- rarity settings are applied.
--
-- The item script must not declare MediaCategory: the loot picker would replace the
-- cassette's recording with a random CD of that category. OnCreate assigns the right one.
local CASSETTE_ITEM_TYPE = "TheRoadSoFarFM.DeansTop13ZeppTraxx"
local GLOVE_BOX_WEIGHT = 0.2

local patchedGloveBoxes = {}

local function addToGloveBox(gloveBox)
    if type(gloveBox) ~= "table" or patchedGloveBoxes[gloveBox] then
        return 0
    end
    patchedGloveBoxes[gloveBox] = true

    if type(gloveBox.items) ~= "table" then
        gloveBox.items = {}
    end
    table.insert(gloveBox.items, CASSETTE_ITEM_TYPE)
    table.insert(gloveBox.items, GLOVE_BOX_WEIGHT)
    return 1
end

-- Vehicle types share glove box tables, so each table is patched only once.
local function addCassetteToVehicleGloveBoxes()
    local vehicles = VehicleDistributions and VehicleDistributions[1]
    if type(vehicles) ~= "table" then
        print("[TheRoadSoFarFM] Vehicle distributions not found; the cassette will not spawn in glove boxes.")
        return
    end

    local patched = 0
    for _, vehicle in pairs(vehicles) do
        if type(vehicle) == "table" then
            if type(vehicle.Normal) == "table" then
                patched = patched + addToGloveBox(vehicle.Normal.GloveBox)
            end
            if type(vehicle.Specific) == "table" then
                for _, specific in ipairs(vehicle.Specific) do
                    if type(specific) == "table" then
                        patched = patched + addToGloveBox(specific.GloveBox)
                    end
                end
            end
        end
    end

    print(string.format("[TheRoadSoFarFM] Cassette added to %d glove box tables at weight %s.", patched, tostring(GLOVE_BOX_WEIGHT)))
end

Events.OnPostDistributionMerge.Add(addCassetteToVehicleGloveBoxes)
