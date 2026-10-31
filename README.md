# LootWiz

**LootWiz** is a lightweight, reliable Master Looter automation addon for World of Warcraft (1.12.1 / Turtle WoW). It streamlines party and raid looting by automatically routing items below the rarity threshold to your bags, preserving manual control when needed.

It uses a paced, reverse-indexed loot queue that processes items cleanly and safely, instead of flooding the server with synchronous loot packets in a single frame. This eliminates the risk of loot packet drops and slot shifting while handling large raid bosses or multi-page loot windows, or leaving empty loot windows that would block other interactions.

---

## Features

- **Zero-Setup Operation:** Enabled automatically whenever loot rules are set to **Master Looter** and you are the Master Looter.
- **Auto-Master Loot on Party Formation:** Automatically switches the loot method to **Master Looter** when you form a party as the leader.
- **Rarity Threshold Automation:** Automatically loots items **below** your chosen rarity threshold directly to your bags, while leaving items **at or above** your threshold in the loot window for manual handling.
- **BoP Exclusion Toggle:** Leave **Bind on Pickup (BoP)** items in the loot window when enabled, even if they fall below your threshold. The **Always Auto-Loot** list still overrides this behavior for any item you explicitly add.
- **Native Player Frame Integration:** Configure your auto-loot threshold directly via the standard right-click menu on your Player Frame (**Loot Threshold -> Uncommon / Rare / Epic**) or through the in-game config panel.
- **In-Game Configuration GUI (`/lw`):**
  * Select your auto-loot rarity threshold (**Common**, **Uncommon**, **Rare**, **Epic**, or **Legendary**).
  * Toggle **Leave Bind on Pickup (BoP) items in loot window**.
  * Manage a custom **Always Auto-Loot** list (auto-loots specific items to you regardless of rarity).
  * Manage a custom **Ignore (Never Auto-Loot)** list (leaves specific items in the loot window regardless of rarity).
  * Supports typing Item Names/IDs or **Shift-clicking** items to add them to the active list.
- **Post-loot interaction & Multi-Page Raid Boss Safe:**
  * Processes loot slots from bottom to top at paced 60ms intervals using `C_Timer.NewTicker`, preventing slot-index shifting and packet drops on raid bosses with multiple pages of loot.
  * Automatically releases empty loot frames once the final item clears to prevent issues with creature interactions after looting.

---

## Requirements

- **[ClassicAPI](https://github.com/brues-code/ClassicAPI)**

---

## Installation

Recommend using **[TocPilot](https://github.com/Seraphic8x2244/TocPilot)**, a dedicated release manager for 1.12.1, to install and update addons and dependencies.

### Recommended: Install via TocPilot
1. Download and install **[TocPilot](https://github.com/Seraphic8x2244/TocPilot)**.
2. Open TocPilot and click `Add Repository`.
3. Paste the clone URL and click Scan.
   ```text
   [https://github.com/valnaut/LootWiz.git](https://github.com/valnaut/LootWiz.git)
   ```
4. Let TocPilot handle the download and installation.

### Alternative: Manual Installation
1. Download this repository as a ZIP file and extract the `LootWiz` folder into your `Interface\AddOns\` directory.
2. Verify the folder structure matches:
   ```text
   Interface\AddOns\LootWiz\LootWiz.toc
   Interface\AddOns\LootWiz\LootWiz.lua
   ```

---

## Usage & Slash Commands

Open the configuration window at any time with:

```text
/lootwiz
/lw
```

You can also change your threshold directly via slash commands:

- `/lw common` — Auto-loots Poor (Gray) items; leaves Common (White) and above for Master Loot.
- `/lw uncommon` — Auto-loots Poor and Common items; leaves Uncommon (Green) and above for Master Loot *(Default)*.
- `/lw rare` — Auto-loots Poor, Common, and Uncommon items; leaves Rare (Blue) and above for Master Loot.
- `/lw epic` — Auto-loots Poor, Common, Uncommon, and Rare items; leaves Epic (Purple) and above for Master Loot.
- `/lw bop` — Toggles looting of **Bind on Pickup (BoP)** items when they are below your threshold.

### Adding Items to "Always Auto-Loot" or "Ignore"
1. Type `/lw` to open the configuration GUI.
2. Click inside either the **Always Auto-Loot** or **Ignore** input box to focus it.
3. `Shift + Left-Click` an item from your inventory, loot window, chat window, or character sheet to immediately add it to the list (the cursor stays focused in the box so you can Shift-click multiple items in succession), **or** type an item name/ID and press **Enter** / click **Add**.
4. Use your mouse wheel to scroll through saved entries, or click **X** next to any item to remove it.