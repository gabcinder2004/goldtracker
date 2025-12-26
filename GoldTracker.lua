-- GoldTracker: Gold trending chart addon for WoW 1.12.1
-- Tracks gold changes over time and displays a line chart

local GoldTracker = CreateFrame("Frame")
local dbReady = false
local mainFrame = nil
local chartFrame = nil
local statsFrame = nil
local lineTextures = {}
local dotTextures = {}
local gridLines = {}
local sessionStart = nil
local sessionStartGold = nil
local currentRange = "all"
local lastGold = nil
local yAxisLabels = {}
local xAxisLabels = {}
local chartDataPoints = {} -- Stores {x, y, gold, timestamp} for hover detection
local minimapButton = nil

-- Constants
local FRAME_WIDTH = 400
local FRAME_HEIGHT = 260
local CHART_PADDING_LEFT = 55
local CHART_PADDING_RIGHT = 15
local CHART_TOP_OFFSET = 35
local CHART_BOTTOM_OFFSET = 70
local CHART_WIDTH = FRAME_WIDTH - CHART_PADDING_LEFT - CHART_PADDING_RIGHT
local CHART_HEIGHT = FRAME_HEIGHT - CHART_TOP_OFFSET - CHART_BOTTOM_OFFSET

local COLORS = {
    background = {0, 0, 0, 0.75},
    border = {0.831, 0.627, 0.090, 0.8},  -- #D4A017
    line = {1, 0.843, 0, 1},              -- #FFD700
    grid = {1, 1, 1, 0.1},
    text = {1, 1, 1, 1},
    gold = {1, 0.843, 0, 1},
    silver = {0.75, 0.75, 0.75, 1},
    copper = {0.72, 0.45, 0.2, 1},
    positive = {0.2, 0.8, 0.2, 1},
    negative = {0.8, 0.2, 0.2, 1},
}

local RANGES = {
    {key = "session", label = "This Session"},
    {key = "1day", label = "Last Day"},
    {key = "3days", label = "Last 3 Days"},
    {key = "7days", label = "Last 7 Days"},
    {key = "30days", label = "Last 30 Days"},
    {key = "all", label = "All Time"},
}

-- Utility: Get character key
local function GetCharKey()
    local name = UnitName("player")
    local realm = GetRealmName()
    return name .. "-" .. realm
end

-- Utility: Format gold as Xg Ys Zc
local function FormatGold(copper)
    if not copper then return "0g 0s 0c" end
    local negative = copper < 0
    copper = math.abs(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor(math.mod(copper, 10000) / 100)
    local cop = math.mod(copper, 100)
    local str = ""
    if negative then str = "-" end
    str = str .. gold .. "g " .. silver .. "s " .. cop .. "c"
    return str
end

-- Utility: Format gold with colors
local function FormatGoldColored(copper)
    if not copper then return "0|cffffd7000g|r 0|cffbfbfbfs|r 0|cffb87333c|r" end
    local negative = copper < 0
    copper = math.abs(copper)
    local gold = math.floor(copper / 10000)
    local silver = math.floor(math.mod(copper, 10000) / 100)
    local cop = math.mod(copper, 100)
    local prefix = negative and "-" or ""
    return prefix .. "|cffffd700" .. gold .. "g|r |cffbfbfbf" .. silver .. "s|r |cffb87333" .. cop .. "c|r"
end

-- Utility: Format gold compactly for axis labels (with optional precision hint)
local function FormatGoldCompact(copper, showDetail)
    if not copper then return "0g" end
    if copper < 0 then copper = 0 end
    local gold = math.floor(copper / 10000)
    local silver = math.floor(math.mod(copper, 10000) / 100)
    local cop = math.mod(copper, 100)

    if gold >= 1000 then
        return string.format("%.1fk", gold / 1000)
    elseif gold > 0 then
        if showDetail then
            return gold .. "g" .. silver .. "s"
        else
            return gold .. "g"
        end
    elseif silver > 0 then
        return silver .. "s"
    else
        return cop .. "c"
    end
end

-- Utility: Format timestamp for axis labels (12h format with AM/PM)
local function FormatTimeLabel(timestamp, sameDay)
    local d = date("*t", timestamp)
    local hour = d.hour
    local ampm = "AM"
    if hour >= 12 then
        ampm = "PM"
        if hour > 12 then hour = hour - 12 end
    end
    if hour == 0 then hour = 12 end
    if sameDay then
        return string.format("%d:%02d %s", hour, d.min, ampm)
    else
        return string.format("%d/%d %d:%02d %s", d.month, d.day, hour, d.min, ampm)
    end
end

-- Utility: Format timestamp for tooltip (12h format with AM/PM)
local function FormatTooltipTime(timestamp)
    local d = date("*t", timestamp)
    local hour = d.hour
    local ampm = "AM"
    if hour >= 12 then
        ampm = "PM"
        if hour > 12 then hour = hour - 12 end
    end
    if hour == 0 then hour = 12 end
    return string.format("%d/%d %d:%02d %s", d.month, d.day, hour, d.min, ampm)
end

-- Check if two timestamps are on the same day
local function IsSameDay(t1, t2)
    local d1 = date("*t", t1)
    local d2 = date("*t", t2)
    return d1.year == d2.year and d1.month == d2.month and d1.day == d2.day
end

-- Data: Initialize character data
local function InitCharacterData()
    if not dbReady then return nil end
    local key = GetCharKey()
    if not GoldTrackerDB[key] then
        GoldTrackerDB[key] = {
            history = {},
            framePos = nil,
        }
    end
    return GoldTrackerDB[key]
end

-- Data: Record gold data point
local function RecordGold()
    local data = InitCharacterData()
    if not data then return end

    -- Skip recording while dead/ghost (GetMoney() returns 0 in spirit form)
    if UnitIsDeadOrGhost("player") then
        return
    end

    local currentGold = GetMoney()

    -- Skip if gold hasn't changed
    if lastGold and currentGold == lastGold then
        return
    end

    -- Skip recording 0 gold if we previously had non-zero gold (prevents logout bug)
    if currentGold == 0 and lastGold and lastGold > 0 then
        return
    end

    lastGold = currentGold

    table.insert(data.history, {
        timestamp = time(),
        gold = currentGold,
    })

    -- Update chart if visible
    if mainFrame and mainFrame:IsVisible() then
        GoldTracker:UpdateChart()
    end
end

-- Data: Get filtered history based on time range
local function GetFilteredHistory()
    local data = InitCharacterData()
    local history = data.history
    local now = time()
    local cutoff = 0

    if currentRange == "session" then
        cutoff = sessionStart or now
    elseif currentRange == "1day" then
        cutoff = now - (1 * 24 * 60 * 60)
    elseif currentRange == "3days" then
        cutoff = now - (3 * 24 * 60 * 60)
    elseif currentRange == "7days" then
        cutoff = now - (7 * 24 * 60 * 60)
    elseif currentRange == "30days" then
        cutoff = now - (30 * 24 * 60 * 60)
    else -- all
        cutoff = 0
    end

    local filtered = {}
    for i, entry in ipairs(history) do
        if entry.timestamp >= cutoff then
            table.insert(filtered, entry)
        end
    end

    return filtered
end

-- Chart: Draw line between two points using small segments
local lineSegmentIndex = 0
local lineSegments = {}

local function ClearLineSegments()
    for i, tex in ipairs(lineSegments) do
        tex:Hide()
    end
    lineSegmentIndex = 0
end

local function DrawLineSegment(x, y)
    lineSegmentIndex = lineSegmentIndex + 1
    local tex = lineSegments[lineSegmentIndex]
    if not tex then
        tex = chartFrame:CreateTexture(nil, "ARTWORK")
        tex:SetTexture("Interface\\Buttons\\WHITE8X8")
        tex:SetWidth(1.5)
        tex:SetHeight(1.5)
        lineSegments[lineSegmentIndex] = tex
    end
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", chartFrame, "BOTTOMLEFT", x, y)
    tex:SetVertexColor(COLORS.line[1], COLORS.line[2], COLORS.line[3], COLORS.line[4])
    tex:Show()
end

local function DrawLine(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)

    -- Draw overlapping segments for solid line appearance
    local steps = math.max(math.floor(length), 1)
    for i = 0, steps do
        local t = i / steps
        local x = x1 + dx * t
        local y = y1 + dy * t
        DrawLineSegment(x, y)
    end
end

-- Chart: Clear existing chart elements
local function ClearChart()
    for i, tex in ipairs(lineTextures) do
        tex:Hide()
    end
    for i, tex in ipairs(dotTextures) do
        tex:Hide()
    end
    ClearLineSegments()
end

-- Chart: Draw a dot at a point
local function DrawDot(x, y, index)
    local tex = dotTextures[index]
    if not tex then
        tex = chartFrame:CreateTexture(nil, "OVERLAY")
        tex:SetTexture("Interface\\Buttons\\WHITE8X8")
        tex:SetWidth(4)
        tex:SetHeight(4)
        dotTextures[index] = tex
    end

    tex:SetPoint("CENTER", chartFrame, "BOTTOMLEFT", x, y)
    tex:SetVertexColor(COLORS.line[1], COLORS.line[2], COLORS.line[3], COLORS.line[4])
    tex:Show()
end

-- Chart: Update and redraw chart
function GoldTracker:UpdateChart()
    if not chartFrame then return end

    ClearChart()

    -- Clear chart data points for hover
    for k in pairs(chartDataPoints) do
        chartDataPoints[k] = nil
    end

    local history = GetFilteredHistory()
    local count = table.getn(history)

    -- Always update stats first
    GoldTracker:UpdateStats(history)

    -- Handle case with 0 or 1 data point - show current gold as a dot
    if count < 2 then
        local currentGold = GetMoney()
        -- Draw a single dot in the center representing current gold
        DrawDot(CHART_WIDTH / 2, CHART_HEIGHT / 2, 1)

        -- Show Y-axis labels based on current gold (+/- 10% range)
        local baseGold = currentGold
        if count == 1 then
            baseGold = history[1].gold
        end
        local padding = math.max(baseGold * 0.1, 10000) -- At least 1g padding
        local minGold = baseGold - padding
        local maxGold = baseGold + padding
        local goldRange = maxGold - minGold
        local showDetail = goldRange < 10000
        local gridCount = 4

        for i = 0, gridCount do
            if yAxisLabels[i + 1] then
                local goldValue = minGold + (goldRange * (i / gridCount))
                yAxisLabels[i + 1]:SetText(FormatGoldCompact(goldValue, showDetail))
            end
        end

        -- Show X-axis with just "Now" for single point
        if xAxisLabels[1] then
            xAxisLabels[1]:SetText("")
        end
        if xAxisLabels[2] then
            xAxisLabels[2]:SetText("Now")
        end
        if xAxisLabels[3] then
            xAxisLabels[3]:SetText("")
        end

        -- Show hint text
        if not chartFrame.noDataText then
            chartFrame.noDataText = chartFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            chartFrame.noDataText:SetPoint("CENTER", chartFrame, "CENTER", 0, -20)
            chartFrame.noDataText:SetTextColor(0.5, 0.5, 0.5, 1)
        end
        chartFrame.noDataText:SetText("Tracking gold changes...")
        chartFrame.noDataText:Show()
        return
    end

    -- Hide the no data text if we have enough data
    if chartFrame.noDataText then
        chartFrame.noDataText:Hide()
    end

    -- Find min/max for scaling
    local minGold = history[1].gold
    local maxGold = history[1].gold
    local minTime = history[1].timestamp
    local maxTime = history[count].timestamp

    for i, entry in ipairs(history) do
        if entry.gold < minGold then minGold = entry.gold end
        if entry.gold > maxGold then maxGold = entry.gold end
    end

    -- Add padding to gold range
    local goldRange = maxGold - minGold
    if goldRange == 0 then goldRange = 1 end
    local padding = goldRange * 0.1
    minGold = minGold - padding
    maxGold = maxGold + padding
    goldRange = maxGold - minGold

    local timeRange = maxTime - minTime
    if timeRange == 0 then timeRange = 1 end

    -- Update Y-axis labels (5 labels: 0%, 25%, 50%, 75%, 100%)
    -- Show detail (silver) when range is less than 1 gold
    local showDetail = goldRange < 10000
    local gridCount = 4
    for i = 0, gridCount do
        if yAxisLabels[i + 1] then
            local goldValue = minGold + (goldRange * (i / gridCount))
            yAxisLabels[i + 1]:SetText(FormatGoldCompact(goldValue, showDetail))
        end
    end

    -- Update X-axis labels (start, middle, end)
    -- Show time if all data is from the same day, otherwise show date
    local sameDay = IsSameDay(minTime, maxTime)
    if xAxisLabels[1] then
        xAxisLabels[1]:SetText(FormatTimeLabel(minTime, sameDay))
    end
    if xAxisLabels[2] then
        local midTime = minTime + (timeRange / 2)
        xAxisLabels[2]:SetText(FormatTimeLabel(midTime, sameDay))
    end
    if xAxisLabels[3] then
        xAxisLabels[3]:SetText(FormatTimeLabel(maxTime, sameDay))
    end

    -- Draw lines between points and store data points for hover
    local maxPoints = 150 -- Limit points for performance
    local step = math.max(1, math.floor(count / maxPoints))
    local lastX, lastY = nil, nil
    local dataPointIndex = 0

    for i = 1, count, step do
        local entry = history[i]
        local x = ((entry.timestamp - minTime) / timeRange) * CHART_WIDTH
        local y = ((entry.gold - minGold) / goldRange) * CHART_HEIGHT

        -- Store data point for hover detection
        dataPointIndex = dataPointIndex + 1
        chartDataPoints[dataPointIndex] = {
            x = x,
            y = y,
            gold = entry.gold,
            timestamp = entry.timestamp
        }

        if lastX and lastY then
            DrawLine(lastX, lastY, x, y)
        end
        lastX, lastY = x, y
    end

    -- Make sure we include the last point
    if step > 1 and count > 0 then
        local entry = history[count]
        local x = ((entry.timestamp - minTime) / timeRange) * CHART_WIDTH
        local y = ((entry.gold - minGold) / goldRange) * CHART_HEIGHT

        -- Store the last data point for hover detection
        dataPointIndex = dataPointIndex + 1
        chartDataPoints[dataPointIndex] = {
            x = x,
            y = y,
            gold = entry.gold,
            timestamp = entry.timestamp
        }

        if lastX and lastY then
            DrawLine(lastX, lastY, x, y)
        end
    end
end

-- Stats: Update stats display
function GoldTracker:UpdateStats(history)
    if not statsFrame then return end

    local currentGold = GetMoney()
    local count = history and table.getn(history) or 0

    -- Calculate net change
    local netChange = 0
    if count > 0 then
        netChange = currentGold - history[1].gold
    end

    -- Calculate session change
    local sessionChange = 0
    if sessionStartGold then
        sessionChange = currentGold - sessionStartGold
    end

    -- Calculate gold per hour
    local goldPerHour = 0
    if sessionStart then
        local elapsed = time() - sessionStart
        if elapsed > 0 then
            goldPerHour = (sessionChange / elapsed) * 3600
        end
    end

    -- Update text
    local netColor = netChange >= 0 and "|cff33cc33" or "|cffcc3333"
    local sessionColor = sessionChange >= 0 and "|cff33cc33" or "|cffcc3333"
    local rateColor = goldPerHour >= 0 and "|cff33cc33" or "|cffcc3333"

    statsFrame.goldText:SetText("Gold: " .. FormatGoldColored(currentGold))
    statsFrame.sessionText:SetText("Session: " .. sessionColor .. FormatGold(sessionChange) .. "|r")
    statsFrame.netText:SetText("Net: " .. netColor .. FormatGold(netChange) .. "|r")
    statsFrame.rateText:SetText("Rate: " .. rateColor .. FormatGold(math.floor(goldPerHour)) .. "/hr|r")
end

-- Lightweight stats refresh (just rate, doesn't need history)
local function RefreshRateDisplay()
    if not statsFrame then return end

    local sessionChange = 0
    if sessionStartGold then
        sessionChange = GetMoney() - sessionStartGold
    end

    local goldPerHour = 0
    if sessionStart then
        local elapsed = time() - sessionStart
        if elapsed > 0 then
            goldPerHour = (sessionChange / elapsed) * 3600
        end
    end

    local rateColor = goldPerHour >= 0 and "|cff33cc33" or "|cffcc3333"
    statsFrame.rateText:SetText("Rate: " .. rateColor .. FormatGold(math.floor(goldPerHour)) .. "/hr|r")
end

-- UI: Create main frame
local function CreateMainFrame()
    if mainFrame then return mainFrame end

    -- Main window frame
    mainFrame = CreateFrame("Frame", "GoldTrackerFrame", UIParent)
    mainFrame:SetWidth(FRAME_WIDTH)
    mainFrame:SetHeight(FRAME_HEIGHT)
    mainFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    mainFrame:SetMovable(true)
    mainFrame:EnableMouse(true)
    mainFrame:SetClampedToScreen(true)
    mainFrame:SetFrameStrata("MEDIUM")

    -- Background
    mainFrame.bg = mainFrame:CreateTexture(nil, "BACKGROUND")
    mainFrame.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    mainFrame.bg:SetAllPoints()
    mainFrame.bg:SetVertexColor(COLORS.background[1], COLORS.background[2], COLORS.background[3], COLORS.background[4])

    -- Border
    local borderSize = 1
    local borders = {}
    for i = 1, 4 do
        borders[i] = mainFrame:CreateTexture(nil, "BORDER")
        borders[i]:SetTexture("Interface\\Buttons\\WHITE8X8")
        borders[i]:SetVertexColor(COLORS.border[1], COLORS.border[2], COLORS.border[3], COLORS.border[4])
    end
    borders[1]:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, 0)
    borders[1]:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, 0)
    borders[1]:SetHeight(borderSize)
    borders[2]:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, 0)
    borders[2]:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
    borders[2]:SetHeight(borderSize)
    borders[3]:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, 0)
    borders[3]:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", 0, 0)
    borders[3]:SetWidth(borderSize)
    borders[4]:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, 0)
    borders[4]:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", 0, 0)
    borders[4]:SetWidth(borderSize)

    -- Title bar (draggable)
    local titleBar = CreateFrame("Frame", nil, mainFrame)
    titleBar:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, 0)
    titleBar:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, 0)
    titleBar:SetHeight(25)
    titleBar:EnableMouse(true)
    titleBar:RegisterForDrag("LeftButton")
    titleBar:SetScript("OnDragStart", function() mainFrame:StartMoving() end)
    titleBar:SetScript("OnDragStop", function()
        mainFrame:StopMovingOrSizing()
        local data = InitCharacterData()
        local point, _, relPoint, x, y = mainFrame:GetPoint()
        data.framePos = {point, relPoint, x, y}
    end)

    -- Title text
    local title = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -7)
    title:SetText("GoldTracker")
    title:SetTextColor(COLORS.text[1], COLORS.text[2], COLORS.text[3])

    -- Close button
    local closeBtn = CreateFrame("Button", nil, mainFrame, "UIPanelCloseButton")
    closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 1, 1)
    closeBtn:SetFrameStrata("HIGH")
    closeBtn:SetFrameLevel(mainFrame:GetFrameLevel() + 10)
    closeBtn:SetScript("OnClick", function() mainFrame:Hide() end)

    -- Dropdown for time range
    local dropdown = CreateFrame("Frame", "GoldTrackerDropdown", mainFrame, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -25, -3)
    UIDropDownMenu_SetWidth(100, dropdown)

    local function DropdownInit()
        for i, range in ipairs(RANGES) do
            local info = {}
            local rangeKey = range.key
            local rangeLabel = range.label
            info.text = rangeLabel
            info.value = rangeKey
            info.func = function()
                currentRange = rangeKey
                GoldTrackerDropdownText:SetText(rangeLabel)
                GoldTracker:UpdateChart()
            end
            info.checked = (currentRange == rangeKey)
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(dropdown, DropdownInit)

    -- Set initial dropdown text
    GoldTrackerDropdownText:SetText("All Time")

    -- Chart frame (inner area for chart)
    chartFrame = CreateFrame("Frame", nil, mainFrame)
    chartFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", CHART_PADDING_LEFT, -CHART_TOP_OFFSET)
    chartFrame:SetWidth(CHART_WIDTH)
    chartFrame:SetHeight(CHART_HEIGHT)

    -- Chart background (slightly darker)
    local chartBg = chartFrame:CreateTexture(nil, "BACKGROUND")
    chartBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    chartBg:SetAllPoints()
    chartBg:SetVertexColor(0.05, 0.05, 0.05, 0.5)

    -- Enable mouse for hover tooltip
    chartFrame:EnableMouse(true)
    chartFrame.isHovering = false

    -- Hover highlight dot
    chartFrame.hoverDot = chartFrame:CreateTexture(nil, "OVERLAY")
    chartFrame.hoverDot:SetTexture("Interface\\Buttons\\WHITE8X8")
    chartFrame.hoverDot:SetWidth(6)
    chartFrame.hoverDot:SetHeight(6)
    chartFrame.hoverDot:SetVertexColor(1, 1, 1, 1)
    chartFrame.hoverDot:Hide()

    chartFrame:SetScript("OnEnter", function()
        this.isHovering = true
    end)

    chartFrame:SetScript("OnLeave", function()
        this.isHovering = false
        GameTooltip:Hide()
        this.hoverDot:Hide()
    end)

    chartFrame:SetScript("OnUpdate", function()
        if not this.isHovering then return end
        if table.getn(chartDataPoints) == 0 then return end

        -- Get mouse position relative to chartFrame
        local mouseX, mouseY = GetCursorPosition()
        local scale = this:GetEffectiveScale()
        mouseX = mouseX / scale
        mouseY = mouseY / scale

        local frameLeft = this:GetLeft()
        local frameBottom = this:GetBottom()
        local relX = mouseX - frameLeft
        local relY = mouseY - frameBottom

        -- Find the nearest data point
        local nearestDist = 99999
        local nearestPoint = nil
        for i = 1, table.getn(chartDataPoints) do
            local point = chartDataPoints[i]
            local dx = point.x - relX
            local dy = point.y - relY
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < nearestDist then
                nearestDist = dist
                nearestPoint = point
            end
        end

        -- Show tooltip if within 30 pixels of a data point
        if nearestPoint and nearestDist < 30 then
            -- Position the hover dot
            this.hoverDot:ClearAllPoints()
            this.hoverDot:SetPoint("CENTER", this, "BOTTOMLEFT", nearestPoint.x, nearestPoint.y)
            this.hoverDot:Show()

            -- Show tooltip
            GameTooltip:SetOwner(this, "ANCHOR_CURSOR")
            GameTooltip:ClearLines()
            GameTooltip:AddLine(FormatGold(nearestPoint.gold), COLORS.gold[1], COLORS.gold[2], COLORS.gold[3])
            GameTooltip:AddLine(FormatTooltipTime(nearestPoint.timestamp), 0.7, 0.7, 0.7)
            GameTooltip:Show()
        else
            GameTooltip:Hide()
            this.hoverDot:Hide()
        end
    end)

    -- Draw subtle grid lines and Y-axis labels
    local gridCount = 4
    for i = 0, gridCount do
        -- Grid line (skip bottom line at i=0)
        if i > 0 then
            local gridLine = chartFrame:CreateTexture(nil, "ARTWORK")
            gridLine:SetTexture("Interface\\Buttons\\WHITE8X8")
            gridLine:SetHeight(1)
            gridLine:SetPoint("LEFT", chartFrame, "BOTTOMLEFT", 0, (CHART_HEIGHT / gridCount) * i)
            gridLine:SetPoint("RIGHT", chartFrame, "BOTTOMRIGHT", 0, (CHART_HEIGHT / gridCount) * i)
            gridLine:SetVertexColor(COLORS.grid[1], COLORS.grid[2], COLORS.grid[3], COLORS.grid[4])
            table.insert(gridLines, gridLine)
        end

        -- Y-axis label
        local yLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        yLabel:SetPoint("RIGHT", chartFrame, "BOTTOMLEFT", -5, (CHART_HEIGHT / gridCount) * i)
        yLabel:SetTextColor(0.6, 0.6, 0.6, 1)
        yLabel:SetText("")
        table.insert(yAxisLabels, yLabel)
    end

    -- X-axis labels (start, middle, end)
    for i = 1, 3 do
        local xLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        local xPos = 0
        if i == 1 then
            xLabel:SetPoint("TOPLEFT", chartFrame, "BOTTOMLEFT", 0, -3)
        elseif i == 2 then
            xLabel:SetPoint("TOP", chartFrame, "BOTTOM", 0, -3)
        else
            xLabel:SetPoint("TOPRIGHT", chartFrame, "BOTTOMRIGHT", 0, -3)
        end
        xLabel:SetTextColor(0.6, 0.6, 0.6, 1)
        xLabel:SetText("")
        table.insert(xAxisLabels, xLabel)
    end

    -- Stats frame
    statsFrame = CreateFrame("Frame", nil, mainFrame)
    statsFrame:SetPoint("BOTTOMLEFT", mainFrame, "BOTTOMLEFT", CHART_PADDING_LEFT, 8)
    statsFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -CHART_PADDING_RIGHT, 8)
    statsFrame:SetHeight(32)

    -- Stats text elements (two rows)
    statsFrame.goldText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.goldText:SetPoint("TOPLEFT", statsFrame, "TOPLEFT", 0, 0)
    statsFrame.goldText:SetText("Gold: 0g 0s 0c")

    statsFrame.sessionText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.sessionText:SetPoint("TOPRIGHT", statsFrame, "TOPRIGHT", 0, 0)
    statsFrame.sessionText:SetText("Session: +0g 0s 0c")

    statsFrame.netText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.netText:SetPoint("BOTTOMLEFT", statsFrame, "BOTTOMLEFT", 0, 0)
    statsFrame.netText:SetText("Net: +0g 0s 0c")

    statsFrame.rateText = statsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statsFrame.rateText:SetPoint("BOTTOMRIGHT", statsFrame, "BOTTOMRIGHT", 0, 0)
    statsFrame.rateText:SetText("Rate: 0g 0s 0c/hr")

    -- Timer for live rate updates (every 2 seconds when visible)
    local updateTimer = 0
    mainFrame:SetScript("OnUpdate", function()
        updateTimer = updateTimer + arg1
        if updateTimer >= 2 then
            updateTimer = 0
            RefreshRateDisplay()
        end
    end)

    mainFrame:Hide()
    return mainFrame
end

-- Toggle main window
local function ToggleWindow()
    if not mainFrame then
        CreateMainFrame()
    end

    if mainFrame:IsVisible() then
        mainFrame:Hide()
    else
        -- Restore position
        local data = InitCharacterData()
        if data.framePos then
            mainFrame:ClearAllPoints()
            mainFrame:SetPoint(data.framePos[1], UIParent, data.framePos[2], data.framePos[3], data.framePos[4])
        end
        mainFrame:Show()
        GoldTracker:UpdateChart()
    end
end

-- Minimap button (pfUI compatible)
local function CreateMinimapButton()
    if minimapButton then return end

    -- Create button as child of Minimap so pfUI can detect and manage it
    minimapButton = CreateFrame("Button", "GoldTrackerMinimapButton", Minimap)
    minimapButton:SetWidth(32)
    minimapButton:SetHeight(32)
    minimapButton:SetFrameStrata("MEDIUM")
    minimapButton:SetFrameLevel(10)

    -- Icon (gold coin)
    local icon = minimapButton:CreateTexture(nil, "ARTWORK")
    icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_01")
    icon:SetWidth(20)
    icon:SetHeight(20)
    icon:SetPoint("CENTER", 0, 0)

    -- Border (standard minimap button border)
    local border = minimapButton:CreateTexture(nil, "OVERLAY")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetWidth(53)
    border:SetHeight(53)
    border:SetPoint("TOPLEFT", 0, 0)

    -- Highlight
    minimapButton:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    -- Load saved position or use default
    local data = InitCharacterData()
    local angle = data.minimapPos or 220 -- Default angle (bottom-left area)
    local radius = 80

    -- Position on minimap edge
    local x = math.cos(math.rad(angle)) * radius
    local y = math.sin(math.rad(angle)) * radius
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)

    -- Click handler
    minimapButton:SetScript("OnClick", function()
        ToggleWindow()
    end)

    -- Dragging to reposition around minimap
    minimapButton:RegisterForDrag("LeftButton")
    minimapButton:SetMovable(true)

    minimapButton:SetScript("OnDragStart", function()
        this:LockHighlight()
        this:SetScript("OnUpdate", function()
            local xpos, ypos = GetCursorPosition()
            local xmin, ymin = Minimap:GetLeft(), Minimap:GetBottom()

            xpos = xmin - xpos / Minimap:GetEffectiveScale() + 70
            ypos = ypos / Minimap:GetEffectiveScale() - ymin - 70

            local newAngle = math.deg(math.atan2(ypos, xpos))
            local newX = math.cos(math.rad(newAngle)) * radius
            local newY = math.sin(math.rad(newAngle)) * radius

            this:ClearAllPoints()
            this:SetPoint("CENTER", Minimap, "CENTER", newX, newY)

            -- Save position
            local charData = InitCharacterData()
            if charData then
                charData.minimapPos = newAngle
            end
        end)
    end)

    minimapButton:SetScript("OnDragStop", function()
        this:UnlockHighlight()
        this:SetScript("OnUpdate", nil)
    end)

    -- Tooltip
    minimapButton:SetScript("OnEnter", function()
        GameTooltip:SetOwner(this, "ANCHOR_LEFT")
        GameTooltip:SetText("|cffffd700GoldTracker|r", 1, 1, 1)
        GameTooltip:AddLine("Left-click to toggle window", 0.2, 1, 0.2)
        GameTooltip:AddLine("Drag to move button", 0.2, 1, 0.2)
        GameTooltip:Show()
    end)

    minimapButton:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    minimapButton:Show()
end

-- Event handling
GoldTracker:RegisterEvent("VARIABLES_LOADED")
GoldTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
GoldTracker:RegisterEvent("PLAYER_MONEY")

GoldTracker:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        -- Initialize SavedVariables
        if not GoldTrackerDB then
            GoldTrackerDB = {}
        end
        dbReady = true

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Initialize session
        sessionStart = time()
        sessionStartGold = GetMoney()

        -- Initialize data and record starting point (lastGold is nil so first point will record)
        InitCharacterData()
        RecordGold()

        -- Create minimap button
        CreateMinimapButton()

        DEFAULT_CHAT_FRAME:AddMessage("|cffffd700GoldTracker|r loaded. Use |cff00ff00/gt|r or |cff00ff00/goldtracker|r to toggle.")

    elseif event == "PLAYER_MONEY" then
        RecordGold()
    end
end)

-- Slash commands
SLASH_GOLDTRACKER1 = "/goldtracker"
SLASH_GOLDTRACKER2 = "/gt"
SlashCmdList["GOLDTRACKER"] = function(msg)
    ToggleWindow()
end
