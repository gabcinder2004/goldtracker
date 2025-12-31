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
local currentRange = "1day"
local currentTab = "chart"  -- "chart" or "transactions"
local transactionContext = nil  -- Current context for source detection
local transactionDetail = nil   -- Detail info (NPC name, player name, etc.)
local currentMailSender = nil   -- Captured when mail is opened
local currentMailIsAuction = false  -- Flag for auction house mail
local currentMailSubject = nil  -- Subject line for extracting item names
local originalTakeInboxMoney = nil  -- For hooking TakeInboxMoney
local originalPlaceAuctionBid = nil  -- For hooking auction purchases
local pendingAuctionItem = nil  -- Item name of pending auction purchase/bid
local pendingMailQueue = {}  -- Queue for tracking mail when using "Open All" feature
local MAIL_DEBUG = false  -- Toggle with /gt debug
local originalRepairAllItems = nil  -- For hooking RepairAllItems
local pendingRepair = false         -- Flag to track if repair was just initiated
local activeFilters = {}  -- Which sources are visible
local currentPage = 1
local detailFilter = nil  -- Filter by specific detail text (player name, item name, etc.)
local transactionsFrame = nil
local statisticsFrame = nil
local tabButtons = {}
local SwitchTab  -- Forward declaration (defined later)
local lastGold = nil
local yAxisLabels = {}
local xAxisLabels = {}
local chartDataPoints = {} -- Stores {x, y, gold, timestamp} for hover detection
local minimapButton = nil
local miniFrame = nil
local miniLineTextures = {}
local isMinimized = false
local miniViewMode = "chart"  -- "chart" or "transactions"

-- Constants
local FRAME_WIDTH = 550
local FRAME_HEIGHT = 400
local MINI_WIDTH = 200
local MINI_HEIGHT = 85
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
    fill = {1, 0.843, 0, 1},              -- Gold/yellow (alpha controlled by gradient)
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
    {key = "loot", label = "Loot", icon = "Interface\\Icons\\INV_Misc_Coin_02"},
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

local TRANSACTIONS_PER_PAGE = 18

local RANGES = {
    {key = "session", label = "This Session"},
    {key = "6hours", label = "Last 6 Hours"},
    {key = "12hours", label = "Last 12 Hours"},
    {key = "1day", label = "Last Day"},
    {key = "3days", label = "Last 3 Days"},
    {key = "7days", label = "Last 7 Days"},
    {key = "30days", label = "Last 30 Days"},
    {key = "all", label = "All Time"},
}

-- Debug logging function for mail tracking
local function MailDebug(msg)
    if MAIL_DEBUG then
        DEFAULT_CHAT_FRAME:AddMessage("|cff888888[GT Mail Debug]|r " .. msg)
    end
end

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

-- Utility: Find a "nice" step size for Y-axis labels
-- Returns a clean interval like 10c, 25c, 50c, 1s, 5s, 10s, 25s, 50s, 1g, 2g, 5g, 10g, etc.
local function GetNiceStep(rawStep)
    -- Nice intervals in copper: 10c, 25c, 50c, 1s, 2s, 5s, 10s, 25s, 50s, 1g, 2g, 5g, 10g, 25g, 50g, 100g...
    local niceSteps = {
        10, 25, 50,                          -- copper
        100, 200, 500,                       -- 1s, 2s, 5s
        1000, 2500, 5000,                    -- 10s, 25s, 50s
        10000, 20000, 50000,                 -- 1g, 2g, 5g
        100000, 250000, 500000,              -- 10g, 25g, 50g
        1000000, 2500000, 5000000,           -- 100g, 250g, 500g
        10000000, 25000000, 50000000,        -- 1000g, 2500g, 5000g
    }

    for i, step in ipairs(niceSteps) do
        if step >= rawStep then
            return step
        end
    end
    -- For very large ranges, round to nearest 1000g multiple
    return math.ceil(rawStep / 10000000) * 10000000
end

-- Utility: Calculate nice Y-axis bounds and step
-- Returns: niceMin, niceMax, niceStep
local function GetNiceAxisBounds(minVal, maxVal, numSteps)
    local range = maxVal - minVal
    if range == 0 then range = 10000 end -- Default to 1g range

    local rawStep = range / numSteps
    local niceStep = GetNiceStep(rawStep)

    -- Snap min down and max up to nice step multiples
    local niceMin = math.floor(minVal / niceStep) * niceStep
    local niceMax = math.ceil(maxVal / niceStep) * niceStep

    -- Ensure we have at least numSteps intervals
    while (niceMax - niceMin) / niceStep < numSteps do
        niceMax = niceMax + niceStep
    end

    return niceMin, niceMax, niceStep
end

-- Utility: Format gold compactly for axis labels
-- niceStep: the interval between labels (used to determine precision)
local function FormatGoldCompact(copper, niceStep)
    if not copper then return "0g" end
    if copper < 0 then copper = 0 end
    local gold = math.floor(copper / 10000)
    local silver = math.floor(math.mod(copper, 10000) / 100)
    local cop = math.mod(copper, 100)

    -- Determine precision based on nice step size
    local showSilver = niceStep and niceStep < 10000
    local showCopper = niceStep and niceStep < 100

    if gold >= 1000 then
        return string.format("%.1fk", gold / 1000)
    elseif gold > 0 then
        if showCopper then
            return gold .. "g" .. silver .. "s" .. cop .. "c"
        elseif showSilver then
            return gold .. "g" .. silver .. "s"
        else
            return gold .. "g"
        end
    elseif silver > 0 then
        if showCopper then
            return silver .. "s" .. cop .. "c"
        else
            return silver .. "s"
        end
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

-- Transaction: Record a gold transaction with source and detail
local function RecordTransaction(amount, source, detail)
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
        detail = detail,
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

    -- Update mini view if visible
    if miniFrame and miniFrame:IsVisible() then
        if miniViewMode == "transactions" then
            GoldTracker:UpdateMiniTransactions()
        else
            GoldTracker:UpdateMiniChart()
        end
    end

    -- Update transaction list if visible
    if transactionsFrame and transactionsFrame:IsVisible() then
        GoldTracker:UpdateTransactionList()
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
    elseif currentRange == "6hours" then
        cutoff = now - (6 * 60 * 60)
    elseif currentRange == "12hours" then
        cutoff = now - (12 * 60 * 60)
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
    elseif currentRange == "6hours" then
        cutoff = now - (6 * 60 * 60)
    elseif currentRange == "12hours" then
        cutoff = now - (12 * 60 * 60)
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
            -- Apply detail filter if set
            if detailFilter then
                if tx.detail and tx.detail == detailFilter then
                    table.insert(filtered, tx)
                end
            else
                table.insert(filtered, tx)
            end
        end
    end

    return filtered
end

-- Analytics: Get time range cutoff based on currentRange
local function GetRangeCutoff()
    local now = time()
    local cutoff = 0

    if currentRange == "session" then
        cutoff = sessionStart or now
    elseif currentRange == "6hours" then
        cutoff = now - (6 * 60 * 60)
    elseif currentRange == "12hours" then
        cutoff = now - (12 * 60 * 60)
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

    return cutoff
end

-- Analytics: Calculate all statistics for the statistics tab
function GoldTracker:CalculateStatistics()
    local data = InitCharacterData()
    if not data or not data.transactions then
        return nil
    end

    local cutoff = GetRangeCutoff()
    local stats = {
        -- Summary cards
        peakGold = 0,
        peakGoldTimestamp = 0,
        totalIn = 0,
        totalInCount = 0,
        totalOut = 0,
        totalOutCount = 0,
        bestDay = nil,
        bestDayTotal = 0,
        bestPeriod = nil,
        bestPeriodTotal = 0,

        -- Source breakdown
        incomeBySource = {},
        expenseBySource = {},

        -- Top trade partners
        tradePartners = {},

        -- Top auction items
        auctionItems = {},

        -- Earning patterns
        byDayOfWeek = {},  -- 1=Sunday, 7=Saturday
        byHourOfDay = {},  -- 0-23
    }

    -- Initialize source tables
    for i, source in ipairs(SOURCES) do
        if source.key ~= "all" then
            stats.incomeBySource[source.key] = 0
            stats.expenseBySource[source.key] = 0
        end
    end

    -- Initialize time pattern tables
    for i = 1, 7 do
        stats.byDayOfWeek[i] = {total = 0, count = 0}
    end
    for i = 0, 23 do
        stats.byHourOfDay[i] = {total = 0, count = 0}
    end

    -- Temporary tables for aggregation
    local tradePartnerData = {}
    local auctionItemData = {}

    -- Process all transactions within time range (exclude historical synthetic data)
    for i, tx in ipairs(data.transactions) do
        if tx.timestamp >= cutoff and tx.source ~= "historical" then
            -- Track peak gold
            if tx.balance and tx.balance > stats.peakGold then
                stats.peakGold = tx.balance
                stats.peakGoldTimestamp = tx.timestamp
            end

            -- Total income/expenses
            if tx.amount > 0 then
                stats.totalIn = stats.totalIn + tx.amount
                stats.totalInCount = stats.totalInCount + 1
                if stats.incomeBySource[tx.source] then
                    stats.incomeBySource[tx.source] = stats.incomeBySource[tx.source] + tx.amount
                end
            else
                stats.totalOut = stats.totalOut + tx.amount
                stats.totalOutCount = stats.totalOutCount + 1
                if stats.expenseBySource[tx.source] then
                    stats.expenseBySource[tx.source] = stats.expenseBySource[tx.source] + math.abs(tx.amount)
                end
            end

            -- Time patterns
            local d = date("*t", tx.timestamp)
            local dow = d.wday  -- 1=Sunday, 7=Saturday
            local hour = d.hour

            stats.byDayOfWeek[dow].total = stats.byDayOfWeek[dow].total + tx.amount
            stats.byDayOfWeek[dow].count = stats.byDayOfWeek[dow].count + 1

            stats.byHourOfDay[hour].total = stats.byHourOfDay[hour].total + tx.amount
            stats.byHourOfDay[hour].count = stats.byHourOfDay[hour].count + 1

            -- Trade partner aggregation
            if tx.source == "trade" and tx.detail and tx.detail ~= "" then
                if not tradePartnerData[tx.detail] then
                    tradePartnerData[tx.detail] = {name = tx.detail, count = 0, received = 0, sent = 0}
                end
                tradePartnerData[tx.detail].count = tradePartnerData[tx.detail].count + 1
                if tx.amount > 0 then
                    tradePartnerData[tx.detail].received = tradePartnerData[tx.detail].received + tx.amount
                else
                    tradePartnerData[tx.detail].sent = tradePartnerData[tx.detail].sent + math.abs(tx.amount)
                end
            end

            -- Auction item aggregation
            if tx.source == "auction" and tx.detail and tx.detail ~= "" then
                if not auctionItemData[tx.detail] then
                    auctionItemData[tx.detail] = {name = tx.detail, count = 0, income = 0, expense = 0}
                end
                auctionItemData[tx.detail].count = auctionItemData[tx.detail].count + 1
                if tx.amount > 0 then
                    auctionItemData[tx.detail].income = auctionItemData[tx.detail].income + tx.amount
                else
                    auctionItemData[tx.detail].expense = auctionItemData[tx.detail].expense + math.abs(tx.amount)
                end
            end
        end
    end

    -- Convert trade partner data to sorted array
    for name, partner in pairs(tradePartnerData) do
        partner.net = partner.received - partner.sent
        table.insert(stats.tradePartners, partner)
    end
    -- Sort by absolute net value (most significant first)
    table.sort(stats.tradePartners, function(a, b)
        return math.abs(a.net) > math.abs(b.net)
    end)

    -- Convert auction item data to sorted array
    for name, item in pairs(auctionItemData) do
        item.net = item.income - item.expense
        table.insert(stats.auctionItems, item)
    end
    -- Sort by absolute net value
    table.sort(stats.auctionItems, function(a, b)
        return math.abs(a.net) > math.abs(b.net)
    end)

    -- Find best day (highest total profit)
    local bestDayIdx = 0
    local bestDayTotal = -999999999
    for day = 1, 7 do
        if stats.byDayOfWeek[day].count > 0 then
            local total = stats.byDayOfWeek[day].total
            if total > bestDayTotal then
                bestDayTotal = total
                bestDayIdx = day
            end
        end
    end
    if bestDayTotal > -999999999 then
        stats.bestDay = bestDayIdx
        stats.bestDayTotal = bestDayTotal
    end

    -- Find best time period (highest total profit)
    -- Night: 0-5, Morning: 6-11, Afternoon: 12-17, Evening: 18-23
    local periods = {
        {startHour = 0, endHour = 5, name = "Night"},
        {startHour = 6, endHour = 11, name = "Morning"},
        {startHour = 12, endHour = 17, name = "Afternoon"},
        {startHour = 18, endHour = 23, name = "Evening"},
    }
    local bestPeriodIdx = 0
    local bestPeriodTotal = -999999999
    for i, period in ipairs(periods) do
        local total = 0
        local hasData = false
        for hour = period.startHour, period.endHour do
            if stats.byHourOfDay[hour].count > 0 then
                total = total + stats.byHourOfDay[hour].total
                hasData = true
            end
        end
        if hasData and total > bestPeriodTotal then
            bestPeriodTotal = total
            bestPeriodIdx = i
        end
    end
    if bestPeriodTotal > -999999999 then
        stats.bestPeriod = bestPeriodIdx
        stats.bestPeriodTotal = bestPeriodTotal
        local periodRanges = {"12am-6am", "6am-12pm", "12pm-6pm", "6pm-12am"}
        stats.bestPeriodName = periodRanges[bestPeriodIdx]
    end

    return stats
end

-- Analytics: Get sorted source breakdown for display
function GoldTracker:GetSourceBreakdown(stats, isIncome)
    local breakdown = {}
    local sourceData = isIncome and stats.incomeBySource or stats.expenseBySource
    local total = 0

    -- Calculate total
    for source, amount in pairs(sourceData) do
        total = total + amount
    end

    -- Build sorted list
    for source, amount in pairs(sourceData) do
        if amount > 0 then
            local pct = 0
            if total > 0 then
                pct = math.floor((amount / total) * 100)
            end
            table.insert(breakdown, {
                source = source,
                amount = amount,
                percent = pct
            })
        end
    end

    -- Sort by amount descending
    table.sort(breakdown, function(a, b)
        return a.amount > b.amount
    end)

    return breakdown, total
end

-- Analytics: Get best earning days
function GoldTracker:GetBestDays(stats)
    local dayNames = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
    local days = {}

    for dow = 1, 7 do
        if stats.byDayOfWeek[dow].count > 0 then
            local avg = stats.byDayOfWeek[dow].total / stats.byDayOfWeek[dow].count
            table.insert(days, {
                name = dayNames[dow],
                avg = avg,
                count = stats.byDayOfWeek[dow].count
            })
        end
    end

    -- Sort by average descending
    table.sort(days, function(a, b)
        return a.avg > b.avg
    end)

    return days
end

-- Analytics: Get best earning hours
function GoldTracker:GetBestHours(stats)
    local hours = {}

    for hour = 0, 23 do
        if stats.byHourOfDay[hour].count > 0 then
            local avg = stats.byHourOfDay[hour].total / stats.byHourOfDay[hour].count
            -- Format hour as "Xam" or "Xpm"
            local displayHour = hour
            local suffix = "am"
            if hour >= 12 then
                suffix = "pm"
                if hour > 12 then displayHour = hour - 12 end
            end
            if hour == 0 then displayHour = 12 end

            table.insert(hours, {
                hour = hour,
                display = displayHour .. suffix,
                avg = avg,
                count = stats.byHourOfDay[hour].count
            })
        end
    end

    -- Sort by average descending
    table.sort(hours, function(a, b)
        return a.avg > b.avg
    end)

    return hours
end

-- Statistics: Update the statistics display
function GoldTracker:UpdateStatisticsDisplay()
    if not statisticsFrame then return end

    local stats = self:CalculateStatistics()
    if not stats then
        -- No data, show empty state
        statisticsFrame.cards.peak.value:SetText("--")
        statisticsFrame.cards.peak.subtext:SetText("")
        statisticsFrame.cards.totalIn.value:SetText("--")
        statisticsFrame.cards.totalIn.subtext:SetText("0 txns")
        statisticsFrame.cards.totalOut.value:SetText("--")
        statisticsFrame.cards.totalOut.subtext:SetText("0 txns")
        statisticsFrame.cards.bestDay.value:SetText("--")
        statisticsFrame.cards.bestDay.subtext:SetText("")
        -- Clear earning patterns (respect range visibility)
        local showDaysRow = not (currentRange == "session" or currentRange == "1day")
        for i = 1, 7 do
            if showDaysRow then
                statisticsFrame.dayLabels[i]:Show()
                statisticsFrame.dayValues[i]:Show()
            else
                statisticsFrame.dayLabels[i]:Hide()
                statisticsFrame.dayValues[i]:Hide()
            end
            statisticsFrame.dayValues[i]:SetText("--")
            statisticsFrame.dayValues[i]:SetTextColor(0.5, 0.5, 0.5, 1)
        end
        -- Adjust time periods position
        local periodYOffset = showDaysRow and -42 or -5
        local periodValueYOffset = showDaysRow and -55 or -18
        for i = 1, 4 do
            statisticsFrame.periodLabels[i]:SetPoint("TOPLEFT", statisticsFrame.periodLabels[i]:GetParent(), "TOPLEFT", (i - 1) * 128 + 5, periodYOffset)
            statisticsFrame.periodValues[i]:SetPoint("TOPLEFT", statisticsFrame.periodValues[i]:GetParent(), "TOPLEFT", (i - 1) * 128 + 5, periodValueYOffset)
            statisticsFrame.periodValues[i]:SetText("--")
            statisticsFrame.periodValues[i]:SetTextColor(0.5, 0.5, 0.5, 1)
        end
        return
    end

    -- Update summary cards
    -- Peak Gold
    local peakGold = math.floor(stats.peakGold / 10000)
    local peakSilver = math.floor(math.mod(stats.peakGold, 10000) / 100)
    statisticsFrame.cards.peak.value:SetText(peakGold .. "g " .. peakSilver .. "s")
    if stats.peakGoldTimestamp > 0 then
        local d = date("*t", stats.peakGoldTimestamp)
        statisticsFrame.cards.peak.subtext:SetText(d.month .. "/" .. d.day)
    else
        statisticsFrame.cards.peak.subtext:SetText("")
    end

    -- Total In
    local inGold = math.floor(stats.totalIn / 10000)
    local inSilver = math.floor(math.mod(stats.totalIn, 10000) / 100)
    statisticsFrame.cards.totalIn.value:SetText("+" .. inGold .. "g " .. inSilver .. "s")
    statisticsFrame.cards.totalIn.value:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)
    statisticsFrame.cards.totalIn.subtext:SetText(stats.totalInCount .. " txns")

    -- Total Out
    local outGold = math.floor(math.abs(stats.totalOut) / 10000)
    local outSilver = math.floor(math.mod(math.abs(stats.totalOut), 10000) / 100)
    statisticsFrame.cards.totalOut.value:SetText("-" .. outGold .. "g " .. outSilver .. "s")
    statisticsFrame.cards.totalOut.value:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)
    statisticsFrame.cards.totalOut.subtext:SetText(stats.totalOutCount .. " txns")

    -- Best Day or Best Time (depending on range)
    local useTimePeriod = (currentRange == "session" or currentRange == "1day")

    if useTimePeriod then
        -- Show best time period for short ranges
        statisticsFrame.cards.bestDay.label:SetText("BEST TIME")
        if stats.bestPeriod then
            local totalGold = math.floor(math.abs(stats.bestPeriodTotal) / 10000)
            local sign = stats.bestPeriodTotal >= 0 and "+" or "-"
            statisticsFrame.cards.bestDay.value:SetText(sign .. totalGold .. "g")
            statisticsFrame.cards.bestDay.subtext:SetText(stats.bestPeriodName)
            if stats.bestPeriodTotal >= 0 then
                statisticsFrame.cards.bestDay.value:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)
            else
                statisticsFrame.cards.bestDay.value:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)
            end
        else
            statisticsFrame.cards.bestDay.value:SetText("--")
            statisticsFrame.cards.bestDay.subtext:SetText("")
        end
    else
        -- Show best day for longer ranges
        statisticsFrame.cards.bestDay.label:SetText("BEST DAY")
        if stats.bestDay then
            local dayNames = {"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
            local dayName = dayNames[stats.bestDay]

            local totalGold = math.floor(math.abs(stats.bestDayTotal) / 10000)
            local sign = stats.bestDayTotal >= 0 and "+" or "-"
            statisticsFrame.cards.bestDay.value:SetText(sign .. totalGold .. "g")
            statisticsFrame.cards.bestDay.subtext:SetText(dayName)
            if stats.bestDayTotal >= 0 then
                statisticsFrame.cards.bestDay.value:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)
            else
                statisticsFrame.cards.bestDay.value:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)
            end
        else
            statisticsFrame.cards.bestDay.value:SetText("--")
            statisticsFrame.cards.bestDay.subtext:SetText("")
        end
    end

    -- Update source breakdown
    local incomeBreakdown, incomeTotal = self:GetSourceBreakdown(stats, true)
    local expenseBreakdown, expenseTotal = self:GetSourceBreakdown(stats, false)

    -- Max bar width (accounting for padding)
    local maxBarWidth = 240

    -- Income rows
    for i = 1, 5 do
        local row = statisticsFrame.incomeRows[i]
        if incomeBreakdown[i] then
            local data = incomeBreakdown[i]
            local sourceLabel = string.upper(string.sub(data.source, 1, 1)) .. string.sub(data.source, 2)
            row.source:SetText(sourceLabel)

            local gold = math.floor(data.amount / 10000)
            local silver = math.floor(math.mod(data.amount, 10000) / 100)
            row.amount:SetText("+" .. gold .. "g " .. silver .. "s")

            row.percent:SetText(data.percent .. "%")

            -- Set bar width based on percentage
            local barWidth = math.max(1, (data.percent / 100) * maxBarWidth)
            row.bar:SetWidth(barWidth)
            row.bar:Show()

            row.btn.sourceKey = data.source
            row.source:Show()
            row.amount:Show()
            row.percent:Show()
        else
            row.bar:Hide()
            row.source:SetText("")
            row.amount:SetText("")
            row.percent:SetText("")
            row.btn.sourceKey = nil
        end
    end

    -- Expense rows
    for i = 1, 5 do
        local row = statisticsFrame.expenseRows[i]
        if expenseBreakdown[i] then
            local data = expenseBreakdown[i]
            local sourceLabel = string.upper(string.sub(data.source, 1, 1)) .. string.sub(data.source, 2)
            row.source:SetText(sourceLabel)

            local gold = math.floor(data.amount / 10000)
            local silver = math.floor(math.mod(data.amount, 10000) / 100)
            row.amount:SetText("-" .. gold .. "g " .. silver .. "s")

            row.percent:SetText(data.percent .. "%")

            -- Set bar width based on percentage
            local barWidth = math.max(1, (data.percent / 100) * maxBarWidth)
            row.bar:SetWidth(barWidth)
            row.bar:Show()

            row.btn.sourceKey = data.source
            row.source:Show()
            row.amount:Show()
            row.percent:Show()
        else
            row.bar:Hide()
            row.source:SetText("")
            row.amount:SetText("")
            row.percent:SetText("")
            row.btn.sourceKey = nil
        end
    end

    -- Update trade partners
    for i = 1, 5 do
        local row = statisticsFrame.tradeRows[i]
        if stats.tradePartners[i] then
            local partner = stats.tradePartners[i]
            local displayName = partner.name
            if string.len(displayName) > 12 then
                displayName = string.sub(displayName, 1, 11) .. ".."
            end
            row.name:SetText(displayName)
            row.count:SetText(partner.count)

            local netGold = math.floor(math.abs(partner.net) / 10000)
            local netSilver = math.floor(math.mod(math.abs(partner.net), 10000) / 100)
            local netSign = partner.net >= 0 and "+" or "-"
            row.net:SetText(netSign .. netGold .. "g " .. netSilver .. "s")
            if partner.net >= 0 then
                row.net:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)
            else
                row.net:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)
            end

            row.btn.playerName = partner.name
            row.name:Show()
            row.count:Show()
            row.net:Show()
        else
            row.name:SetText("")
            row.count:SetText("")
            row.net:SetText("")
            row.btn.playerName = nil
        end
    end

    -- Update auction items
    for i = 1, 5 do
        local row = statisticsFrame.auctionRows[i]
        if stats.auctionItems[i] then
            local item = stats.auctionItems[i]
            local displayName = item.name
            if string.len(displayName) > 14 then
                displayName = string.sub(displayName, 1, 13) .. ".."
            end
            row.name:SetText(displayName)
            row.count:SetText(item.count)

            local netGold = math.floor(math.abs(item.net) / 10000)
            local netSilver = math.floor(math.mod(math.abs(item.net), 10000) / 100)
            local netSign = item.net >= 0 and "+" or "-"
            row.net:SetText(netSign .. netGold .. "g " .. netSilver .. "s")
            if item.net >= 0 then
                row.net:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)
            else
                row.net:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)
            end

            row.btn.itemName = item.name
            row.name:Show()
            row.count:Show()
            row.net:Show()
        else
            row.name:SetText("")
            row.count:SetText("")
            row.net:SetText("")
            row.btn.itemName = nil
        end
    end

    -- Update earning patterns - Days of week (only show for longer ranges)
    local showDaysRow = not (currentRange == "session" or currentRange == "1day")

    for i = 1, 7 do
        if showDaysRow then
            statisticsFrame.dayLabels[i]:Show()
            statisticsFrame.dayValues[i]:Show()

            local dayData = stats.byDayOfWeek[i]
            local total = dayData and dayData.total or 0
            local gold = math.floor(math.abs(total) / 10000)
            local sign = total >= 0 and "+" or "-"

            if dayData and dayData.count > 0 then
                statisticsFrame.dayValues[i]:SetText(sign .. gold .. "g")
                if total >= 0 then
                    statisticsFrame.dayValues[i]:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)
                else
                    statisticsFrame.dayValues[i]:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)
                end
            else
                statisticsFrame.dayValues[i]:SetText("--")
                statisticsFrame.dayValues[i]:SetTextColor(0.5, 0.5, 0.5, 1)
            end
        else
            statisticsFrame.dayLabels[i]:Hide()
            statisticsFrame.dayValues[i]:Hide()
        end
    end

    -- Adjust time periods position based on whether days row is shown
    local periodYOffset = showDaysRow and -42 or -5
    local periodValueYOffset = showDaysRow and -55 or -18
    for i = 1, 4 do
        statisticsFrame.periodLabels[i]:SetPoint("TOPLEFT", statisticsFrame.periodLabels[i]:GetParent(), "TOPLEFT", (i - 1) * 128 + 5, periodYOffset)
        statisticsFrame.periodValues[i]:SetPoint("TOPLEFT", statisticsFrame.periodValues[i]:GetParent(), "TOPLEFT", (i - 1) * 128 + 5, periodValueYOffset)
    end

    -- Update earning patterns - Time periods (total profit)
    -- Night: 0-5 (12am-6am), Morning: 6-11 (6am-12pm), Afternoon: 12-17 (12pm-6pm), Evening: 18-23 (6pm-12am)
    local periods = {
        {startHour = 0, endHour = 5},   -- Night
        {startHour = 6, endHour = 11},  -- Morning
        {startHour = 12, endHour = 17}, -- Afternoon
        {startHour = 18, endHour = 23}, -- Evening
    }

    for i, period in ipairs(periods) do
        local total = 0
        local hasData = false
        for hour = period.startHour, period.endHour do
            local hourData = stats.byHourOfDay[hour]
            if hourData and hourData.count > 0 then
                total = total + hourData.total
                hasData = true
            end
        end

        local gold = math.floor(math.abs(total) / 10000)
        local sign = total >= 0 and "+" or "-"

        if hasData then
            statisticsFrame.periodValues[i]:SetText(sign .. gold .. "g")
            if total >= 0 then
                statisticsFrame.periodValues[i]:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)
            else
                statisticsFrame.periodValues[i]:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)
            end
        else
            statisticsFrame.periodValues[i]:SetText("--")
            statisticsFrame.periodValues[i]:SetTextColor(0.5, 0.5, 0.5, 1)
        end
    end
end

-- Filter: Switch to transactions tab filtered by source
function GoldTracker:FilterBySource(sourceKey)
    -- Set only the specified source as active
    for i, source in ipairs(SOURCES) do
        if source.key ~= "all" then
            activeFilters[source.key] = (source.key == sourceKey)
        end
    end

    -- Clear detail filter
    detailFilter = nil

    -- Switch to transactions tab
    currentPage = 1
    SwitchTab("transactions")

    -- Update filter button visuals
    if transactionsFrame and transactionsFrame.filterButtons then
        for key, btn in pairs(transactionsFrame.filterButtons) do
            btn:UpdateState()
        end
    end
end

-- Filter: Switch to transactions tab filtered by detail (player name, item name)
function GoldTracker:FilterByDetail(sourceKey, detail)
    -- Set only the specified source as active
    for i, source in ipairs(SOURCES) do
        if source.key ~= "all" then
            activeFilters[source.key] = (source.key == sourceKey)
        end
    end

    -- Set detail filter
    detailFilter = detail

    -- Switch to transactions tab
    currentPage = 1
    SwitchTab("transactions")

    -- Update filter button visuals
    if transactionsFrame and transactionsFrame.filterButtons then
        for key, btn in pairs(transactionsFrame.filterButtons) do
            btn:UpdateState()
        end
    end
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

    -- Update detail filter indicator
    if transactionsFrame.detailFilterFrame then
        if detailFilter then
            local displayText = detailFilter
            if string.len(displayText) > 14 then
                displayText = string.sub(displayText, 1, 13) .. ".."
            end
            transactionsFrame.detailFilterFrame.text:SetText(displayText)
            transactionsFrame.detailFilterFrame:Show()
        else
            transactionsFrame.detailFilterFrame:Hide()
        end
    end

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

            -- Detail (NPC name, player name, quest name, etc.) - truncate for display
            local detailText = tx.detail or ""
            row.detailFull = detailText
            if string.len(detailText) > 18 then
                detailText = string.sub(detailText, 1, 16) .. ".."
            end
            row.detail:SetText(detailText)

            -- Balance (show gold and silver)
            local balGold = math.floor(tx.balance / 10000)
            local balSilver = math.floor(math.mod(tx.balance, 10000) / 100)
            row.balance:SetText(balGold .. "g " .. balSilver .. "s")
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

-- Chart: Filled area support
local fillBarIndex = 0
local fillBars = {}

local function ClearFillBars()
    for i, tex in ipairs(fillBars) do
        tex:Hide()
    end
    fillBarIndex = 0
end

-- Gradient bands for fill (fewer bands = better performance)
local NUM_GRADIENT_BANDS = 16
local gradientBandHeight = nil  -- Calculated once when chart updates

-- Draw a single vertical fill column with smooth gradient (using opaque colors, no alpha)
local function DrawFillColumn(x, height, colWidth)
    if height <= 2 then return end

    -- Base gold color
    local baseR, baseG, baseB = COLORS.fill[1], COLORS.fill[2], COLORS.fill[3]

    for i = 0, NUM_GRADIENT_BANDS - 1 do
        local bandBottom = i * gradientBandHeight
        local bandTop = (i + 1) * gradientBandHeight

        -- Only draw if this band intersects with our column height
        if bandBottom < height then
            local segmentBottom = bandBottom
            local segmentTop = math.min(bandTop, height)
            local segmentHeight = segmentTop - segmentBottom

            if segmentHeight > 0 then
                -- Brightness increases from bottom to top (fade to black at bottom)
                local t = (i + 0.5) / NUM_GRADIENT_BANDS
                local brightness = 0.08 + (t * t * 0.55)

                fillBarIndex = fillBarIndex + 1
                local tex = fillBars[fillBarIndex]
                if not tex then
                    tex = chartFrame:CreateTexture(nil, "ARTWORK", nil, -1)
                    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
                    fillBars[fillBarIndex] = tex
                end
                tex:ClearAllPoints()
                tex:SetWidth(colWidth)
                tex:SetHeight(segmentHeight)
                tex:SetPoint("BOTTOMLEFT", chartFrame, "BOTTOMLEFT", x, segmentBottom)
                tex:SetVertexColor(baseR * brightness, baseG * brightness, baseB * brightness, 1)
                tex:Show()
            end
        end
    end
end

-- Draw filled area between two points using linear interpolation (matches the line)
local function DrawFilledArea(x1, y1, x2, y2)
    local startX = math.floor(x1)
    local endX = math.floor(x2)
    local width = endX - startX

    if width <= 0 then return end

    -- Performance optimization: draw fewer, wider columns
    local colStep = 3  -- Draw every 3 pixels
    local colWidth = 3  -- Match step size exactly (no spillover)

    for i = 0, width, colStep do
        local t = width > 0 and (i / width) or 0
        local height = y1 + (y2 - y1) * t + 1  -- Add 1px to reach the line
        DrawFillColumn(startX + i, height, colWidth)
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
    ClearFillBars()
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

    -- Initialize gradient band height for fill
    gradientBandHeight = CHART_HEIGHT / NUM_GRADIENT_BANDS

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

        -- Show Y-axis labels based on current gold with nice intervals
        local baseGold = currentGold
        if count == 1 then
            baseGold = history[1].gold
        end
        local padding = math.max(baseGold * 0.1, 10000) -- At least 1g padding
        local gridCount = 4
        local niceMin, niceMax, niceStep = GetNiceAxisBounds(baseGold - padding, baseGold + padding, gridCount)

        for i = 0, gridCount do
            if yAxisLabels[i + 1] then
                local goldValue = niceMin + (niceStep * i)
                yAxisLabels[i + 1]:SetText(FormatGoldCompact(goldValue, niceStep))
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

    -- Calculate nice Y-axis bounds with clean intervals
    local gridCount = 4
    local rawRange = maxGold - minGold
    if rawRange == 0 then rawRange = 10000 end -- Default 1g range
    -- Add small padding before calculating nice bounds
    local paddedMin = minGold - (rawRange * 0.05)
    local paddedMax = maxGold + (rawRange * 0.05)
    local niceMin, niceMax, niceStep = GetNiceAxisBounds(paddedMin, paddedMax, gridCount)
    minGold = niceMin
    maxGold = niceMax
    local goldRange = maxGold - minGold

    local timeRange = maxTime - minTime
    if timeRange == 0 then timeRange = 1 end

    -- Update Y-axis labels using nice step intervals
    for i = 0, gridCount do
        if yAxisLabels[i + 1] then
            local goldValue = minGold + (niceStep * i)
            yAxisLabels[i + 1]:SetText(FormatGoldCompact(goldValue, niceStep))
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

    -- Draw filled area and lines between points, store data points for hover
    local maxPoints = 150 -- Limit points for performance
    local step = math.max(1, math.floor(count / maxPoints))
    local lastX, lastY = nil, nil
    local dataPointIndex = 0

    -- First pass: Draw the filled area (step-style for accurate representation)
    for i = 1, count, step do
        local entry = history[i]
        local x = ((entry.timestamp - minTime) / timeRange) * CHART_WIDTH
        local y = ((entry.gold - minGold) / goldRange) * CHART_HEIGHT

        if lastX and lastY then
            DrawFilledArea(lastX, lastY, x, y)
        end
        lastX, lastY = x, y
    end

    -- Handle last point for fill (ensure we reach the right edge)
    if count > 0 then
        local entry = history[count]
        local x = ((entry.timestamp - minTime) / timeRange) * CHART_WIDTH
        local y = ((entry.gold - minGold) / goldRange) * CHART_HEIGHT
        if lastX and lastY and x > lastX then
            DrawFilledArea(lastX, lastY, x, y)
        end
        -- Fill from last point to right edge at constant height
        if x < CHART_WIDTH then
            DrawFilledArea(x, y, CHART_WIDTH, y)
        end
    end

    -- Second pass: Draw the line on top and store data points for hover
    lastX, lastY = nil, nil
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
        lastX, lastY = x, y
    end

    -- Extend line to right edge of chart
    if lastX and lastY then
        DrawLine(lastX, lastY, CHART_WIDTH + 1, lastY)
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
SwitchTab = function(tabKey)
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
            -- Clear detail filter when explicitly switching to transactions
            detailFilter = nil
            GoldTracker:UpdateTransactionList()
        else
            transactionsFrame:Hide()
        end
    end

    if statisticsFrame then
        if tabKey == "statistics" then
            statisticsFrame:Show()
            GoldTracker:UpdateStatisticsDisplay()
        else
            statisticsFrame:Hide()
        end
    end
end

-- UI: Create transactions frame content (separated to avoid upvalue limit)
local function CreateTransactionsFrame()
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

        btn.icon = btn:CreateTexture(nil, "ARTWORK")
        btn.icon:SetTexture(source.icon)
        btn.icon:SetPoint("CENTER", 0, 0)
        btn.icon:SetWidth(filterBtnSize - 4)
        btn.icon:SetHeight(filterBtnSize - 4)

        btn.sourceKey = source.key
        btn.sourceLabel = source.label

        btn.UpdateState = function(self)
            if self.sourceKey == "all" then
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
            for key, filterBtn in pairs(transactionsFrame.filterButtons) do
                filterBtn:UpdateState()
            end
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

    -- Detail filter indicator
    transactionsFrame.detailFilterFrame = CreateFrame("Frame", nil, transactionsFrame.filterBar)
    transactionsFrame.detailFilterFrame:SetPoint("LEFT", transactionsFrame.filterBar, "LEFT", 320, 0)
    transactionsFrame.detailFilterFrame:SetWidth(120)
    transactionsFrame.detailFilterFrame:SetHeight(20)
    transactionsFrame.detailFilterFrame:Hide()

    transactionsFrame.detailFilterFrame.bg = transactionsFrame.detailFilterFrame:CreateTexture(nil, "BACKGROUND")
    transactionsFrame.detailFilterFrame.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    transactionsFrame.detailFilterFrame.bg:SetAllPoints()
    transactionsFrame.detailFilterFrame.bg:SetVertexColor(0.15, 0.15, 0.15, 0.9)

    transactionsFrame.detailFilterFrame.text = transactionsFrame.detailFilterFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    transactionsFrame.detailFilterFrame.text:SetPoint("LEFT", transactionsFrame.detailFilterFrame, "LEFT", 5, 0)
    transactionsFrame.detailFilterFrame.text:SetWidth(90)
    transactionsFrame.detailFilterFrame.text:SetJustifyH("LEFT")
    transactionsFrame.detailFilterFrame.text:SetTextColor(1, 0.843, 0, 1)

    transactionsFrame.detailFilterFrame.clearBtn = CreateFrame("Button", nil, transactionsFrame.detailFilterFrame)
    transactionsFrame.detailFilterFrame.clearBtn:SetWidth(14)
    transactionsFrame.detailFilterFrame.clearBtn:SetHeight(14)
    transactionsFrame.detailFilterFrame.clearBtn:SetPoint("RIGHT", transactionsFrame.detailFilterFrame, "RIGHT", -3, 0)

    transactionsFrame.detailFilterFrame.clearBtn.text = transactionsFrame.detailFilterFrame.clearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    transactionsFrame.detailFilterFrame.clearBtn.text:SetPoint("CENTER", 0, 0)
    transactionsFrame.detailFilterFrame.clearBtn.text:SetText("x")
    transactionsFrame.detailFilterFrame.clearBtn.text:SetTextColor(0.8, 0.8, 0.8, 1)

    transactionsFrame.detailFilterFrame.clearBtn:SetScript("OnClick", function()
        detailFilter = nil
        for i, source in ipairs(SOURCES) do
            if source.key ~= "all" then
                activeFilters[source.key] = true
            end
        end
        for key, btn in pairs(transactionsFrame.filterButtons) do
            btn:UpdateState()
        end
        transactionsFrame.detailFilterFrame:Hide()
        currentPage = 1
        GoldTracker:UpdateTransactionList()
    end)

    transactionsFrame.detailFilterFrame.clearBtn:SetScript("OnEnter", function()
        this.text:SetTextColor(1, 0.843, 0, 1)
    end)

    transactionsFrame.detailFilterFrame.clearBtn:SetScript("OnLeave", function()
        this.text:SetTextColor(0.8, 0.8, 0.8, 1)
    end)

    -- Table container
    transactionsFrame.tableFrame = CreateFrame("Frame", nil, transactionsFrame)
    transactionsFrame.tableFrame:SetPoint("TOPLEFT", transactionsFrame.filterBar, "BOTTOMLEFT", 0, -4)
    transactionsFrame.tableFrame:SetPoint("BOTTOMRIGHT", transactionsFrame, "BOTTOMRIGHT", 0, 24)

    local tableBg = transactionsFrame.tableFrame:CreateTexture(nil, "BACKGROUND")
    tableBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    tableBg:SetAllPoints()
    tableBg:SetVertexColor(0.05, 0.05, 0.05, 0.5)

    -- Table column headers
    local colWidths = {90, 85, 60, 200, 85}  -- Time, Amount, Source, Detail, Balance
    local colNames = {"Time", "Amount", "Source", "Detail", "Balance"}
    local colPositions = {0, 90, 175, 235, 435}

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

        row.time = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.time:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[1], y)
        row.time:SetWidth(colWidths[1])
        row.time:SetJustifyH("LEFT")
        row.time:SetTextColor(0.7, 0.7, 0.7, 1)

        row.amount = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.amount:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[2], y)
        row.amount:SetWidth(colWidths[2])
        row.amount:SetJustifyH("LEFT")

        row.source = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.source:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[3], y)
        row.source:SetWidth(colWidths[3])
        row.source:SetJustifyH("LEFT")
        row.source:SetTextColor(0.6, 0.6, 0.6, 1)

        row.detail = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.detail:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[4], y)
        row.detail:SetWidth(colWidths[4])
        row.detail:SetHeight(rowHeight)
        row.detail:SetJustifyH("LEFT")
        row.detail:SetTextColor(0.6, 0.6, 0.6, 1)
        row.detailFull = nil

        row.detailHover = CreateFrame("Button", nil, transactionsFrame.tableFrame)
        row.detailHover:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[4], y)
        row.detailHover:SetWidth(colWidths[4])
        row.detailHover:SetHeight(rowHeight)
        row.detailHover.row = row
        row.detailHover:SetScript("OnEnter", function()
            if this.row.detailFull and this.row.detailFull ~= "" then
                GameTooltip:SetOwner(this, "ANCHOR_CURSOR")
                GameTooltip:SetText(this.row.detailFull, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        row.detailHover:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        row.balance = transactionsFrame.tableFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.balance:SetPoint("TOPLEFT", transactionsFrame.tableFrame, "TOPLEFT", colPositions[5], y)
        row.balance:SetWidth(colWidths[5])
        row.balance:SetJustifyH("LEFT")

        row.Show = function(self)
            self.time:Show()
            self.amount:Show()
            self.source:Show()
            self.detail:Show()
            self.detailHover:Show()
            self.balance:Show()
        end

        row.Hide = function(self)
            self.time:Hide()
            self.amount:Hide()
            self.source:Hide()
            self.detail:Hide()
            self.detailHover:Hide()
            self.balance:Hide()
        end

        transactionsFrame.rows[i] = row
    end

    -- Pagination container
    transactionsFrame.pagination = CreateFrame("Frame", nil, transactionsFrame)
    transactionsFrame.pagination:SetPoint("BOTTOMLEFT", transactionsFrame, "BOTTOMLEFT", 0, 0)
    transactionsFrame.pagination:SetPoint("BOTTOMRIGHT", transactionsFrame, "BOTTOMRIGHT", 0, 0)
    transactionsFrame.pagination:SetHeight(20)

    transactionsFrame.pageText = transactionsFrame.pagination:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    transactionsFrame.pageText:SetPoint("LEFT", transactionsFrame.pagination, "LEFT", 0, 0)
    transactionsFrame.pageText:SetTextColor(0.7, 0.7, 0.7, 1)
    transactionsFrame.pageText:SetText("Page 1 of 1")

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
end

-- UI: Create statistics frame content (separated to avoid upvalue limit)
local function CreateStatisticsFrame()
    -- Statistics frame (hidden by default)
    statisticsFrame = CreateFrame("Frame", nil, mainFrame)
    statisticsFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 10, -CHART_TOP_OFFSET)
    statisticsFrame:SetPoint("BOTTOMRIGHT", mainFrame, "BOTTOMRIGHT", -10, 8)
    statisticsFrame:Hide()

    -- Statistics background
    local statsBg = statisticsFrame:CreateTexture(nil, "BACKGROUND")
    statsBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    statsBg:SetAllPoints()
    statsBg:SetVertexColor(0.05, 0.05, 0.05, 0.3)

    -- Create a scroll frame for statistics content
    statisticsFrame.scrollFrame = CreateFrame("ScrollFrame", nil, statisticsFrame)
    statisticsFrame.scrollFrame:SetPoint("TOPLEFT", statisticsFrame, "TOPLEFT", 0, 0)
    statisticsFrame.scrollFrame:SetPoint("BOTTOMRIGHT", statisticsFrame, "BOTTOMRIGHT", 0, 0)
    statisticsFrame.scrollFrame:EnableMouseWheel(true)
    statisticsFrame.scrollFrame:SetScript("OnMouseWheel", function()
        local current = this:GetVerticalScroll()
        local maxScroll = this:GetVerticalScrollRange()
        local newScroll = current - (arg1 * 20)
        if newScroll < 0 then newScroll = 0 end
        if newScroll > maxScroll then newScroll = maxScroll end
        this:SetVerticalScroll(newScroll)
    end)

    -- Content frame inside scroll
    statisticsFrame.content = CreateFrame("Frame", nil, statisticsFrame.scrollFrame)
    statisticsFrame.content:SetWidth(530)
    statisticsFrame.content:SetHeight(600)
    statisticsFrame.scrollFrame:SetScrollChild(statisticsFrame.content)

    local content = statisticsFrame.content
    local yOffset = 0

    -- Helper function to create a summary card
    local function CreateSummaryCard(parent, xPos, width)
        local card = CreateFrame("Frame", nil, parent)
        card:SetWidth(width)
        card:SetHeight(50)
        card:SetPoint("TOPLEFT", parent, "TOPLEFT", xPos, 0)

        card.bg = card:CreateTexture(nil, "BACKGROUND")
        card.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        card.bg:SetAllPoints()
        card.bg:SetVertexColor(0.08, 0.08, 0.08, 0.8)

        card.border = {}
        for i = 1, 4 do
            card.border[i] = card:CreateTexture(nil, "BORDER")
            card.border[i]:SetTexture("Interface\\Buttons\\WHITE8X8")
            card.border[i]:SetVertexColor(0.3, 0.3, 0.3, 0.5)
        end
        card.border[1]:SetHeight(1)
        card.border[1]:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
        card.border[1]:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, 0)
        card.border[2]:SetHeight(1)
        card.border[2]:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
        card.border[2]:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", 0, 0)
        card.border[3]:SetWidth(1)
        card.border[3]:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
        card.border[3]:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
        card.border[4]:SetWidth(1)
        card.border[4]:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, 0)
        card.border[4]:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", 0, 0)

        card.label = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        card.label:SetPoint("TOP", card, "TOP", 0, -6)
        card.label:SetTextColor(0.6, 0.6, 0.6, 1)

        card.value = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        card.value:SetPoint("CENTER", card, "CENTER", 0, 0)
        card.value:SetTextColor(1, 0.843, 0, 1)

        card.subtext = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        card.subtext:SetPoint("BOTTOM", card, "BOTTOM", 0, 6)
        card.subtext:SetTextColor(0.5, 0.5, 0.5, 1)

        return card
    end

    -- Summary cards row
    local cardWidth = 125
    local cardSpacing = 8
    statisticsFrame.cards = {}

    statisticsFrame.cards.peak = CreateSummaryCard(content, 0, cardWidth)
    statisticsFrame.cards.peak.label:SetText("PEAK GOLD")

    statisticsFrame.cards.totalIn = CreateSummaryCard(content, cardWidth + cardSpacing, cardWidth)
    statisticsFrame.cards.totalIn.label:SetText("TOTAL IN")

    statisticsFrame.cards.totalOut = CreateSummaryCard(content, (cardWidth + cardSpacing) * 2, cardWidth)
    statisticsFrame.cards.totalOut.label:SetText("TOTAL OUT")

    statisticsFrame.cards.bestDay = CreateSummaryCard(content, (cardWidth + cardSpacing) * 3, cardWidth)
    statisticsFrame.cards.bestDay.label:SetText("BEST DAY")

    yOffset = -58

    -- Source Breakdown Section
    local sourceLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    sourceLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
    sourceLabel:SetText("SOURCE BREAKDOWN")
    sourceLabel:SetTextColor(0.8, 0.8, 0.8, 1)

    yOffset = yOffset - 18

    -- Income column
    local incomeFrame = CreateFrame("Frame", nil, content)
    incomeFrame:SetWidth(255)
    incomeFrame:SetHeight(100)
    incomeFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)

    local incomeBg = incomeFrame:CreateTexture(nil, "BACKGROUND")
    incomeBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    incomeBg:SetAllPoints()
    incomeBg:SetVertexColor(0.05, 0.05, 0.05, 0.5)

    local incomeHeader = incomeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    incomeHeader:SetPoint("TOPLEFT", incomeFrame, "TOPLEFT", 5, -5)
    incomeHeader:SetText("INCOME")
    incomeHeader:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)

    statisticsFrame.incomeRows = {}
    for i = 1, 5 do
        local row = {}
        local rowY = -20 - ((i - 1) * 15)

        row.bar = incomeFrame:CreateTexture(nil, "ARTWORK")
        row.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
        row.bar:SetHeight(10)
        row.bar:SetPoint("TOPLEFT", incomeFrame, "TOPLEFT", 5, rowY)
        row.bar:SetVertexColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 0.6)

        row.source = incomeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.source:SetPoint("LEFT", incomeFrame, "TOPLEFT", 8, rowY - 5)
        row.source:SetTextColor(1, 1, 1, 1)

        row.amount = incomeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.amount:SetPoint("RIGHT", incomeFrame, "TOPRIGHT", -30, rowY - 5)
        row.amount:SetJustifyH("RIGHT")
        row.amount:SetTextColor(0.8, 0.8, 0.8, 1)

        row.percent = incomeFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.percent:SetPoint("RIGHT", incomeFrame, "TOPRIGHT", -5, rowY - 5)
        row.percent:SetJustifyH("RIGHT")
        row.percent:SetTextColor(0.6, 0.6, 0.6, 1)

        row.btn = CreateFrame("Button", nil, incomeFrame)
        row.btn:SetPoint("TOPLEFT", incomeFrame, "TOPLEFT", 0, rowY)
        row.btn:SetWidth(255)
        row.btn:SetHeight(15)
        row.btn.sourceKey = nil
        row.btn:SetScript("OnClick", function()
            if this.sourceKey then
                GoldTracker:FilterBySource(this.sourceKey)
            end
        end)
        row.btn:SetScript("OnEnter", function()
            if this.sourceKey then
                row.source:SetTextColor(1, 0.843, 0, 1)
            end
        end)
        row.btn:SetScript("OnLeave", function()
            row.source:SetTextColor(1, 1, 1, 1)
        end)

        statisticsFrame.incomeRows[i] = row
    end

    -- Expenses column
    local expenseFrame = CreateFrame("Frame", nil, content)
    expenseFrame:SetWidth(255)
    expenseFrame:SetHeight(100)
    expenseFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 265, yOffset)

    local expenseBg = expenseFrame:CreateTexture(nil, "BACKGROUND")
    expenseBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    expenseBg:SetAllPoints()
    expenseBg:SetVertexColor(0.05, 0.05, 0.05, 0.5)

    local expenseHeader = expenseFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    expenseHeader:SetPoint("TOPLEFT", expenseFrame, "TOPLEFT", 5, -5)
    expenseHeader:SetText("EXPENSES")
    expenseHeader:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)

    statisticsFrame.expenseRows = {}
    for i = 1, 5 do
        local row = {}
        local rowY = -20 - ((i - 1) * 15)

        row.bar = expenseFrame:CreateTexture(nil, "ARTWORK")
        row.bar:SetTexture("Interface\\Buttons\\WHITE8X8")
        row.bar:SetHeight(10)
        row.bar:SetPoint("TOPLEFT", expenseFrame, "TOPLEFT", 5, rowY)
        row.bar:SetVertexColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 0.6)

        row.source = expenseFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.source:SetPoint("LEFT", expenseFrame, "TOPLEFT", 8, rowY - 5)
        row.source:SetTextColor(1, 1, 1, 1)

        row.amount = expenseFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.amount:SetPoint("RIGHT", expenseFrame, "TOPRIGHT", -30, rowY - 5)
        row.amount:SetJustifyH("RIGHT")
        row.amount:SetTextColor(0.8, 0.8, 0.8, 1)

        row.percent = expenseFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.percent:SetPoint("RIGHT", expenseFrame, "TOPRIGHT", -5, rowY - 5)
        row.percent:SetJustifyH("RIGHT")
        row.percent:SetTextColor(0.6, 0.6, 0.6, 1)

        row.btn = CreateFrame("Button", nil, expenseFrame)
        row.btn:SetPoint("TOPLEFT", expenseFrame, "TOPLEFT", 0, rowY)
        row.btn:SetWidth(255)
        row.btn:SetHeight(15)
        row.btn.sourceKey = nil
        row.btn:SetScript("OnClick", function()
            if this.sourceKey then
                GoldTracker:FilterBySource(this.sourceKey)
            end
        end)
        row.btn:SetScript("OnEnter", function()
            if this.sourceKey then
                row.source:SetTextColor(1, 0.843, 0, 1)
            end
        end)
        row.btn:SetScript("OnLeave", function()
            row.source:SetTextColor(1, 1, 1, 1)
        end)

        statisticsFrame.expenseRows[i] = row
    end

    yOffset = yOffset - 110

    -- Top Trade Partners Section
    local tradeLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tradeLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
    tradeLabel:SetText("TOP TRADE PARTNERS")
    tradeLabel:SetTextColor(0.8, 0.8, 0.8, 1)

    local auctionLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    auctionLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 265, yOffset)
    auctionLabel:SetText("TOP AUCTION ITEMS")
    auctionLabel:SetTextColor(0.8, 0.8, 0.8, 1)

    yOffset = yOffset - 18

    -- Trade Partners list frame
    local tradeListFrame = CreateFrame("Frame", nil, content)
    tradeListFrame:SetWidth(255)
    tradeListFrame:SetHeight(90)
    tradeListFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)

    local tradeBg = tradeListFrame:CreateTexture(nil, "BACKGROUND")
    tradeBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    tradeBg:SetAllPoints()
    tradeBg:SetVertexColor(0.05, 0.05, 0.05, 0.5)

    local tradeNameHeader = tradeListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tradeNameHeader:SetPoint("TOPLEFT", tradeListFrame, "TOPLEFT", 5, -3)
    tradeNameHeader:SetText("Player")
    tradeNameHeader:SetTextColor(0.5, 0.5, 0.5, 1)

    local tradeCountHeader = tradeListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tradeCountHeader:SetPoint("TOPLEFT", tradeListFrame, "TOPLEFT", 110, -3)
    tradeCountHeader:SetText("#")
    tradeCountHeader:SetTextColor(0.5, 0.5, 0.5, 1)

    local tradeNetHeader = tradeListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tradeNetHeader:SetPoint("TOPRIGHT", tradeListFrame, "TOPRIGHT", -5, -3)
    tradeNetHeader:SetText("Net")
    tradeNetHeader:SetTextColor(0.5, 0.5, 0.5, 1)

    statisticsFrame.tradeRows = {}
    for i = 1, 5 do
        local row = {}
        local rowY = -16 - ((i - 1) * 14)

        row.name = tradeListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.name:SetPoint("TOPLEFT", tradeListFrame, "TOPLEFT", 5, rowY)
        row.name:SetWidth(100)
        row.name:SetJustifyH("LEFT")
        row.name:SetTextColor(1, 1, 1, 1)

        row.count = tradeListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.count:SetPoint("TOPLEFT", tradeListFrame, "TOPLEFT", 110, rowY)
        row.count:SetTextColor(0.6, 0.6, 0.6, 1)

        row.net = tradeListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.net:SetPoint("TOPRIGHT", tradeListFrame, "TOPRIGHT", -5, rowY)
        row.net:SetJustifyH("RIGHT")

        row.btn = CreateFrame("Button", nil, tradeListFrame)
        row.btn:SetPoint("TOPLEFT", tradeListFrame, "TOPLEFT", 0, rowY)
        row.btn:SetWidth(255)
        row.btn:SetHeight(14)
        row.btn.playerName = nil
        row.btn:SetScript("OnClick", function()
            if this.playerName then
                GoldTracker:FilterByDetail("trade", this.playerName)
            end
        end)
        row.btn:SetScript("OnEnter", function()
            if this.playerName then
                row.name:SetTextColor(1, 0.843, 0, 1)
            end
        end)
        row.btn:SetScript("OnLeave", function()
            row.name:SetTextColor(1, 1, 1, 1)
        end)

        statisticsFrame.tradeRows[i] = row
    end

    -- Auction Items list frame
    local auctionListFrame = CreateFrame("Frame", nil, content)
    auctionListFrame:SetWidth(255)
    auctionListFrame:SetHeight(90)
    auctionListFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 265, yOffset)

    local auctionBg = auctionListFrame:CreateTexture(nil, "BACKGROUND")
    auctionBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    auctionBg:SetAllPoints()
    auctionBg:SetVertexColor(0.05, 0.05, 0.05, 0.5)

    local auctionNameHeader = auctionListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    auctionNameHeader:SetPoint("TOPLEFT", auctionListFrame, "TOPLEFT", 5, -3)
    auctionNameHeader:SetText("Item")
    auctionNameHeader:SetTextColor(0.5, 0.5, 0.5, 1)

    local auctionCountHeader = auctionListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    auctionCountHeader:SetPoint("TOPLEFT", auctionListFrame, "TOPLEFT", 130, -3)
    auctionCountHeader:SetText("#")
    auctionCountHeader:SetTextColor(0.5, 0.5, 0.5, 1)

    local auctionNetHeader = auctionListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    auctionNetHeader:SetPoint("TOPRIGHT", auctionListFrame, "TOPRIGHT", -5, -3)
    auctionNetHeader:SetText("Net")
    auctionNetHeader:SetTextColor(0.5, 0.5, 0.5, 1)

    statisticsFrame.auctionRows = {}
    for i = 1, 5 do
        local row = {}
        local rowY = -16 - ((i - 1) * 14)

        row.name = auctionListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.name:SetPoint("TOPLEFT", auctionListFrame, "TOPLEFT", 5, rowY)
        row.name:SetWidth(120)
        row.name:SetJustifyH("LEFT")
        row.name:SetTextColor(1, 1, 1, 1)

        row.count = auctionListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.count:SetPoint("TOPLEFT", auctionListFrame, "TOPLEFT", 130, rowY)
        row.count:SetTextColor(0.6, 0.6, 0.6, 1)

        row.net = auctionListFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        row.net:SetPoint("TOPRIGHT", auctionListFrame, "TOPRIGHT", -5, rowY)
        row.net:SetJustifyH("RIGHT")

        row.btn = CreateFrame("Button", nil, auctionListFrame)
        row.btn:SetPoint("TOPLEFT", auctionListFrame, "TOPLEFT", 0, rowY)
        row.btn:SetWidth(255)
        row.btn:SetHeight(14)
        row.btn.itemName = nil
        row.btn:SetScript("OnClick", function()
            if this.itemName then
                GoldTracker:FilterByDetail("auction", this.itemName)
            end
        end)
        row.btn:SetScript("OnEnter", function()
            if this.itemName then
                row.name:SetTextColor(1, 0.843, 0, 1)
            end
        end)
        row.btn:SetScript("OnLeave", function()
            row.name:SetTextColor(1, 1, 1, 1)
        end)

        statisticsFrame.auctionRows[i] = row
    end

    -- Click hints
    local tradeHint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    tradeHint:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset - 92)
    tradeHint:SetText("(click to view transactions)")
    tradeHint:SetTextColor(0.4, 0.4, 0.4, 1)

    local auctionHint = content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    auctionHint:SetPoint("TOPLEFT", content, "TOPLEFT", 265, yOffset - 92)
    auctionHint:SetText("(click to view transactions)")
    auctionHint:SetTextColor(0.4, 0.4, 0.4, 1)

    yOffset = yOffset - 110

    -- Earning Patterns Section
    local patternsLabel = content:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    patternsLabel:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)
    patternsLabel:SetText("EARNING PATTERNS")
    patternsLabel:SetTextColor(0.8, 0.8, 0.8, 1)

    yOffset = yOffset - 18

    local patternsFrame = CreateFrame("Frame", nil, content)
    patternsFrame:SetWidth(520)
    patternsFrame:SetHeight(72)
    patternsFrame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, yOffset)

    local patternsBg = patternsFrame:CreateTexture(nil, "BACKGROUND")
    patternsBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    patternsBg:SetAllPoints()
    patternsBg:SetVertexColor(0.05, 0.05, 0.05, 0.5)

    -- Days of week row
    local dayNames = {"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
    local dayWidth = 73
    statisticsFrame.dayLabels = {}
    statisticsFrame.dayValues = {}

    for i, dayName in ipairs(dayNames) do
        local xPos = (i - 1) * dayWidth + 5

        local label = patternsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", patternsFrame, "TOPLEFT", xPos, -5)
        label:SetText(dayName)
        label:SetTextColor(0.6, 0.6, 0.6, 1)
        statisticsFrame.dayLabels[i] = label

        local value = patternsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        value:SetPoint("TOPLEFT", patternsFrame, "TOPLEFT", xPos, -18)
        value:SetTextColor(1, 1, 1, 1)
        statisticsFrame.dayValues[i] = value
    end

    -- Time periods row
    local periodNames = {"Night (12a-6a)", "Morning (6a-12p)", "Afternoon (12p-6p)", "Evening (6p-12a)"}
    local periodWidth = 128
    statisticsFrame.periodLabels = {}
    statisticsFrame.periodValues = {}

    for i, periodName in ipairs(periodNames) do
        local xPos = (i - 1) * periodWidth + 5

        local label = patternsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", patternsFrame, "TOPLEFT", xPos, -42)
        label:SetText(periodName)
        label:SetTextColor(0.6, 0.6, 0.6, 1)
        statisticsFrame.periodLabels[i] = label

        local value = patternsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        value:SetPoint("TOPLEFT", patternsFrame, "TOPLEFT", xPos, -55)
        statisticsFrame.periodValues[i] = value
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

    -- Close button with custom icon
    local closeBtn = CreateFrame("Button", nil, mainFrame)
    closeBtn:SetWidth(16)
    closeBtn:SetHeight(16)
    closeBtn:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -5, -5)
    closeBtn:SetFrameLevel(mainFrame:GetFrameLevel() + 5)
    closeBtn:EnableMouse(true)
    closeBtn:RegisterForClicks("LeftButtonUp")

    closeBtn.icon = closeBtn:CreateTexture(nil, "ARTWORK")
    closeBtn.icon:SetTexture("Interface\\AddOns\\GoldTracker\\images\\yellow_close_x_icon")
    closeBtn.icon:SetAllPoints()
    closeBtn.icon:SetVertexColor(0.8, 0.8, 0.8, 0.8)

    closeBtn:SetScript("OnClick", function() mainFrame:Hide() end)
    closeBtn:SetScript("OnEnter", function()
        this.icon:SetVertexColor(1, 0.843, 0, 1)
    end)
    closeBtn:SetScript("OnLeave", function()
        this.icon:SetVertexColor(0.8, 0.8, 0.8, 0.8)
    end)

    -- Minimize button with custom icon
    local minimizeBtn = CreateFrame("Button", nil, mainFrame)
    minimizeBtn:SetWidth(16)
    minimizeBtn:SetHeight(16)
    minimizeBtn:SetPoint("RIGHT", closeBtn, "LEFT", -4, 0)
    minimizeBtn:SetFrameLevel(mainFrame:GetFrameLevel() + 5)
    minimizeBtn:EnableMouse(true)
    minimizeBtn:RegisterForClicks("LeftButtonUp")

    minimizeBtn.icon = minimizeBtn:CreateTexture(nil, "ARTWORK")
    minimizeBtn.icon:SetTexture("Interface\\AddOns\\GoldTracker\\images\\yellow_minimize_icon_ui")
    minimizeBtn.icon:SetAllPoints()
    minimizeBtn.icon:SetVertexColor(0.8, 0.8, 0.8, 0.8)

    minimizeBtn:SetScript("OnClick", function()
        GoldTracker:MinimizeWindow()
    end)
    minimizeBtn:SetScript("OnEnter", function()
        this.icon:SetVertexColor(1, 0.843, 0, 1)
    end)
    minimizeBtn:SetScript("OnLeave", function()
        this.icon:SetVertexColor(0.8, 0.8, 0.8, 0.8)
    end)

    -- Dropdown for time range
    local dropdown = CreateFrame("Frame", "GoldTrackerDropdown", mainFrame, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", -45, -3)
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
                -- Save the range preference
                local data = InitCharacterData()
                if data then
                    data.selectedRange = rangeKey
                end
                GoldTracker:UpdateChart()
                if miniViewMode == "transactions" then
                    GoldTracker:UpdateMiniTransactions()
                else
                    GoldTracker:UpdateMiniChart()
                end
                if transactionsFrame and transactionsFrame:IsVisible() then
                    GoldTracker:UpdateTransactionList()
                end
                if statisticsFrame and statisticsFrame:IsVisible() then
                    GoldTracker:UpdateStatisticsDisplay()
                end
            end
            info.checked = (currentRange == rangeKey)
            UIDropDownMenu_AddButton(info)
        end
    end
    UIDropDownMenu_Initialize(dropdown, DropdownInit)

    -- Set initial dropdown text based on saved range
    local rangeLabel = "Last Day"
    for i, range in ipairs(RANGES) do
        if range.key == currentRange then
            rangeLabel = range.label
            break
        end
    end
    GoldTrackerDropdownText:SetText(rangeLabel)

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
    tabButtons.statistics = CreateTabButton(mainFrame, "Statistics", "statistics", 174)

    -- Tab click handlers
    tabButtons.chart:SetScript("OnClick", function()
        SwitchTab("chart")
    end)
    tabButtons.transactions:SetScript("OnClick", function()
        SwitchTab("transactions")
    end)
    tabButtons.statistics:SetScript("OnClick", function()
        SwitchTab("statistics")
    end)

    -- Set initial tab state
    tabButtons.chart:SetActive(true)
    tabButtons.transactions:SetActive(false)
    tabButtons.statistics:SetActive(false)

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

        -- Y-axis label (parent to chartFrame so it hides with the chart)
        local yLabel = chartFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
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

        -- Label (parent to chartFrame so it hides with the chart)
        local xLabel = chartFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
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

    -- Create transactions frame (in separate function to avoid upvalue limit)
    CreateTransactionsFrame()

    -- Create statistics frame (in separate function to avoid upvalue limit)
    CreateStatisticsFrame()

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

-- Create mini chart frame
local function CreateMiniFrame()
    if miniFrame then return miniFrame end

    miniFrame = CreateFrame("Frame", "GoldTrackerMiniFrame", UIParent)
    miniFrame:SetWidth(MINI_WIDTH)
    miniFrame:SetHeight(MINI_HEIGHT)
    miniFrame:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -20, -100)
    miniFrame:SetMovable(true)
    miniFrame:EnableMouse(true)
    miniFrame:SetClampedToScreen(true)
    miniFrame:SetFrameStrata("MEDIUM")
    miniFrame:SetAlpha(0.75)

    -- Background
    local bg = miniFrame:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetAllPoints()
    bg:SetVertexColor(0, 0, 0, 0.85)

    -- Border
    local border = CreateFrame("Frame", nil, miniFrame)
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
    })
    border:SetBackdropBorderColor(COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.6)

    -- Chart area
    miniFrame.chartArea = CreateFrame("Frame", nil, miniFrame)
    miniFrame.chartArea:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -18)
    miniFrame.chartArea:SetPoint("BOTTOMRIGHT", miniFrame, "BOTTOMRIGHT", -5, 5)

    -- Transactions area (hidden by default)
    miniFrame.txArea = CreateFrame("Frame", nil, miniFrame)
    miniFrame.txArea:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -18)
    miniFrame.txArea:SetPoint("BOTTOMRIGHT", miniFrame, "BOTTOMRIGHT", -5, 5)
    miniFrame.txArea:Hide()

    -- Transaction rows (4 rows to fit in mini view)
    miniFrame.txRows = {}
    local rowHeight = 14
    for i = 1, 4 do
        local row = {}
        local yOffset = -((i - 1) * rowHeight)

        -- Row container for alignment
        row.frame = CreateFrame("Frame", nil, miniFrame.txArea)
        row.frame:SetPoint("TOPLEFT", miniFrame.txArea, "TOPLEFT", 0, yOffset)
        row.frame:SetPoint("TOPRIGHT", miniFrame.txArea, "TOPRIGHT", 0, yOffset)
        row.frame:SetHeight(rowHeight)

        -- Date/time (compact, smaller font)
        row.time = row.frame:CreateFontString(nil, "OVERLAY")
        row.time:SetFont("Fonts\\FRIZQT__.TTF", 8)
        row.time:SetPoint("LEFT", row.frame, "LEFT", 0, 0)
        row.time:SetWidth(34)
        row.time:SetJustifyH("LEFT")
        row.time:SetTextColor(0.45, 0.45, 0.45, 1)

        -- Detail (source/description, smaller font)
        row.detail = row.frame:CreateFontString(nil, "OVERLAY")
        row.detail:SetFont("Fonts\\FRIZQT__.TTF", 8)
        row.detail:SetPoint("LEFT", row.time, "RIGHT", 2, 0)
        row.detail:SetWidth(110)
        row.detail:SetJustifyH("LEFT")
        row.detail:SetTextColor(0.6, 0.6, 0.6, 1)
        row.detailFull = ""

        -- Hover area for detail tooltip
        row.detailHover = CreateFrame("Button", nil, row.frame)
        row.detailHover:SetPoint("LEFT", row.time, "RIGHT", 2, 0)
        row.detailHover:SetWidth(110)
        row.detailHover:SetHeight(rowHeight)
        row.detailHover.row = row
        row.detailHover:SetScript("OnEnter", function()
            if this.row.detailFull and this.row.detailFull ~= "" then
                GameTooltip:SetOwner(this, "ANCHOR_CURSOR")
                GameTooltip:SetText(this.row.detailFull, 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        row.detailHover:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        -- Amount (right-aligned, smaller font)
        row.amount = row.frame:CreateFontString(nil, "OVERLAY")
        row.amount:SetFont("Fonts\\FRIZQT__.TTF", 9)
        row.amount:SetPoint("RIGHT", row.frame, "RIGHT", 0, 0)
        row.amount:SetWidth(36)
        row.amount:SetJustifyH("RIGHT")

        miniFrame.txRows[i] = row
    end

    -- Tab bar area
    local tabBar = CreateFrame("Frame", nil, miniFrame)
    tabBar:SetPoint("TOPLEFT", miniFrame, "TOPLEFT", 5, -3)
    tabBar:SetPoint("TOPRIGHT", miniFrame, "TOPRIGHT", -18, -3)
    tabBar:SetHeight(14)
    miniFrame.tabBar = tabBar

    -- Chart tab
    local chartTab = CreateFrame("Button", nil, tabBar)
    chartTab:SetWidth(40)
    chartTab:SetHeight(12)
    chartTab:SetPoint("LEFT", tabBar, "LEFT", 0, 0)
    chartTab.text = chartTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    chartTab.text:SetPoint("CENTER", 0, 0)
    chartTab.text:SetText("Chart")
    chartTab.text:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], 1)
    miniFrame.chartTab = chartTab

    -- Transactions tab
    local txTab = CreateFrame("Button", nil, tabBar)
    txTab:SetWidth(30)
    txTab:SetHeight(12)
    txTab:SetPoint("LEFT", chartTab, "RIGHT", 4, 0)
    txTab.text = txTab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    txTab.text:SetPoint("CENTER", 0, 0)
    txTab.text:SetText("Txns")
    txTab.text:SetTextColor(0.6, 0.6, 0.6, 1)
    miniFrame.txTab = txTab

    -- Tab click handlers
    chartTab:SetScript("OnClick", function()
        miniViewMode = "chart"
        miniFrame.chartTab.text:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], 1)
        miniFrame.txTab.text:SetTextColor(0.6, 0.6, 0.6, 1)
        miniFrame.chartArea:Show()
        miniFrame.txArea:Hide()
        GoldTracker:UpdateMiniChart()
    end)

    txTab:SetScript("OnClick", function()
        miniViewMode = "transactions"
        miniFrame.txTab.text:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], 1)
        miniFrame.chartTab.text:SetTextColor(0.6, 0.6, 0.6, 1)
        miniFrame.chartArea:Hide()
        miniFrame.txArea:Show()
        GoldTracker:UpdateMiniTransactions()
    end)

    -- Tab hover effects
    chartTab:SetScript("OnEnter", function()
        if miniViewMode ~= "chart" then
            this.text:SetTextColor(0.9, 0.9, 0.9, 1)
        end
    end)
    chartTab:SetScript("OnLeave", function()
        if miniViewMode ~= "chart" then
            this.text:SetTextColor(0.6, 0.6, 0.6, 1)
        end
    end)
    txTab:SetScript("OnEnter", function()
        if miniViewMode ~= "transactions" then
            this.text:SetTextColor(0.9, 0.9, 0.9, 1)
        end
    end)
    txTab:SetScript("OnLeave", function()
        if miniViewMode ~= "transactions" then
            this.text:SetTextColor(0.6, 0.6, 0.6, 1)
        end
    end)

    -- Current gold display (small, tucked to the right)
    miniFrame.goldText = miniFrame:CreateFontString(nil, "OVERLAY")
    miniFrame.goldText:SetFont("Fonts\\FRIZQT__.TTF", 8, "OUTLINE")
    miniFrame.goldText:SetPoint("TOPRIGHT", miniFrame, "TOPRIGHT", -14, -5)
    miniFrame.goldText:SetTextColor(0.8, 0.8, 0.8, 0.8)

    -- Restore button (small + to expand back)
    local restoreBtn = CreateFrame("Button", nil, miniFrame)
    restoreBtn:SetWidth(10)
    restoreBtn:SetHeight(10)
    restoreBtn:SetPoint("TOPRIGHT", miniFrame, "TOPRIGHT", -2, -2)
    restoreBtn.text = restoreBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    restoreBtn.text:SetPoint("CENTER", 0, 0)
    restoreBtn.text:SetText("+")
    restoreBtn.text:SetTextColor(0.7, 0.7, 0.7, 1)
    restoreBtn:SetScript("OnClick", function()
        GoldTracker:RestoreWindow()
    end)
    restoreBtn:SetScript("OnEnter", function()
        this.text:SetTextColor(1, 0.843, 0, 1)
    end)
    restoreBtn:SetScript("OnLeave", function()
        this.text:SetTextColor(0.7, 0.7, 0.7, 1)
    end)

    -- Make draggable
    miniFrame:SetScript("OnMouseDown", function()
        if arg1 == "LeftButton" then
            this:StartMoving()
        end
    end)
    miniFrame:SetScript("OnMouseUp", function()
        this:StopMovingOrSizing()
        -- Save position
        local data = InitCharacterData()
        local point, _, relPoint, x, y = this:GetPoint()
        data.miniFramePos = {point, relPoint, x, y}
    end)

    miniFrame:Hide()
    return miniFrame
end

-- Update mini chart
local miniSegmentIndex = 0

local function DrawMiniSegment(x, y)
    miniSegmentIndex = miniSegmentIndex + 1
    local tex = miniLineTextures[miniSegmentIndex]
    if not tex then
        tex = miniFrame.chartArea:CreateTexture(nil, "ARTWORK")
        tex:SetTexture("Interface\\Buttons\\WHITE8X8")
        tex:SetWidth(1.5)
        tex:SetHeight(1.5)
        miniLineTextures[miniSegmentIndex] = tex
    end
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", miniFrame.chartArea, "BOTTOMLEFT", x, y)
    tex:SetVertexColor(COLORS.line[1], COLORS.line[2], COLORS.line[3], 0.9)
    tex:Show()
end

local function DrawMiniLine(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    local length = math.sqrt(dx * dx + dy * dy)
    local steps = math.max(math.floor(length), 1)
    for i = 0, steps do
        local t = i / steps
        local x = x1 + dx * t
        local y = y1 + dy * t
        DrawMiniSegment(x, y)
    end
end

-- Mini chart fill support
local miniFillTextures = {}
local miniFillIndex = 0
local miniChartHeight = nil  -- Set during UpdateMiniChart

local function ClearMiniFill()
    for i, tex in ipairs(miniFillTextures) do
        tex:Hide()
    end
    miniFillIndex = 0
end

-- Draw mini fill column with gradient
local function DrawMiniFillColumn(x, height, colWidth)
    if height <= 1 or not miniChartHeight then return end

    local numBands = 8  -- Fewer bands for smaller chart
    local bandHeight = miniChartHeight / numBands
    local baseR, baseG, baseB = COLORS.fill[1], COLORS.fill[2], COLORS.fill[3]

    for i = 0, numBands - 1 do
        local bandBottom = i * bandHeight
        local bandTop = (i + 1) * bandHeight

        if bandBottom < height then
            local segmentBottom = bandBottom
            local segmentTop = math.min(bandTop, height)
            local segmentHeight = segmentTop - segmentBottom

            if segmentHeight > 0 then
                local t = (i + 0.5) / numBands
                local brightness = 0.08 + (t * t * 0.55)

                miniFillIndex = miniFillIndex + 1
                local tex = miniFillTextures[miniFillIndex]
                if not tex then
                    tex = miniFrame.chartArea:CreateTexture(nil, "ARTWORK", nil, -1)
                    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
                    miniFillTextures[miniFillIndex] = tex
                end
                tex:ClearAllPoints()
                tex:SetWidth(colWidth)
                tex:SetHeight(segmentHeight)
                tex:SetPoint("BOTTOMLEFT", miniFrame.chartArea, "BOTTOMLEFT", x, segmentBottom)
                tex:SetVertexColor(baseR * brightness, baseG * brightness, baseB * brightness, 1)
                tex:Show()
            end
        end
    end
end

-- Draw mini filled area between two points
local function DrawMiniFillArea(x1, y1, x2, y2)
    local startX = math.floor(x1)
    local endX = math.floor(x2)
    local width = endX - startX

    if width <= 0 then return end

    local colStep = 2
    local colWidth = 2  -- Match step size exactly (no spillover)

    for i = 0, width, colStep do
        local t = width > 0 and (i / width) or 0
        local height = y1 + (y2 - y1) * t + 1  -- Add 1px to reach the line
        DrawMiniFillColumn(startX + i, height, colWidth)
    end
end

function GoldTracker:UpdateMiniChart()
    if not miniFrame or not miniFrame:IsVisible() then return end

    -- Clear old lines and fill
    for i, tex in ipairs(miniLineTextures) do
        tex:Hide()
    end
    miniSegmentIndex = 0
    ClearMiniFill()

    -- Get history data
    local data = InitCharacterData()
    if not data then return end
    local history = GetFilteredHistory()
    local count = table.getn(history)

    -- Update net profit text based on selected period
    local currentGold = GetMoney()
    local netChange = 0
    if count > 0 then
        netChange = currentGold - history[1].gold
    end
    local netGold = math.floor(math.abs(netChange) / 10000)
    local netSilver = math.floor(math.mod(math.abs(netChange), 10000) / 100)
    local prefix = netChange >= 0 and "+" or "-"
    if netGold > 0 then
        miniFrame.goldText:SetText(prefix .. netGold .. "g " .. netSilver .. "s")
    else
        miniFrame.goldText:SetText(prefix .. netSilver .. "s")
    end
    if netChange >= 0 then
        miniFrame.goldText:SetTextColor(0.5, 0.95, 0.5, 1)
    else
        miniFrame.goldText:SetTextColor(0.95, 0.5, 0.5, 1)
    end

    if count < 2 then return end

    -- Calculate bounds
    local minGold, maxGold = history[1].gold, history[1].gold
    local minTime, maxTime = history[1].timestamp, history[count].timestamp

    for i, entry in ipairs(history) do
        if entry.gold < minGold then minGold = entry.gold end
        if entry.gold > maxGold then maxGold = entry.gold end
    end

    local goldRange = maxGold - minGold
    if goldRange == 0 then goldRange = 1 end
    local timeRange = maxTime - minTime
    if timeRange == 0 then timeRange = 1 end

    -- Add padding
    local padding = goldRange * 0.1
    minGold = minGold - padding
    maxGold = maxGold + padding
    goldRange = maxGold - minGold

    -- Chart dimensions
    local chartWidth = MINI_WIDTH - 10
    local chartHeight = MINI_HEIGHT - 23
    miniChartHeight = chartHeight  -- Set for gradient calculations

    -- Draw fill first, then lines on top
    local maxPoints = 50  -- More points for better detail
    local step = math.max(1, math.floor(count / maxPoints))
    local lastX, lastY = nil, nil

    -- First pass: draw fill
    for i = 1, count, step do
        local entry = history[i]
        local x = ((entry.timestamp - minTime) / timeRange) * chartWidth
        local y = ((entry.gold - minGold) / goldRange) * chartHeight

        if lastX then
            DrawMiniFillArea(lastX, lastY, x, y)
        end

        lastX, lastY = x, y
    end

    -- Ensure last point is included for fill
    if step > 1 and count > 0 then
        local entry = history[count]
        local x = ((entry.timestamp - minTime) / timeRange) * chartWidth
        local y = ((entry.gold - minGold) / goldRange) * chartHeight
        if lastX and lastY and x > lastX then
            DrawMiniFillArea(lastX, lastY, x, y)
        end
        lastX, lastY = x, y
    end

    -- Fill to right edge
    if lastX and lastY then
        DrawMiniFillArea(lastX, lastY, chartWidth, lastY)
    end

    -- Second pass: draw lines
    lastX, lastY = nil, nil
    for i = 1, count, step do
        local entry = history[i]
        local x = ((entry.timestamp - minTime) / timeRange) * chartWidth
        local y = ((entry.gold - minGold) / goldRange) * chartHeight

        if lastX then
            DrawMiniLine(lastX, lastY, x, y)
        end

        lastX, lastY = x, y
    end

    -- Ensure last point is included for line
    if step > 1 and count > 0 then
        local entry = history[count]
        local x = ((entry.timestamp - minTime) / timeRange) * chartWidth
        local y = ((entry.gold - minGold) / goldRange) * chartHeight
        if lastX and lastY then
            DrawMiniLine(lastX, lastY, x, y)
        end
        lastX, lastY = x, y
    end

    -- Extend line to right edge of chart
    if lastX and lastY then
        DrawMiniLine(lastX, lastY, chartWidth + 1, lastY)
    end
end

-- Format compact time for mini view (e.g., "2:34p")
local function FormatMiniTime(timestamp)
    local d = date("*t", timestamp)
    local hour = d.hour
    local ampm = "a"
    if hour >= 12 then
        ampm = "p"
        if hour > 12 then hour = hour - 12 end
    end
    if hour == 0 then hour = 12 end
    return hour .. ":" .. string.format("%02d", d.min) .. ampm
end

-- Update mini transactions view
function GoldTracker:UpdateMiniTransactions()
    if not miniFrame or not miniFrame:IsVisible() then return end
    if not miniFrame.txRows then return end

    -- Get transactions (most recent first)
    local transactions = self:GetFilteredTransactions()
    local count = table.getn(transactions)

    -- Update gold text same as chart view
    local data = InitCharacterData()
    if data then
        local history = GetFilteredHistory()
        local histCount = table.getn(history)
        local currentGold = GetMoney()
        local netChange = 0
        if histCount > 0 then
            netChange = currentGold - history[1].gold
        end
        local netGold = math.floor(math.abs(netChange) / 10000)
        local netSilver = math.floor(math.mod(math.abs(netChange), 10000) / 100)
        local prefix = netChange >= 0 and "+" or "-"
        if netGold > 0 then
            miniFrame.goldText:SetText(prefix .. netGold .. "g " .. netSilver .. "s")
        else
            miniFrame.goldText:SetText(prefix .. netSilver .. "s")
        end
        if netChange >= 0 then
            miniFrame.goldText:SetTextColor(0.5, 0.95, 0.5, 1)
        else
            miniFrame.goldText:SetTextColor(0.95, 0.5, 0.5, 1)
        end
    end

    -- Populate rows (show most recent 4 transactions)
    for i = 1, 4 do
        local row = miniFrame.txRows[i]
        if i <= count then
            local tx = transactions[i]

            -- Time (compact format)
            row.time:SetText(FormatMiniTime(tx.timestamp))

            -- Detail - show source or detail if available
            local detailText = tx.detail or ""
            if detailText == "" then
                detailText = tx.source or ""
                detailText = string.upper(string.sub(detailText, 1, 1)) .. string.sub(detailText, 2)
            end
            -- Store full text for tooltip
            row.detailFull = detailText
            -- Truncate for mini view
            if string.len(detailText) > 26 then
                detailText = string.sub(detailText, 1, 25) .. ".."
            end
            row.detail:SetText(detailText)

            -- Amount (compact: gold, silver, or copper)
            local absAmount = math.abs(tx.amount)
            local gold = math.floor(absAmount / 10000)
            local silver = math.floor(math.mod(absAmount, 10000) / 100)
            local copper = math.mod(absAmount, 100)
            local sign = tx.amount >= 0 and "+" or "-"
            local amountText
            if gold > 0 then
                amountText = sign .. gold .. "g"
            elseif silver > 0 then
                amountText = sign .. silver .. "s"
            else
                amountText = sign .. copper .. "c"
            end
            row.amount:SetText(amountText)

            -- Color based on gain/loss
            if tx.amount >= 0 then
                row.amount:SetTextColor(COLORS.positive[1], COLORS.positive[2], COLORS.positive[3], 1)
            else
                row.amount:SetTextColor(COLORS.negative[1], COLORS.negative[2], COLORS.negative[3], 1)
            end

            row.time:Show()
            row.detail:Show()
            row.amount:Show()
        else
            row.time:SetText("")
            row.detail:SetText("")
            row.amount:SetText("")
        end
    end
end

-- Minimize window
function GoldTracker:MinimizeWindow()
    if not miniFrame then
        CreateMiniFrame()
    end

    -- Restore mini frame position
    local data = InitCharacterData()
    if data.miniFramePos then
        miniFrame:ClearAllPoints()
        miniFrame:SetPoint(data.miniFramePos[1], UIParent, data.miniFramePos[2], data.miniFramePos[3], data.miniFramePos[4])
    end

    mainFrame:Hide()
    miniFrame:Show()
    isMinimized = true

    -- Update view based on current mode
    if miniViewMode == "transactions" then
        miniFrame.chartArea:Hide()
        miniFrame.txArea:Show()
        miniFrame.txTab.text:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], 1)
        miniFrame.chartTab.text:SetTextColor(0.6, 0.6, 0.6, 1)
        GoldTracker:UpdateMiniTransactions()
    else
        miniFrame.chartArea:Show()
        miniFrame.txArea:Hide()
        miniFrame.chartTab.text:SetTextColor(COLORS.gold[1], COLORS.gold[2], COLORS.gold[3], 1)
        miniFrame.txTab.text:SetTextColor(0.6, 0.6, 0.6, 1)
        GoldTracker:UpdateMiniChart()
    end
end

-- Restore window from minimized
function GoldTracker:RestoreWindow()
    if miniFrame then
        miniFrame:Hide()
    end

    -- Restore main frame position
    local data = InitCharacterData()
    if data.framePos then
        mainFrame:ClearAllPoints()
        mainFrame:SetPoint(data.framePos[1], UIParent, data.framePos[2], data.framePos[3], data.framePos[4])
    end

    mainFrame:Show()
    isMinimized = false
    GoldTracker:UpdateChart()
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

        -- Helper function to queue auction mail (prevents duplicate code)
        local function QueueAuctionMail(mailIndex, source)
            local _, _, sender, subject, money = GetInboxHeaderInfo(mailIndex)
            if sender then
                currentMailSender = sender
                local lowerSender = string.lower(sender)
                local isAuction = string.find(lowerSender, "auction")
                if isAuction then
                    currentMailIsAuction = true
                    currentMailSubject = subject
                    -- Check for duplicate: same mailIndex already queued recently
                    local dominated = false
                    for i = 1, table.getn(pendingMailQueue) do
                        if pendingMailQueue[i].mailIndex == mailIndex then
                            dominated = true
                            MailDebug("[" .. source .. "] Skipping duplicate mail index " .. mailIndex)
                            break
                        end
                    end
                    if not dominated then
                        table.insert(pendingMailQueue, {
                            sender = sender,
                            subject = subject,
                            isAuction = true,
                            money = money,
                            mailIndex = mailIndex
                        })
                        MailDebug("[" .. source .. "] Queued mail #" .. table.getn(pendingMailQueue) .. " (idx:" .. mailIndex .. "): " .. (subject or "no subject") .. " (" .. (money or 0) .. "c)")
                    end
                else
                    currentMailIsAuction = false
                    currentMailSubject = nil
                end
            end
        end

        -- Hook TakeInboxMoney to capture sender before money is taken
        if TakeInboxMoney and not originalTakeInboxMoney then
            originalTakeInboxMoney = TakeInboxMoney
            TakeInboxMoney = function(mailIndex)
                QueueAuctionMail(mailIndex, "Global")
                return originalTakeInboxMoney(mailIndex)
            end
        end

        -- Also hook TurtleMail's stored reference if it exists
        if TurtleMail and TurtleMail.TakeInboxMoney then
            local turtleMailOriginal = TurtleMail.TakeInboxMoney
            TurtleMail.TakeInboxMoney = function(mailIndex)
                QueueAuctionMail(mailIndex, "TurtleMail")
                return turtleMailOriginal(mailIndex)
            end
        end

        -- Hook RepairAllItems to detect repair costs
        if RepairAllItems and not originalRepairAllItems then
            originalRepairAllItems = RepairAllItems
            RepairAllItems = function(useGuildBank)
                pendingRepair = true
                return originalRepairAllItems(useGuildBank)
            end
        end

        -- Hook PlaceAuctionBid to capture item name when buying at AH
        if PlaceAuctionBid and not originalPlaceAuctionBid then
            originalPlaceAuctionBid = PlaceAuctionBid
            PlaceAuctionBid = function(auctionType, index, bid)
                -- Capture the item name before placing bid/buyout
                local name = GetAuctionItemInfo(auctionType, index)
                if name then
                    pendingAuctionItem = name
                end
                return originalPlaceAuctionBid(auctionType, index, bid)
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Initialize session
        sessionStart = time()
        sessionStartGold = GetMoney()

        -- Initialize data and record starting point
        local data = InitCharacterData()
        RecordGold()

        -- Restore saved range preference (default to "1day")
        if data and data.selectedRange then
            currentRange = data.selectedRange
        else
            currentRange = "1day"
        end

        -- Create minimap button
        CreateMinimapButton()

        -- Create main frame (needed for mini frame to work)
        CreateMainFrame()

        -- Automatically show the minimized view on login
        GoldTracker:MinimizeWindow()

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
            local detail = transactionDetail

            -- Fallback: Check if quest frame is visible (quest reward)
            if source == "unknown" and delta > 0 then
                if QuestFrame and QuestFrame:IsVisible() then
                    source = "quest"
                    detail = GetTitleText()
                elseif QuestFrameRewardPanel and QuestFrameRewardPanel:IsVisible() then
                    source = "quest"
                    detail = GetTitleText()
                end
            end

            -- Detect repair vs vendor
            if source == "vendor" and delta < 0 and pendingRepair then
                source = "repair"
                pendingRepair = false
            end

            -- Try to get trade partner name at transaction time if not captured earlier
            if source == "trade" and not detail then
                if TradeFrameRecipientNameText then
                    detail = TradeFrameRecipientNameText:GetText()
                end
                if not detail then
                    detail = UnitName("target")
                end
            end

            -- Handle auction house purchases (buying items directly)
            if source == "auction" and delta < 0 and pendingAuctionItem then
                detail = pendingAuctionItem
                pendingAuctionItem = nil
            end

            -- Try to get mail sender/recipient name
            if source == "mail" then
                if delta < 0 then
                    -- Sending mail - get recipient from send box
                    if SendMailNameEditBox then
                        detail = SendMailNameEditBox:GetText()
                    end
                else
                    -- Receiving mail - check queue first (for batch processing)
                    local usedQueue = false
                    if table.getn(pendingMailQueue) > 0 then
                        local mailData = table.remove(pendingMailQueue, 1)
                        MailDebug("Popped from queue: " .. (mailData.subject or "no subject") .. " (queue size now: " .. table.getn(pendingMailQueue) .. ")")
                        if mailData.isAuction and mailData.subject then
                            source = "auction"
                            detail = mailData.subject
                            detail = string.gsub(detail, "^Auction successful: ", "")
                            detail = string.gsub(detail, "^Auction won: ", "")
                            detail = string.gsub(detail, "^Sale pending: ", "")
                            detail = string.gsub(detail, "^Outbid on ", "")
                            detail = string.gsub(detail, "^Auction expired: ", "")
                            MailDebug("Recording auction sale: " .. detail .. " for " .. delta .. "c")
                            usedQueue = true
                        else
                            detail = mailData.sender
                            usedQueue = true
                        end
                    end
                    -- Fallback to single-variable logic (for manual mail opening)
                    if not usedQueue then
                        if currentMailIsAuction and currentMailSubject then
                            source = "auction"
                            detail = currentMailSubject
                            detail = string.gsub(detail, "^Auction successful: ", "")
                            detail = string.gsub(detail, "^Auction won: ", "")
                            detail = string.gsub(detail, "^Sale pending: ", "")
                            detail = string.gsub(detail, "^Outbid on ", "")
                            detail = string.gsub(detail, "^Auction expired: ", "")
                            MailDebug("[Fallback] Recording auction sale: " .. detail)
                        elseif not detail then
                            detail = currentMailSender
                        end
                    end
                end
            end

            RecordTransaction(delta, source, detail)
        end

        RecordGold()

    -- Context tracking
    elseif event == "MERCHANT_SHOW" then
        transactionContext = "vendor"
        transactionDetail = UnitName("npc")
    elseif event == "MERCHANT_CLOSED" then
        transactionContext = nil
        transactionDetail = nil
        pendingRepair = false  -- Reset repair flag on merchant close
    elseif event == "AUCTION_HOUSE_SHOW" then
        transactionContext = "auction"
        transactionDetail = nil
    elseif event == "AUCTION_HOUSE_CLOSED" then
        transactionContext = nil
        transactionDetail = nil
        pendingAuctionItem = nil
    elseif event == "MAIL_SHOW" then
        transactionContext = "mail"
        transactionDetail = nil
        currentMailSender = nil
        -- Start watching for open mail to capture sender
        if not GoldTracker.mailWatcher then
            GoldTracker.mailWatcher = CreateFrame("Frame")
        end
        GoldTracker.mailWatcher:SetScript("OnUpdate", function()
            -- Check if a mail is open and capture the sender
            if OpenMailFrame and OpenMailFrame:IsVisible() then
                if OpenMailSender then
                    local sender = OpenMailSender:GetText()
                    if sender and sender ~= "" then
                        currentMailSender = sender
                    end
                end
            end
        end)
    elseif event == "MAIL_CLOSED" then
        transactionContext = nil
        transactionDetail = nil
        currentMailSender = nil
        currentMailIsAuction = false
        currentMailSubject = nil
        -- Clear mail queue and log if there were leftover entries
        if table.getn(pendingMailQueue) > 0 then
            MailDebug("Clearing mail queue on close (" .. table.getn(pendingMailQueue) .. " items remaining)")
        end
        pendingMailQueue = {}
        -- Stop mail watcher
        if GoldTracker.mailWatcher then
            GoldTracker.mailWatcher:SetScript("OnUpdate", nil)
        end
    elseif event == "TRADE_SHOW" then
        transactionContext = "trade"
        -- Get trade partner name from the trade frame UI
        if TradeFrameRecipientNameText then
            transactionDetail = TradeFrameRecipientNameText:GetText()
        else
            transactionDetail = UnitName("target")
        end
    elseif event == "TRADE_CLOSED" then
        -- Delay clearing trade context so PLAYER_MONEY can capture it
        if not GoldTracker.tradeTimer then
            GoldTracker.tradeTimer = CreateFrame("Frame")
        end
        GoldTracker.tradeTimer.elapsed = 0
        GoldTracker.tradeTimer:SetScript("OnUpdate", function()
            this.elapsed = this.elapsed + arg1
            if this.elapsed > 0.5 then
                if transactionContext == "trade" then
                    transactionContext = nil
                    transactionDetail = nil
                end
                this:SetScript("OnUpdate", nil)
            end
        end)
    elseif event == "TRAINER_SHOW" then
        transactionContext = "training"
        transactionDetail = UnitName("npc")
    elseif event == "TRAINER_CLOSED" then
        transactionContext = nil
        transactionDetail = nil
    elseif event == "QUEST_COMPLETE" then
        transactionContext = "quest"
        transactionDetail = GetTitleText()
        -- Clear quest context after 30 seconds (gives time to read rewards and select items)
        if not GoldTracker.questTimer then
            GoldTracker.questTimer = CreateFrame("Frame")
        end
        GoldTracker.questTimer.elapsed = 0
        GoldTracker.questTimer:SetScript("OnUpdate", function()
            this.elapsed = this.elapsed + arg1
            if this.elapsed > 30 then
                if transactionContext == "quest" then
                    transactionContext = nil
                    transactionDetail = nil
                end
                this:SetScript("OnUpdate", nil)
            end
        end)
    elseif event == "CHAT_MSG_MONEY" then
        -- Only set loot context if no other context is active (don't overwrite quest, etc.)
        if not transactionContext then
            transactionContext = "loot"
            transactionDetail = UnitName("target")
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
                        transactionDetail = nil
                    end
                    this:SetScript("OnUpdate", nil)
                end
            end)
        end
    end
end)

-- Slash commands
SLASH_GOLDTRACKER1 = "/goldtracker"
SLASH_GOLDTRACKER2 = "/gt"
SlashCmdList["GOLDTRACKER"] = function(msg)
    local cmd = string.lower(msg or "")
    if cmd == "debug" then
        MAIL_DEBUG = not MAIL_DEBUG
        if MAIL_DEBUG then
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd700GoldTracker|r: Mail debug logging |cff00ff00enabled|r")
        else
            DEFAULT_CHAT_FRAME:AddMessage("|cffffd700GoldTracker|r: Mail debug logging |cffff0000disabled|r")
        end
    elseif cmd == "help" then
        DEFAULT_CHAT_FRAME:AddMessage("|cffffd700GoldTracker commands:|r")
        DEFAULT_CHAT_FRAME:AddMessage("  /gt - Toggle main window")
        DEFAULT_CHAT_FRAME:AddMessage("  /gt debug - Toggle mail debug logging")
        DEFAULT_CHAT_FRAME:AddMessage("  /gt help - Show this help")
    else
        ToggleWindow()
    end
end
