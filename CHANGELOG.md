# Changelog

All notable changes to **Elitism EPGP** are documented here. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

Unreleased changes live under the `[Unreleased]` heading; when you cut a release, rename it to the version + date and start a new `[Unreleased]` block above.

## [Unreleased]

## [0.1.1] — 2026-05-14

### Added
- `/ee diag` slash command — prints config, permissions, raid state, click-hook status and active session in one chat dump for triage. Players hitting bid issues can paste this without needing custom scripts.
- Awards Points mode now spans the whole automation surface (start/end raid + boss kills) with three settings:
  - **Manual** — no auto EP, RL clicks Award buttons in the Raid Manager.
  - **Suggest** *(default)* — confirmation modal on Start/End raid + boss-kill banner.
  - **Auto** — everything fires immediately, no prompts.
- Click-blocked clicks (no raid active, bid already in progress) now flash a red message at the top of the screen via `UIErrorsFrame` in addition to the chat print. Officers can no longer miss "Start the raid first" mid-pull.
- Bid panel auto-recovers from an off-screen saved position: `BidFrame:Reopen` checks bounds, clears stale `bidFramePos`, and re-anchors to the StaticPopup1 spot if it lands outside UIParent.
- Weekly maintenance now broadcasts to guild chat (`"Weekly maintenance — N% decay applied to M players."`) so members understand why their EP/GP just moved.

### Changed
- **Bid window lifecycle**: the corner X now **hides** the bid panel (session keeps running in the background, RL can bring it back via the View/Hide Bids toggle in the Raid Manager or by clicking any item). Only the **Cancel** button ends the session. Timer expiry no longer affects the session — the bid stays open until the RL explicitly Awards or Cancels.
- Boss-kill Detection section in Officer & RL renamed to **Awards Points** to reflect that it now governs all automation, not just boss kills. The old "Confirmation message when starting and ending a raid" toggle is retired — the new Awards Points mode subsumes it.
- `RaidSession:Start` now takes an `awardEP` argument (default `true`) so manual mode can flip the session active without auto-paying On-Time EP.

### Migrated
- Profiles on 0.1.0 with `bossKillMode = "auto"` keep auto behaviour. All other values (including the default "manual") migrate to `awardsMode = "suggest"` to preserve auto-EP-with-confirmation rather than silently dropping the grant. Users wanting zero automation can switch to "Manual" in Officer & RL.

### Fixed
- Sanity-review punch list from pre-launch (officer-note write guards, Sync MSG_FULL auth, Backup transactional safety, version-parser tolerance) — all blockers from v0.1.0 closed.

## [0.1.0] — 2026-05-13

Initial public release.

### Added
- EP/GP standings with PR (`EP / GP`) ranking, alt → main resolution, class-colored names.
- Per-raid × per-difficulty EP award matrix (MC, BWL, AQ40, Naxx, ICC, …) with difficulty multipliers (Normal / Heroic / Mythic / Ascended).
- GP formula: base × `2^((ilvl − standard) / doubling)`, plus per-slot multipliers.
- AtlasLoot integration — modifier-click any item to open a bid session.
- Bid window with 60 s timer, 4-3-2-1 raid-chat countdown, top-3 announcement on close, "X won" broadcast on award.
- Raid Manager — pick raid + difficulty, Start/End raid, boss-kill auto-award, custom awards, per-player tweaks.
- Guild-wide state replication via AceComm (`Sync.lua`, `GuildSync.lua`) — passive replication, officer-only authority, per-key timestamps.
- Version broadcast — one ~12-byte GUILD ping per session; out-of-date guildies see a one-time "newer version available" notice.
- Backup & Restore — copy-pasteable serialized snapshot, plus a 5-slot auto-snapshot ring buffer (records before any destructive op).
- Weekly maintenance — EP/GP decay with configurable percentage + officer/GM weekly EP stipend.
- Confirmation modal with a "checkbox-gated" Apply button for irreversible actions (`/ee reset all`).
- Minimap button + LDB launcher with version footnote in the tooltip.
- Slash commands: `/ee`, `/ee raid`, `/ee help`, `/ee reset epgp <player>`, `/ee reset all`.
- Officer/RL settings page gated on the guild's "Edit Officer Note" rank.
- MIT license, README, CHANGELOG, GitHub issue templates.

[Unreleased]: https://github.com/Emilolenstein/ElitismEPGP/compare/v0.1.1...HEAD
[0.1.1]: https://github.com/Emilolenstein/ElitismEPGP/releases/tag/v0.1.1
[0.1.0]: https://github.com/Emilolenstein/ElitismEPGP/releases/tag/v0.1.0
