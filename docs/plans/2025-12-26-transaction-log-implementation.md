# Transaction Log Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a tabbed interface with a Transactions tab showing a paginated, filterable table of gold changes with source detection.

**Architecture:** Extend the existing single-frame UI with tab switching, add context-based event tracking to detect transaction sources, store transactions separately from history snapshots, and migrate historical data on first load.

**Tech Stack:** WoW 1.12.1 Lua API, no external dependencies. Manual in-game testing.

---

## Task 1: Add Transaction Data Structure and Constants

**Files:**
- Modify: `GoldTracker.lua:1-50` (constants section)

**Step 1: Add transaction source constants after COLORS table**

Add after line 42 (after COLORS table closing brace):

```lua
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

local TRANSACTIONS_PER_PAGE = 15
```

**Step 2: Add state variables after existing locals (around line 19)**

Add after `local currentRange = "all"`:

```lua
local currentTab = "chart"  -- "chart" or "transactions"
local transactionContext = nil  -- Current context for source detection
local activeFilters = {}  -- Which sources are visible
local currentPage = 1
local transactionsFrame = nil
local tabButtons = {}
```

**Step 3: Verify in-game**

Run: `/reload` in WoW
Expected: No errors, addon loads normally

**Step 4: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: add transaction constants and state variables"
```

---

## Task 2: Add Transaction Recording Function

**Files:**
- Modify: `GoldTracker.lua` (after FormatTooltipTime function, around line 148)

**Step 1: Add RecordTransaction function**

Add after the `IsSameDay` function (around line 155):

```lua
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
```

**Step 2: Verify in-game**

Run: `/reload` in WoW
Expected: No errors, addon loads normally

**Step 3: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: add RecordTransaction function"
```

---

## Task 3: Add Historical Data Migration

**Files:**
- Modify: `GoldTracker.lua` (in InitCharacterData function, around line 157-168)

**Step 1: Add migration logic to InitCharacterData**

Replace the InitCharacterData function:

```lua
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
```

**Step 2: Verify in-game**

Run: `/reload` in WoW
Expected: No errors. If you have existing history, `/dump GoldTrackerDB` should show transactions table populated.

**Step 3: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: add historical data migration to transactions"
```

---

## Task 4: Add Context Tracking Events

**Files:**
- Modify: `GoldTracker.lua` (event registration around line 907, event handler around line 911)

**Step 1: Register new events for context tracking**

Replace the event registration block (around line 907-909):

```lua
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
```

**Step 2: Add helper function to check if player has damaged gear**

Add before the event handler (before `GoldTracker:SetScript("OnEvent"`):

```lua
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
```

**Step 3: Update the event handler**

Replace the SetScript OnEvent block:

```lua
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
        -- Quest context clears after short delay (gold awarded on accept)
    elseif event == "CHAT_MSG_MONEY" then
        -- Loot gold message - set context briefly
        transactionContext = "loot"
    end
end)
```

**Step 4: Verify in-game**

Run: `/reload` in WoW
Test: Loot some gold, sell an item to vendor, check `/dump GoldTrackerDB` for transaction entries with correct sources

**Step 5: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: add context tracking for transaction sources"
```

---

## Task 5: Create Tab Bar UI

**Files:**
- Modify: `GoldTracker.lua` (in CreateMainFrame function, around line 529)

**Step 1: Add tab creation helper function**

Add before CreateMainFrame (around line 528):

```lua
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
```

**Step 2: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: add tab button creation helper"
```

---

## Task 6: Integrate Tabs into Main Frame

**Files:**
- Modify: `GoldTracker.lua` (in CreateMainFrame, update constants and frame setup)

**Step 1: Update frame constants at top of file**

Replace the constants block (lines 21-29):

```lua
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
```

**Step 2: Add tab switching function before CreateMainFrame**

Add after CreateTabButton function:

```lua
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
```

**Step 3: Add tabs to CreateMainFrame**

In CreateMainFrame, after the dropdown setup (around line 621), add:

```lua
    -- Tab bar separator line
    local tabBarLine = mainFrame:CreateTexture(nil, "ARTWORK")
    tabBarLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    tabBarLine:SetHeight(1)
    tabBarLine:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", 0, -47)
    tabBarLine:SetPoint("TOPRIGHT", mainFrame, "TOPRIGHT", 0, -47)
    tabBarLine:SetVertexColor(COLORS.border[1], COLORS.border[2], COLORS.border[3], 0.8)

    -- Create tabs
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
```

**Step 4: Update chartFrame position in CreateMainFrame**

The chartFrame creation line should already use CHART_TOP_OFFSET which we updated. Verify it says:

```lua
    chartFrame:SetPoint("TOPLEFT", mainFrame, "TOPLEFT", CHART_PADDING_LEFT, -CHART_TOP_OFFSET)
```

**Step 5: Verify in-game**

Run: `/reload` in WoW, open GoldTracker with `/gt`
Expected: See two tabs at top - "Chart" (active) and "Transactions" (inactive). Clicking them should toggle visuals.

**Step 6: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: integrate tab bar into main frame"
```

---

## Task 7: Create Transactions Frame Structure

**Files:**
- Modify: `GoldTracker.lua` (add after statsFrame creation in CreateMainFrame)

**Step 1: Add transactions frame creation**

Add after the statsFrame setup and before `mainFrame:Hide()` (around line 788):

```lua
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

    -- Table container
    transactionsFrame.tableFrame = CreateFrame("Frame", nil, transactionsFrame)
    transactionsFrame.tableFrame:SetPoint("TOPLEFT", transactionsFrame.filterBar, "BOTTOMLEFT", 0, -4)
    transactionsFrame.tableFrame:SetPoint("BOTTOMRIGHT", transactionsFrame, "BOTTOMRIGHT", 0, 24)

    -- Table background
    local tableBg = transactionsFrame.tableFrame:CreateTexture(nil, "BACKGROUND")
    tableBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    tableBg:SetAllPoints()
    tableBg:SetVertexColor(0.05, 0.05, 0.05, 0.5)

    -- Pagination container
    transactionsFrame.pagination = CreateFrame("Frame", nil, transactionsFrame)
    transactionsFrame.pagination:SetPoint("BOTTOMLEFT", transactionsFrame, "BOTTOMLEFT", 0, 0)
    transactionsFrame.pagination:SetPoint("BOTTOMRIGHT", transactionsFrame, "BOTTOMRIGHT", 0, 0)
    transactionsFrame.pagination:SetHeight(20)
```

**Step 2: Verify in-game**

Run: `/reload` in WoW, `/gt` to open
Expected: Clicking "Transactions" tab shows empty area (frame structure exists but no content yet)

**Step 3: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: create transactions frame structure"
```

---

## Task 8: Create Filter Bar Toggle Buttons

**Files:**
- Modify: `GoldTracker.lua` (add filter button creation in transactionsFrame setup)

**Step 1: Add filter toggle creation**

Add after the transactionsFrame.filterBar creation, before tableFrame:

```lua
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

        -- Border
        btn.border = btn:CreateTexture(nil, "OVERLAY")
        btn.border:SetTexture("Interface\\Buttons\\WHITE8X8")
        btn.border:SetPoint("TOPLEFT", -1, 1)
        btn.border:SetPoint("BOTTOMRIGHT", 1, -1)
        btn.border:SetVertexColor(0.3, 0.3, 0.3, 1)
        btn:SetFrameLevel(btn.border:GetDrawLayer() == "OVERLAY" and btn:GetFrameLevel() + 1 or btn:GetFrameLevel())

        -- Reparent so border is behind icon
        btn.border:SetDrawLayer("BORDER")

        btn.sourceKey = source.key

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
                    self.border:SetVertexColor(COLORS.border[1], COLORS.border[2], COLORS.border[3], 1)
                else
                    self.icon:SetVertexColor(0.5, 0.5, 0.5, 1)
                    self.border:SetVertexColor(0.3, 0.3, 0.3, 1)
                end
            else
                if activeFilters[self.sourceKey] then
                    self.icon:SetVertexColor(1, 1, 1, 1)
                    self.border:SetVertexColor(COLORS.border[1], COLORS.border[2], COLORS.border[3], 1)
                else
                    self.icon:SetVertexColor(0.3, 0.3, 0.3, 1)
                    self.border:SetVertexColor(0.2, 0.2, 0.2, 1)
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
            GameTooltip:SetText(source.label, 1, 1, 1)
            GameTooltip:Show()
        end)

        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        transactionsFrame.filterButtons[source.key] = btn
        btn:UpdateState()
    end
```

**Step 2: Verify in-game**

Run: `/reload` in WoW, `/gt`, click Transactions tab
Expected: See row of filter icons. Clicking toggles their appearance.

**Step 3: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: add filter bar toggle buttons"
```

---

## Task 9: Create Table Headers and Row Frames

**Files:**
- Modify: `GoldTracker.lua` (continue transactions frame setup)

**Step 1: Add table headers and rows**

Add after the filter buttons loop, before pagination container:

```lua
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
```

**Step 2: Verify in-game**

Run: `/reload` in WoW, `/gt`, Transactions tab
Expected: See column headers (Time, Amount, Source, Balance) with underline

**Step 3: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: add transaction table headers and row frames"
```

---

## Task 10: Create Pagination Controls

**Files:**
- Modify: `GoldTracker.lua` (add pagination UI elements)

**Step 1: Add pagination controls**

Add after the row frames loop, in the transactionsFrame setup:

```lua
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
```

**Step 2: Verify in-game**

Run: `/reload` in WoW, `/gt`, Transactions tab
Expected: See "Page 1 of 1" text and Prev/Next buttons at bottom

**Step 3: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: add pagination controls"
```

---

## Task 11: Implement Transaction Filtering and List Update

**Files:**
- Modify: `GoldTracker.lua` (add filtering and update functions)

**Step 1: Add GetFilteredTransactions function**

Add before UpdateChart function (around line 306):

```lua
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
```

**Step 2: Verify in-game**

Run: `/reload` in WoW
Test: `/gt`, click Transactions tab. Should see any existing transactions (or "Page 1 of 1" with empty rows if none).
Test: Change time range dropdown - transactions should filter.
Test: Click filter buttons - transactions should filter.
Test: Loot gold, check that new transaction appears.

**Step 3: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: implement transaction filtering and list update"
```

---

## Task 12: Hook Time Range Dropdown to Refresh Transactions

**Files:**
- Modify: `GoldTracker.lua` (update dropdown callback)

**Step 1: Update dropdown callback to refresh transactions**

Find the dropdown init function (around line 602-616) and update the info.func:

```lua
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
```

**Step 2: Verify in-game**

Run: `/reload` in WoW
Test: Open GoldTracker, go to Transactions tab, change time range - list should update

**Step 3: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: hook time range dropdown to refresh transactions"
```

---

## Task 13: Clear Quest Context After Delay

**Files:**
- Modify: `GoldTracker.lua` (add timer to clear quest context)

**Step 1: Add quest context clearing**

In the event handler, update the QUEST_COMPLETE case:

```lua
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
```

**Step 2: Similarly update loot context clearing**

Update the CHAT_MSG_MONEY case:

```lua
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
```

**Step 3: Verify in-game**

Run: `/reload` in WoW
Test: Complete a quest with gold reward - should be marked as "quest"
Test: Loot gold - should be marked as "loot"

**Step 4: Commit**

```bash
git add GoldTracker.lua
git commit -m "feat: add context clearing timers for quest and loot"
```

---

## Task 14: Final Testing and Cleanup

**Step 1: Full integration test**

Test the following scenarios in-game:
1. Open `/gt` - chart tab works as before
2. Click Transactions tab - shows transaction list
3. Filter buttons toggle and filter correctly
4. Time range dropdown affects both chart and transactions
5. Pagination works with many transactions
6. Loot gold - appears with "Loot" source
7. Sell to vendor - appears with "Vendor" source
8. Buy from vendor - appears with "Vendor" source
9. Get mail gold - appears with "Mail" source
10. Complete quest - appears with "Quest" source
11. Train spell - appears with "Training" source
12. Historical data shows "Historical" source

**Step 2: Fix any issues found during testing**

**Step 3: Final commit**

```bash
git add GoldTracker.lua
git commit -m "feat: complete transaction log feature

Adds tabbed interface with Chart and Transactions tabs.
Transactions tab displays paginated, filterable list of gold changes.
Source detection for: loot, vendor, auction, mail, trade, quest, training.
Historical data migration from existing snapshots.
Filter bar with toggle buttons for each source type.
Time range filter applies to both views."
```

---

## Summary

This plan adds:
- **13 implementation tasks** building incrementally
- **Tabbed interface** switching between Chart and Transactions views
- **Source detection** via context tracking on UI events
- **Historical migration** computing transactions from existing snapshots
- **Filter bar** with visual toggle buttons per source
- **Paginated table** with Time, Amount, Source, Balance columns
- **Shared time range filter** affecting both tabs
