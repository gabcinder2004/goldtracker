# Transaction Log Feature Design

## Overview

Add a tabbed interface to GoldTracker with a new "Transactions" tab that displays a paginated table of gold changes, including source detection for new transactions and computed changes for historical data.

## Data Model

### New transaction storage structure

```lua
GoldTrackerDB[charKey] = {
    history = { ... },           -- existing snapshots (unchanged)
    transactions = {             -- NEW: detailed transaction log
        {
            timestamp = 1234567890,
            amount = 5000,           -- copper, positive = gain, negative = loss
            source = "loot",         -- loot|vendor|auction|mail|trade|quest|training|repair|unknown|historical
            balance = 1500000,       -- running balance after this transaction
        },
        ...
    }
}
```

### Transaction sources

| Source | Description |
|--------|-------------|
| loot | Gold picked up from corpses/chests |
| vendor | Selling/buying items from NPCs |
| auction | AH sales, purchases, deposits, refunds |
| mail | Gold received/sent via mailbox |
| trade | Player-to-player trades |
| quest | Quest reward gold |
| training | Spell/skill training costs |
| repair | Armor repair costs |
| unknown | Gold change with no detected context |
| historical | Computed from legacy history data |

## UI Design

### Tabbed Interface

- Two tabs: "Chart" | "Transactions" at top-left below title
- Active tab: highlighted gold border
- Inactive tab: dimmed, clickable
- Time range dropdown shared by both tabs (applies to both views)
- Window height increases ~20px for tab bar

### Transactions Tab Layout

**Filter bar (24px height):**
- Horizontal row of toggle buttons for each source
- Icons: All (checkmark), Loot (coin), Vendor (bag), Auction (gavel), Mail (envelope), Trade (handshake), Quest (!), Training (book), Repair (anvil)
- Active = gold tint, inactive = dimmed
- "All" button toggles all sources on/off

**Table:**
- Columns: Time (90px) | Amount (85px) | Source (70px) | Balance (85px)
- 15 rows per page
- Row height: ~16px (GameFontNormalSmall)
- Newest transactions first (no sorting)

**Amount formatting:**
- Positive: Green with + prefix
- Negative: Red with - prefix

**Pagination controls:**
- Left: "Page 1 of 12"
- Right: "< Prev" | "Next >" buttons
- Buttons disabled at first/last page

## Event Handling

### Context tracking

Track UI context to determine transaction source when PLAYER_MONEY fires:

```lua
local transactionContext = nil

-- Flow:
-- 1. Player opens mailbox -> MAIL_SHOW -> context = "mail"
-- 2. Player takes gold -> PLAYER_MONEY -> record with source "mail"
-- 3. Player closes mailbox -> MAIL_CLOSED -> context = nil
```

### Events to hook

| Context | Open Event | Close Event |
|---------|-----------|-------------|
| vendor | MERCHANT_SHOW | MERCHANT_CLOSED |
| repair | MERCHANT_SHOW (+ durability check) | MERCHANT_CLOSED |
| auction | AUCTION_HOUSE_SHOW | AUCTION_HOUSE_CLOSED |
| mail | MAIL_SHOW | MAIL_CLOSED |
| trade | TRADE_SHOW | TRADE_CLOSED |
| training | TRAINER_SHOW | TRAINER_CLOSED |
| loot | CHAT_MSG_LOOT / CHAT_MSG_MONEY | - |
| quest | QUEST_COMPLETE | - |

### Repair detection

When at a vendor (MERCHANT_SHOW), if gold decreases and player has damaged gear, mark as "repair". Otherwise mark as "vendor".

### Fallback

If PLAYER_MONEY fires with no active context, source = "unknown".

## Historical Data Migration

On first load when `transactions` table is nil:
1. Iterate through existing `history` entries
2. Compute gold difference between consecutive entries
3. Create transaction record with `source = "historical"`
4. Preserve original timestamps

## Visual Consistency

- Background: `0, 0, 0, 0.75`
- Border: `#D4A017` (gold)
- Fonts: GameFontNormal, GameFontNormalSmall
- Colors: Green for gains, Red for losses
- Gold/Silver/Copper coloring in balance column

## Filter Behavior

- Filters apply to transaction list only
- Time range dropdown filters both chart and transactions
- Source toggles filter by transaction source
- Filter state preserved when switching tabs
- Page resets to 1 when filters change
