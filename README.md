# GoldTracker

A World of Warcraft 1.12.1 addon that tracks your gold over time and displays it as a clean, modern line chart.

![GoldTracker Screenshot](screenshots/goldtracker.png)

## Features

- **Real-time gold tracking** - Automatically records gold changes from looting, vendoring, trading, mail, and quests
- **Line chart visualization** - Clean, modern chart showing your gold trends over time
- **Multiple time ranges** - View data for This Session, Last 7 Days, Last 30 Days, or All Time
- **Live statistics** - See current gold, session gains, net change, and gold per hour (updates live)
- **Persistent data** - Your gold history is saved across sessions forever
- **Per-character tracking** - Each character has their own separate history

## Installation

1. Download or clone this repository
2. Copy the `goldtracker` folder to your `World of Warcraft/Interface/AddOns/` directory
3. Restart WoW or type `/reload` if already in-game
4. The addon will appear in your addon list as "GoldTracker"

## Usage

### Commands

- `/gt` or `/goldtracker` - Toggle the GoldTracker window

### Interface

- **Chart Area** - Displays your gold history as a line chart
- **Time Range Dropdown** - Select the time period to view (top right)
- **Y-Axis** - Gold amounts (adjusts automatically to your data)
- **X-Axis** - Time stamps (shows time if same day, date+time if multiple days)

### Statistics (bottom of window)

| Stat | Description |
|------|-------------|
| **Gold** | Your current total gold |
| **Session** | Gold gained/lost since logging in |
| **Net** | Total change over the selected time range |
| **Rate** | Current gold per hour (updates every 2 seconds) |

## Compatibility

- World of Warcraft 1.12.1 (Vanilla)
- TurtleWoW and other 1.12.1 private servers

## License

This addon is free to use and modify.
