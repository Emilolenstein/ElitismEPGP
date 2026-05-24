# Changelog

All notable changes to **Elitism EPGP** are documented here. The format is loosely based on [Keep a Changelog](https://keepachangelog.com/), and this project adheres to [Semantic Versioning](https://semver.org/).

Unreleased changes live under the `[Unreleased]` heading; when you cut a release, rename it to the version + date and start a new `[Unreleased]` block above.

## [Unreleased]

## [0.1.3] — 2026-05-24

### Added
- **Per-player decay breakdown in History.** Selecting a weekly-maintenance entry in the History detail view now lists every affected player with their individual EP/GP change, instead of only the summary line. Decay entries logged before this version show a note that no per-player breakdown was stored.

### Fixed
- **Global AceGUI layout breakage in other addons** (WeakAuras, ElvUI, and any AceConfig-based UI). The bundled Ace3 was a newer revision than the rest of the 3.3.5a ecosystem (AceGUI-3.0 r34 vs the server-standard r33; AceConfigDialog 60 vs 50/54). Because WoW keeps only the single highest-versioned copy of each LibStub library for the whole UI, our copy was winning the version race and being force-shared to every AceGUI addon. WeakAuras ships no AceGUI core of its own, so it rendered entirely through ours; the r34 Flow layout's `safelayoutcall`/`layoutrecursionblock` width guard is incompatible with the 3.3.5a WeakAuras/ElvUI backports, so nested option containers collapsed to a single narrow column. Downgraded the embedded `AceGUI-3.0` and `AceConfig-3.0` to the server-standard r33 set so ElitismEPGP no longer outranks (and overrides) other addons' Ace3. Our own options panel is unaffected. *(Note: any sibling addon still shipping the newer Ace3 — LootReserve, Rolz, epgploot2 — will reintroduce the same conflict until updated the same way.)*
- **Officer-rank detection in weekly maintenance.** The guild-rank scan now reads the correct *Edit Officer Note* permission flag and treats the Guild Master rank as having full permissions. Previously the top rank was misread and some ranks could be classified incorrectly.
- **Raid/difficulty picker highlight overhang.** The hover and selected highlight on the Raid and Difficulty dropdown buttons extended ~5 px past the button's left edge; it now stops flush. The Main-spec / Off-spec / Pass bid buttons share the same skin and are unchanged.

## [0.1.2] — 2026-05-15

### Changed
- **GP formula UI rework**: the *Standard ilvl* + *Ilvl per doubling* sliders have been replaced by **Base ilvl** and **Price ramp** for an intuitive setup. Base ilvl is the reference item level (recommended 65 for Ascension). Price ramp is a 1-10 scale where higher = pricier high-ilvl items (instead of the previous "higher = flatter curve" inverse). Internal wire format is unchanged — `Prices:Compute` and Guild Info sync still use the same doubling field under the hood. **Manual rollout note**: existing officers won't see any change to their stored values until someone explicitly clicks Reset to Defaults under GP Formula. Coordinate the upgrade with your team before resetting so non-upgraded officers aren't surprised.
- **Option A tiebreaker** for tied-PR players: when two players share the same PR (typical when both sit below the Base GP floor and have `PR = ep/basegp`), the player with **less actual GP** sorts higher. Receiving an item nudges their GP up and immediately rotates them below tied peers — no more "winner stays at the top" surprise after an award. Applied in both the Standings list and the bid winner selection.
- **End-of-bid raid-chat message** reformatted from "top 3" to **winner + tier + PR**, or **tied set + /roll prompt** if multiple bidders share the same (PR, GP) tuple. Higher-PR tier (MS > OS > BANK) automatically picks the candidate pool; PASS bids never qualify as winners. Under Option A, same-PR-but-higher-GP players are correctly excluded from the tied set.

### Fixed
- **GP Formula "Reset to Defaults" button** no longer errored on click (`resetSlotMultipliers` was being referenced inside a closure before its `local function` declaration; forward-declared so the upvalue captures correctly).
- **Slider revert race in Guild Info sync**: after dragging or typing a value into any EP/GP slider, an incoming `GUILD_ROSTER_UPDATE` (which fires constantly on every guildie login/logout/ping) would trigger `GuildSync:Read` and clobber the in-flight edit with the stale Guild Info text. `GuildSync:Read` now no-ops during the 3.5s window between an edit and its committed write. Edits stick reliably.

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

[Unreleased]: https://github.com/Emilolenstein/ElitismEPGP/compare/v0.1.3...HEAD
[0.1.3]: https://github.com/Emilolenstein/ElitismEPGP/releases/tag/v0.1.3
[0.1.2]: https://github.com/Emilolenstein/ElitismEPGP/releases/tag/v0.1.2
[0.1.1]: https://github.com/Emilolenstein/ElitismEPGP/releases/tag/v0.1.1
[0.1.0]: https://github.com/Emilolenstein/ElitismEPGP/releases/tag/v0.1.0
