require "ISUI/ISLiteratureUI"

-- The cassette's recording has no text lines, so the Learning resources window could never
-- list it. Its media category (see RecordedMedia/TheRoadSoFarFM.lua) would still add an
-- always empty tab, which is removed here.
local HIDDEN_MEDIA_CATEGORY = "cdS"

if ISLiteratureUI and not ISLiteratureUI.TheRoadSoFarFMTabHooked then
    local originalCreateChildren = ISLiteratureUI.createChildren

    ISLiteratureUI.createChildren = function(self)
        originalCreateChildren(self)

        local radio = getZomboidRadio and getZomboidRadio()
        local recordedMedia = radio and radio:getRecordedMedia()
        local categories = recordedMedia and recordedMedia:getCategories()
        if not categories or not self.tabs or not self.listboxMedia then
            return
        end

        for i = 1, categories:size() do
            local list = self.listboxMedia[i]
            if categories:get(i - 1) == HIDDEN_MEDIA_CATEGORY and list then
                self.tabs:removeView(list)
            end
        end
    end

    ISLiteratureUI.TheRoadSoFarFMTabHooked = true
end
