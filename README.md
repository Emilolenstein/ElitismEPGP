# Elitism EPGP

A polished EP/GP loot-council system built for **Ascension WoW** (3.3.5a). Officers calibrate point values once; bidders click a button when loot drops; the addon handles the math, the standings, the chat broadcasts, and the audit trail.

## Highlights

- **EP/GP with PR ranking** — Effort Points and Gear Points tracked per character, with priority `PR = EP / GP`. Alts route to mains so a player's standing follows them across characters.
- **Per-raid × per-difficulty EP matrix** — every raid (MC, BWL, AQ40, Naxx, ICC, …) × every difficulty (Normal/Heroic/Mythic/Ascended) has its own award values. Defaults bundled; officers tune them in the Options panel.
- **AtlasLoot integration** — modifier-click any item in AtlasLoot to open a bid session. Auto-detects equipped vs. upgrade and labels bids Main-Spec / Off-Spec accordingly.
- **GP formula** — base GP × 2^((ilvl − standard) / doubling) — calibrated by officers, applied uniformly. Per-slot multipliers handle trinkets, weapons, off-hands, etc.
- **Bid timer + auto-resolve** — 60-second bid window (configurable), 4-3-2-1 raid-chat countdown in the final seconds, top-3 bidders announced on close.
- **Guild-wide state replication** — every addon-using guildie holds a copy of the standings via AceComm sync. Officers can write; everyone reads. Crash-resistant: a freshly-installed officer can bootstrap from any online guildie.
- **Backup & restore** — copy-pasteable encoded blob for off-site backups, plus an auto-snapshot ring buffer that triggers before destructive operations (resets, weekly maintenance). A bad decision is one click away from being undone.
- **Weekly maintenance** — one-click EP/GP decay with configurable percentage. Officer-rank players get a weekly EP stipend automatically.
- **Officer-only surfaces** — sensitive controls (raid manager, EP awards, prices, backups) are gated on the guild's "Edit Officer Note" rank. Members see standings and their own detail page; officers see the full toolkit.
- **Minimap button + slash commands** — `/ee` for everything, `/ee help` for the full command list.

## Installation

1. Download the latest release zip from the [Releases page](https://github.com/Emilolenstein/ElitismEPGP/releases).
2. Extract the `ElitismEPGP/` folder into:
   ```
   <Ascension>\Interface\AddOns\
   ```
3. Restart the client (or `/reload` if already in-game).
4. Type `/ee` to open the main window.

Officers need their guild rank to have **"Edit Officer Note"** checked in the guild controls. Without it, the addon falls back to read-only mode for that character.

## Quickstart

### For officers / raid leaders

1. **Open the main window** — `/ee` or click the minimap icon.
2. **Set base values** — Interface > AddOns > Elitism EPGP > Gear Points. Base GP, standard ilvl, doubling ilvl. Defaults work; tune if you want a steeper or flatter curve.
3. **Start a raid** — minimap right-click > Manage Raid > pick raid + difficulty > Start Raid.
4. **Award boss kills** — auto if "Auto" mode is on, or click "Boss Kill" in the Raid Manager.
5. **Award loot** — modifier-click an item in AtlasLoot (Alt + LeftClick by default) to open a bid session.
6. **End the raid** — Manage Raid > End Raid. EP awards finalize and broadcast.
7. **Weekly maintenance** — minimap right-click > Weekly Maintenance. Decays everyone's EP+GP and awards the weekly officer stipend.

### For raiders

1. Install the addon — that's it.
2. When loot drops and the bid window pops, click **Main-Spec** or **Off-Spec**.
3. Check your standing on the minimap tooltip or via `/ee`.

## Configuration

All settings live under **Interface > AddOns > Elitism EPGP**. Highlights:

- **Display** — opacity, class colors, self-row highlight.
- **Effort Points** — per-raid award amounts + difficulty multipliers.
- **Gear Points** — formula calibration + per-slot multipliers.
- **Officer & RL** — bidding modifier, bid timeout, weekly decay %, boss-kill detection mode.
- **Backups** — open the Backup & Restore window, plus the filesystem path to copy off-site.

## Slash commands

Run `/ee help` in-game for the full reference. Some highlights:

| Command | What it does |
| --- | --- |
| `/ee` | Toggle the main window |
| `/ee raid` | Open the Raid Manager |
| `/ee help` | Print the command reference |
| `/ee reset epgp <player>` | Zero a single player's EP/GP |
| `/ee reset all` | **Wipe everything** (gated by confirmation checkbox) |

## Compatibility

- **Client**: WoW 3.3.5a (Ascension). Not tested against retail or other 3.3.5 servers.
- **Optional deps**: [AtlasLoot](https://www.curseforge.com/wow/addons/atlasloot) for bid-on-click, [DBM-Core](https://www.curseforge.com/wow/addons/deadly-boss-mods) for auto boss-kill detection.
- **Required libs**: bundled via Ace3 embeds (`Libs/` folder in the addon).

## Versioning

Semantic versioning (`MAJOR.MINOR.PATCH`). The addon broadcasts its version on guild channel once per session — out-of-date guildies see a one-time prompt to update.

## License

[MIT](LICENSE) — do whatever you want, attribution appreciated.

## Credits

- **Author**: Emilol
- **Built for**: Elitism (Ascension)
- **Repo**: https://github.com/Emilolenstein/ElitismEPGP
