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
local currentTab = "chart"  -- "chart" or "transactions"
local transactionContext = nil  -- Current context for source detection
local activeFilters = {}  -- Which sources are visible
local currentPage = 1
local transactionsFrame = nil
local tabButtons = {}
local lastGold = nil
local yAxisLabels = {}
local xAxisLabels = {}
local chartDataPoints = {} -- Stores {x, y, gold, timestamp} for hover detection
local minimapButton = nil

-- Constants
local FRAME_WIDTH = 400
local FRAME_HEIGHT = 280  -- Increased for tabs
local CHART_PADDING_LEFT = 55
local CHART_PADDING_RIGHT = 15
local CHART_TOP_OFFSET = 55  -- Increased for tab bar
local CHART_BOTTOM_OFFSET = 70
local CHART_WIDTH = FRAME_WIDTH - CHART_PADDING_LEFT - CHART_PADDING_RIGHT
local CHART_HEIGHT = FRAME_HEIGHT - CHART_TOP_OFFSET - CHART_BOTTOM_OFFSET
local TAB_BAR_HEIGHT = 22

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

local SOURCES = {
    {key = "all", label = "All", icon = "Interface\\Buttons\\UI-CheckBox-Check"},
    {key = "loot", label = "Loot", icon = "Interface\\Icons\\INV_Misc_Coin_17"},
    {key = "vendor", label = "Vendor", icon = "Interface\\Icons\\INV_Misc_Bag_10"},
    {key = "auction", label = "Auction", icon = "Interface\\Icons\\INV_Hammer_15"},
    {key = "mail", label = "Mail", icon = "Interface\\Icons\\INV_Letter_15"},
    {key = "trade", label = "Trade", icon = "Interface\\Icons\\INV_Misc_Note_01"},
    {key = "quest", label = "Quest", icon = "Interface\\Icons\\INV_Misc_Note_05"},
    {key = "training", label = "Training", icon = "Interface\\Icons\\INV_Misc_Book_07"},
    {key = "repair", label = "Repair", icon = "Interface\\Icons\\Trade_BlackSmithing"},
    {key = "unknown", label = "Unknown", icon = "Interface\\Icons\\INV_Misc_QuestionMark"},
    {key = "historical", label = "Historical", icon = "Interface\\Icons\\INV_Misc_PocketWatch_01"},
}

local TRANSACTIONS_PER_PAGE = 10

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

-- Utility: Format timestamp for axis labels based on time range
local function FormatTimeLabel(timestamp, sameDay, timeRange)
    local d = date("*t", timestamp)
    local hour = d.hour
    local ampm = "AM"
    if hour >= 12 then
        ampm = "PM"
        if hour > 12 then hour = hour - 12 end
    end
    if hour == 0 then hour = 12 end

    -- For short ranges (< 3 hours), show hour:min
    if timeRange and timeRange < 3 * 60 * 60 then
        if sameDay then
            return string.format("%d:%02d %s", hour, d.min, ampm)
        else
            return string.format("%d/%d %d:%02d %s", d.month, d.day, hour, d.min, ampm)
        end
    else
        -- For longer ranges, just show the hour
        if sameDay then
            return string.format("%d %s", hour, ampm)
        else
            return string.format("%d/%d %d %s", d.month, d.day, hour, ampm)
        end
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
            transactions = {},
            framePos = nil,
        }
    end

    -- Migrate historical data to transactions if needed
    local data = GoldTrackerDB[key]
    if not data.transactions then
        data.transactions = {}
        -- Generate transactions from history deltas
        local history = data.history
        if history and table.getn(history) > 1 then
            for i = 2, table.getn(history) do
                local prev = history[i - 1]
                local curr = history[i]
                local delta = curr.gold - prev.gold
                if delta ~= 0 then
                    table.insert(data.transactions, {
                        timestamp = curr.timestamp,
                        amount = delta,
                        source = "historical",
                        balance = curr.gold,
                    })
                end
            end
        end
    end

    return data
end

-- Transaction: Record a gold transaction with source
local function RecordTransaction(amount, source)
    local data = InitCharacterData()
    if not data then return end

    if not data.transactions then
        data.transactions = {}
    end

    local balance = GetMoney()

    table.insert(data.transactions, {
        timestamp = time(),
        amount = amount,
        source = source or "unknown",
        balance = balance,
    })
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

-- Transactions: Get filtered transaction list
function GoldTracker:GetFilteredTransactions()
    local data = InitCharacterData()
    if not data or not data.transactions then return {} end

    local now = time()
    local cutoff = 0

    -- Apply time range filter (same as chart)
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
    else
        cutoff = 0
    end

    local filtered = {}
    for i = table.getn(data.transactions), 1, -1 do  -- Reverse order (newest first)
        local tx = data.transactions[i]
        if tx.timestamp >= cutoff and activeFilters[tx.source] then
            table.insert(filtered, tx)
        end
    end

    return filtered
end

-- Transactions: Format time for table display
local function FormatTableTime(timestamp)
    local d = date("*t", timestamp)
    local hour = d.hour
    local ampm = "a"
    if hour >= 12 then
        ampm = "p"
        if hour > 12 then hour = hour - 12 end
    end
    if hour == 0 then hour = 12 end
    return string.format("%d/%d %d:%02d%s", d.month, d.day, hour, d.min, ampm)
end

-- Transactions: Update the transaction list display
function GoldTracker:UpdateTransactionList()
    if not transactionsFrame then return end

    local filtered = self:GetFilteredTransactions()
    local totalCount = table.getn(filtered)
    local totalPages = math.max(1, math.ceil(totalCount / TRANSACTIONS_PER_PAGE))

    -- Clamp current page
    if currentPage > totalPages then currentPage = totalPages end
    if currentPage < 1 then currentPage = 1 end

    -- Update page text
    transactionsFrame.pageText:SetText("Page " .. currentPage .. " of " .. totalPages)

    -- Update button states
    if currentPage <= 1 then
        transactionsFrame.prevBtn.text:SetTextColor(0.4, 0.4, 0.4, 1)
    else
        transactionsFrame.prevBtn.text:SetTextColor(1, 1, 1, 1)
    end

    if currentPage >= totalPages then
        transactionsFrame.nextBtn.text:SetTextColor(0.4, 0.4, 0.4, 1)
    else
        transactionsFrame.nextBtn.text:SetTextColor(1, 1, 1, 1)
    end

    -- Calculate page range
    local startIdx = ((currentPage - 1) * TRANSACTIONS_PER_PAGE) + 1
    local endIdx = math.min(startIdx + TRANSACTIONS_PER_PAGE - 1, totalCount)

    -- Populate rows
    for i = 1, TRANSACTIONS_PER_PAGE do
        local row = transactionsFrame.rows[i]
        local txIdx = startIdx + i - 1

        if txIdx <= totalCount then
            local tx = filtered[txIdx]

            -- Time
            row.time:SetText(FormatTableTime(tx.timestamp))

            -- Amount (colored)
            local amountStr = FormatGold(math.abs(tx.amount))
            if tx.amount >= 0 then
                row.amount:SetText("+" .. amountStr)
                row.amount:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)
            else
                row.amount:SetText("-" .. amountStr)
                row.amount:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)
            end

            -- Source (capitalize first letter)
            local sourceText = tx.source
            sourceText = string.upper(string.sub(sourceText, 1, 1)) .. string.sub(sourceText, 2)
            row.source:SetText(sourceText)

            -- Balance
            row.balance:SetText(FormatGoldCompact(tx.balance, false))
            row.balance:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], 1)

            row:Show()
        else
            row:Hide()
        end
    end
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
        xAxisLabels[1]:SetText(FormatTimeLabel(minTime, sameDay, timeRange))
    end
    if xAxisLabels[2] then
        local midTime = minTime + (timeRange / 2)
        xAxisLabels[2]:SetText(FormatTimeLabel(midTime, sameDay, timeRange))
    end
    if xAxisLabels[3] then
        xAxisLabels[3]:SetText(FormatTimeLabel(maxTime, sameDay, timeRange))
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


-- UI: Create a tab button
local function CreateTabButton(parent, text, tabKey, xOffset)
    local tab = CreateFrame("Button", nil, parent)
    tab:SetWidth(80)
    tab:SetHeight(22)
    tab:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, -25)

    -- Background
    tab.bg = tab:CreateTexture(nil, "BACKGROUND")
    tab.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    tab.bg:SetAllPoints()
    tab.bg:SetVertexColor(0.1, 0.1, 0.1, 0.8)

    -- Border (bottom is open for active tab)
    tab.borders = {}
    -- Top
    tab.borders[1] = tab:CreateTexture(nil, "BORDER")
    tab.borders[1]:SetTexture("Interface\\Buttons\\WHITE8X8")
    tab.borders[1]:SetHeight(1)
    tab.borders[1]:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, 0)
    tab.borders[1]:SetPoint("TOPRIGHT", tab, "TOPRIGHT", 0, 0)
    -- Left
    tab.borders[2] = tab:CreateTexture(nil, "BORDER")
    tab.borders[2]:SetTexture("Interface\\Buttons\\WHITE8X8")
    tab.borders[2]:SetWidth(1)
    tab.borders[2]:SetPoint("TOPLEFT", tab, "TOPLEFT", 0, 0)
    tab.borders[2]:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
    -- Right
    tab.borders[3] = tab:CreateTexture(nil, "BORDER")
    tab.borders[3]:SetTexture("Interface\\Buttons\\WHITE8X8")
    tab.borders[3]:SetWidth(1)
    tab.borders[3]:SetPoint("TOPRIGHT", tab, "TOPRIGHT", 0, 0)
    tab.borders[3]:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)
    -- Bottom (only shown when inactive)
    tab.borders[4] = tab:CreateTexture(nil, "BORDER")
    tab.borders[4]:SetTexture("Interface\\Buttons\\WHITE8X8")
    tab.borders[4]:SetHeight(1)
    tab.borders[4]:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 0, 0)
    tab.borders[4]:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", 0, 0)

    -- Text
    tab.text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tab.text:SetPoint("CENTER", tab, "CENTER", 0, 0)
    tab.text:SetText(text)

    tab.tabKey = tabKey

    -- Set visual state
    tab.SetActive = function(self, active)
        if active then
            self.bg:SetVertexColor(0, 0, 0, 0.75)
            self.borders[4]:Hide()
            for i = 1, 3 do
                self.borders[i]:SetVertexColor(COLORS.border[1], COLORS.border[2], COLORS.border[3], 1)
            end
            self.text:SetTextColor(1, 0.843, 0, 1)
        else
            self.bg:SetVertexColor(0.05, 0.05, 0.05, 0.8)
            self.borders[4]:Show()
            for i = 1, 4 do
                self.borders[i]:SetVertexColor(0.4, 0.4, 0.4, 0.8)
            end
            self.text:SetTextColor(0.6, 0.6, 0.6, 1)
        end
    end

    return tab
end

-- UI: Switch between tabs
local function SwitchTab(tabKey)
    currentTab = tabKey

    -- Update tab visuals
    for key, tab in pairs(tabButtons) do
        tab:SetActive(key == tabKey)
    end

    -- Show/hide content
    if chartFrame then
        if tabKey == "chart" then
            chartFrame:Show()
            if statsFrame then statsFrame:Show() end
        else
            chartFrame:Hide()
            if statsFrame then statsFrame:Hide() end
        end
    end

    if transactionsFrame then
        if tabKey == "transactions" then
            transactionsFrame:Show()
            GoldTracker:UpdateTransactionList()
        else
            transactionsFrame:Hide()
        end
    end
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
                currentPage = 1  -- Reset to first page
                GoldTracker:UpdateChart()
                if transactionsFrame and transactionsFrame:IsVisible() then
                    GoldTracker:UpdateTransactionList()
                end
            end
            info.checked = (currentRange == rangeKey)
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(dropdown, DropdownInit)

    -- Set initial dropdown text
    GoldTrackerDropdownText:SetText("All Time")

    -- Tab bar separator line
    local tabSeparator = mainFrame:CreateTexture(nil, "ARTWORK")
    tabSeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
    tabSeparator:SetHeight(1)
    tabSeparator:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -25 - TAB_BAR_HEIGHT)
    tabSeparator:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -25 - TAB_BAR_HEIGHT)
    tabSeparator:SetVertexColor(COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.5)

    -- Tab buttons
    tabButtons.chart = CreateTabButton(mainFrame, "Chart", "chart", 10)
    tabButtons.transactions = CreateTabButton(mainFrame, "Transactions", "transactions", 92)

    -- Tab click handlers
    tabButtons.chart:SetScript("OnClick", function()
        SwitchTab("chart")
    end)
    tabButtons.transactions:SetScript("OnClick", function()
        SwitchTab("transactions")
    end)

    -- Set initial tab state
    tabButtons.chart:SetActive(true)
    tabButtons.transactions:SetActive(false)

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

    -- X-axis labels (start, middle, end) with tick marks
    for i = 1, 3 do
        -- Tick mark
        local tick = chartFrame:CreateTexture(nil, "OVERLAY")
        tick:SetTexture("Interface\\Buttons\\WHITE8X8")
        tick:SetWidth(1)
        tick:SetHeight(5)
        tick:SetVertexColor(0.6, 0.6, 0.6, 1)
        if i == 1 then
            tick:SetPoint("TOPLEFT", chartFrame, "BOTTOMLEFT", 0, 0)
        elseif i == 2 then
            tick:SetPoint("TOP", chartFrame, "BOTTOM", 0, 0)
        else
            tick:SetPoint("TOPRIGHT", chartFrame, "BOTTOMRIGHT", 0, 0)
        end

        -- Label
        local xLabel = mainFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        if i == 1 then
            xLabel:SetPoint("TOPLEFT", chartFrame, "BOTTOMLEFT", 0, -6)
        elseif i == 2 then
            xLabel:SetPoint("TOP", chartFrame, "BOTTOM", 0, -6)
        else
            xLabel:SetPoint("TOPRIGHT", chartFrame, "BOTTOMRIGHT", 0, -6)
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

    -- Transactions frame (hidden by default)
    transactionsFrame = CreateFrame("Frame", nil, mainFrame)
    transactionsFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -CHART_TOP_OFFSET)
    transactionsFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 8)
    transactionsFrame:Hide()

    -- Filter bar container
    transactionsFrame.filterBar = CreateFrame("Frame", nil, transactionsFrame)
    transactionsFrame.filterBar:SetPoint("TOPLEFT", transactionsFrame, "TOPLEFT", 0, 0)
    transactionsFrame.filterBar:SetPoint("TOPRIGHT", transactionsFrame, "TOPRIGHT", 0, 0)
    transactionsFrame.filterBar:SetHeight(28)

    -- Create filter toggle buttons
    transactionsFrame.filterButtons = {}
    local filterBtnSize = 24
    local filterSpacing = 4

    for i, source in ipairs(SOURCES) do
        local btn = CreateFrame("Button", nil, transactionsFrame.filterBar)
        btn:SetWidth(filterBtnSize)
        btn:SetHeight(filterBtnSize)
        btn:SetPoint("TOPLEFT", transactionsFrame.filterBar, "TOPLEFT", (i - 1) * (filterBtnSize + filterSpacing), -2)

        -- Icon
        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetTexture(source.icon)
        btn.icon:SetPoint("CENTER", 0, 0)
        btn.icon:SetWidth(filterBtnSize - 4)
        btn.icon:SetHeight(filterBtnSize - 4)

        btn.sourceKey = source.key
        btn.sourceLabel = source.label  -- Store label for tooltip

        -- Update visual state
        btn.UpdateState = function(self)
            if self.sourceKey == "all" then
                -- All button is highlighted if all filters are active
                local allActive = true
                for key, active in pairs(activeFilters) do
                    if not active then allActive = false break end
                end
                if allActive then
                    self.icon:SetVertexColor(1, 0.843, 0, 1)
                else
                    self.icon:SetVertexColor(0.4, 0.4, 0.4, 1)
                end
            else
                if activeFilters[self.sourceKey] then
                    self.icon:SetVertexColor(1, 1, 1, 1)
                else
                    self.icon:SetVertexColor(0.3, 0.3, 0.3, 1)
                end
            end
        end

        btn:SetScript("OnClick", function()
            if this.sourceKey == "all" then
                -- Toggle all filters
                local allActive = true
                for key, active in pairs(activeFilters) do
                    if not active then allActive = false break end
                end
                for j, s in ipairs(SOURCES) do
                    if s.key ~= "all" then
                        activeFilters[s.key] = not allActive
                    end
                end
            else
                activeFilters[this.sourceKey] = not activeFilters[this.sourceKey]
            end

            -- Update all button states
            for key, filterBtn in pairs(transactionsFrame.filterButtons) do
                filterBtn:UpdateState()
            end

            -- Reset to page 1 and refresh
            currentPage = 1
            GoldTracker:UpdateTransactionList()
        end)

        btn:SetScript("OnEnter", function()
            GameTooltip:SetOwner(this, "ANCHOR_BOTTOM")
            GameTooltip:SetText(this.sourceLabel, 1, 1, 1)
            GameTooltip:Show()
        end)

        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        transactionsFrame.filterButtons[source.key] = btn
        btn:UpdateState()
    end

    -- Table container
    transactionsFrame.tableFrame = CreateFrame("Frame", nil, transactionsFrame)
    transactionsFrame.tableFrame:SetPoint("TOPLEFT", transactionsFrame.filterBar, "BOTTOMLEFT", 0, -4)
    transactionsFrame.tableFrame:SetPoint("BOTTOMRIGHT", transactionsFrame, "BOTTOMRIGHT", 0, 24)

    -- Table background
    local tableBg = transactionsFrame.tableFrame:CreateTexture(nil, "BACKGROUND")
    tableBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    tableBg:SetAllPoints()
    tableBg:SetVertexColor(0.05, 0.05, 0.05, 0.5)

    -- Table column headers
    local headerY = 0
    local colWidths = {90, 85, 70, 85}  -- Time, Amount, Source, Balance
    local colNames = {"Time", "Amount", "Source", "Balance"}
    local colPositions = {0, 90, 175, 245}

    transactionsFrame.headers = {}
    for i, name in ipairs(colNames) do
        local header = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        header:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[i], 0)
        header:SetWidth(colWidths[i])
        header:SetJustifyH("LEFT")
        header:SetText(name)
        header:SetTextColor(0.8, 0.8, 0.8, 1)
        transactionsFrame.headers[i] = header
    end

    -- Header underline
    local headerLine = transactionsFrame.tableFrame:CreateTexture(nil, "ARTWORK")
    headerLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerLine:SetHeight(1)
    headerLine:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", 0, -14)
    headerLine:SetPoint("TOPRIGHT", transactionsFrame.tableFrame, "TOPRIGHT", 0, -14)
    headerLine:SetVertexColor(0.3, 0.3, 0.3, 1)

    -- Create row frames
    transactionsFrame.rows = {}
    local rowHeight = 14
    local rowStartY = -18

    for i = 1, TRANSACTIONS_PER_PAGE do
        local row = {}
        local y = rowStartY - ((i - 1) * rowHeight)

        -- Time column
        row.time = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.time:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[1], y)
        row.time:SetWidth(colWidths[1])
        row.time:SetJustifyH("LEFT")
        row.time:SetTextColor(0.7, 0.7, 0.7, 1)

        -- Amount column
        row.amount = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.amount:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[2], y)
        row.amount:SetWidth(colWidths[2])
        row.amount:SetJustifyH("LEFT")

        -- Source column
        row.source = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.source:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[3], y)
        row.source:SetWidth(colWidths[3])
        row.source:SetJustifyH("LEFT")
        row.source:SetTextColor(0.6, 0.6, 0.6, 1)

        -- Balance column
        row.balance = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.balance:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[4], y)
        row.balance:SetWidth(colWidths[4])
        row.balance:SetJustifyH("LEFT")

        row.Show = function(self)
            self.time:Show()
            self.amount:Show()
            self.source:Show()
            self.balance:Show()
        end

        row.Hide = function(self)
            self.time:Hide()
            self.amount:Hide()
            self.source:Hide()
            self.balance:Hide()
        end

        transactionsFrame.rows[i] = row
    end
    -- Pagination container
    transactionsFrame.pagination = CreateFrame("Frame", nil, transactionsFrame)
    transactionsFrame.pagination:SetPoint("BOTTOMLEFT", transactionsFrame, "BOTTOMLEFT", 0, 0)
    transactionsFrame.pagination:SetPoint("BOTTOMRIGHT", transactionsFrame, "BOTTOMRIGHT", 0, 0)
    transactionsFrame.pagination:SetHeight(20)

    -- Pagination: Page indicator
    transactionsFrame.pageText = transactionsFrame.pagination:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    transactionsFrame.pageText:SetPoint("LEFT", transactionsFrame.pagination, "LEFT", 0, 0)
    transactionsFrame.pageText:SetTextColor(0.7, 0.7, 0.7, 1)
    transactionsFrame.pageText:SetText("Page 1 of 1")

    -- Pagination: Next button
    transactionsFrame.nextBtn = CreateFrame("Button", nil, transactionsFrame.pagination)
    transactionsFrame.nextBtn:SetWidth(50)
    transactionsFrame.nextBtn:SetHeight(18)
    transactionsFrame.nextBtn:SetPoint("RIGHT", transactionsFrame.pagination, "RIGHT", 0, 0)

    transactionsFrame.nextBtn.text = transactionsFrame.nextBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    transactionsFrame.nextBtn.text:SetPoint("CENTER", 0, 0)
    transactionsFrame.nextBtn.text:SetText("Next >")

    transactionsFrame.nextBtn:SetScript("OnClick", function()
        local data = InitCharacterData()
        if not data or not data.transactions then return end
        local filtered = GoldTracker:GetFilteredTransactions()
        local totalPages = math.ceil(table.getn(filtered) / TRANSACTIONS_PER_PAGE)
        if currentPage < totalPages then
            currentPage = currentPage + 1
            GoldTracker:UpdateTransactionList()
        end
    end)

    transactionsFrame.nextBtn:SetScript("OnEnter", function()
        this.text:SetTextColor(1, 0.843, 0, 1)
    end)

    transactionsFrame.nextBtn:SetScript("OnLeave", function()
        this.text:SetTextColor(1, 1, 1, 1)
    end)

    -- Pagination: Prev button
    transactionsFrame.prevBtn = CreateFrame("Button", nil, transactionsFrame.pagination)
    transactionsFrame.prevBtn:SetWidth(50)
    transactionsFrame.prevBtn:SetHeight(18)
    transactionsFrame.prevBtn:SetPoint("RIGHT", transactionsFrame.nextBtn, "LEFT", -10, 0)

    transactionsFrame.prevBtn.text = transactionsFrame.prevBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    transactionsFrame.prevBtn.text:SetPoint("CENTER", 0, 0)
    transactionsFrame.prevBtn.text:SetText("< Prev")

    transactionsFrame.prevBtn:SetScript("OnClick", function()
        if currentPage > 1 then
            currentPage = currentPage - 1
            GoldTracker:UpdateTransactionList()
        end
    end)

    transactionsFrame.prevBtn:SetScript("OnEnter", function()
        this.text:SetTextColor(1, 0.843, 0, 1)
    end)

    transactionsFrame.prevBtn:SetScript("OnLeave", function()
        this.text:SetTextColor(1, 1, 1, 1)
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

-- Check if player has any damaged gear (for repair detection)
local function HasDamagedGear()
    for slot = 1, 18 do
        local hasItem, _, repairCost = GameTooltip:SetInventoryItem("player", slot)
        if repairCost and repairCost > 0 then
            return true
        end
    end
    return false
end

-- Event handling
GoldTracker:RegisterEvent("VARIABLES_LOADED")
GoldTracker:RegisterEvent("PLAYER_ENTERING_WORLD")
GoldTracker:RegisterEvent("PLAYER_MONEY")
-- Context tracking events
GoldTracker:RegisterEvent("MERCHANT_SHOW")
GoldTracker:RegisterEvent("MERCHANT_CLOSED")
GoldTracker:RegisterEvent("AUCTION_HOUSE_SHOW")
GoldTracker:RegisterEvent("AUCTION_HOUSE_CLOSED")
GoldTracker:RegisterEvent("MAIL_SHOW")
GoldTracker:RegisterEvent("MAIL_CLOSED")
GoldTracker:RegisterEvent("TRADE_SHOW")
GoldTracker:RegisterEvent("TRADE_CLOSED")
GoldTracker:RegisterEvent("TRAINER_SHOW")
GoldTracker:RegisterEvent("TRAINER_CLOSED")
GoldTracker:RegisterEvent("QUEST_COMPLETE")
GoldTracker:RegisterEvent("CHAT_MSG_MONEY")

GoldTracker:SetScript("OnEvent", function()
    if event == "VARIABLES_LOADED" then
        -- Initialize SavedVariables
        if not GoldTrackerDB then
            GoldTrackerDB = {}
        end
        dbReady = true

        -- Initialize active filters (all enabled by default)
        for i, source in ipairs(SOURCES) do
            if source.key ~= "all" then
                activeFilters[source.key] = true
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Initialize session
        sessionStart = time()
        sessionStartGold = GetMoney()

        -- Initialize data and record starting point
        InitCharacterData()
        RecordGold()

        -- Create minimap button
        CreateMinimapButton()

        DEFAULT_CHAT_FRAME:AddMessage("|cffffd700GoldTracker|r loaded. Use |cff00ff00/gt|r or |cff00ff00/goldtracker|r to toggle.")

    elseif event == "PLAYER_MONEY" then
        local currentGold = GetMoney()
        local delta = 0
        if lastGold then
            delta = currentGold - lastGold
        end

        -- Record transaction with context
        if delta ~= 0 then
            local source = transactionContext or "unknown"

            -- Detect repair vs vendor
            if source == "vendor" and delta < 0 then
                -- Could be repair - we'll mark as vendor since we can't reliably detect
                source = "vendor"
            end

            RecordTransaction(delta, source)
        end

        RecordGold()

    -- Context tracking
    elseif event == "MERCHANT_SHOW" then
        transactionContext = "vendor"
    elseif event == "MERCHANT_CLOSED" then
        transactionContext = nil
    elseif event == "AUCTION_HOUSE_SHOW" then
        transactionContext = "auction"
    elseif event == "AUCTION_HOUSE_CLOSED" then
        transactionContext = nil
    elseif event == "MAIL_SHOW" then
        transactionContext = "mail"
    elseif event == "MAIL_CLOSED" then
        transactionContext = nil
    elseif event == "TRADE_SHOW" then
        transactionContext = "trade"
    elseif event == "TRADE_CLOSED" then
        transactionContext = nil
    elseif event == "TRAINER_SHOW" then
        transactionContext = "training"
    elseif event == "TRAINER_CLOSED" then
        transactionContext = nil
    elseif event == "QUEST_COMPLETE" then
        transactionContext = "quest"
        -- Clear quest context after 2 seconds (reward comes on button click)
        if not GoldTracker.questTimer then
            GoldTracker.questTimer = CreateFrame("Frame")
        end
        GoldTracker.questTimer.elapsed = 0
        GoldTracker.questTimer:SetScript("OnUpdate", function()
            this.elapsed = this.elapsed + arg1
            if this.elapsed > 2 then
                if transactionContext == "quest" then
                    transactionContext = nil
                end
                this:SetScript("OnUpdate", nil)
            end
        end)
    elseif event == "CHAT_MSG_MONEY" then
        transactionContext = "loot"
        -- Clear loot context after short delay
        if not GoldTracker.lootTimer then
            GoldTracker.lootTimer = CreateFrame("Frame")
        end
        GoldTracker.lootTimer.elapsed = 0
        GoldTracker.lootTimer:SetScript("OnUpdate", function()
            this.elapsed = this.elapsed + arg1
            if this.elapsed > 0.5 then
                if transactionContext == "loot" then
                    transactionContext = nil
                end
                this:SetScript("OnUpdate", nil)
            end
        end)
    end
end)

-- Slash commands
SLASH_GOLDTRACKER1 = "/goldtracker"
SLASH_GOLDTRACKER2 = "/gt"
SlashCmdList["GOLDTRACKER"] = function(msg)
    ToggleWindow()
end
