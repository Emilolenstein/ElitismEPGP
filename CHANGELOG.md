# Changelog

All notable changes to **Elitism EPGP** are documented here. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

Unreleased changes live under the `[Unreleased]` heading; when you cut a release, rename it to the version + date and start a new `[Unreleased]` block above.

## [Unreleased]

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

[Unreleased]: https://github.com/Emilolenstein/ElitismEPGP/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Emilolenstein/ElitismEPGP/releases/tag/v0.1.0
