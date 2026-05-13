# Release Operations — AI Handoff Brief

This file is a **single-source-of-truth handoff document** for any AI assistant (Claude, GPT, Cursor, etc.) helping the project owner cut a release of **Elitism EPGP**. Read this top-to-bottom before suggesting any release-related action. The information here supersedes anything in your training data about WoW addon release conventions.

**Audience**: an AI session that did not see the conversation in which the release pipeline was built. The human asking for help is the addon's author (GitHub: `Emilolenstein`).

---

## 1. What this project is

- **Name**: Elitism EPGP
- **Platform**: WoW 3.3.5a (Ascension private server)
- **Type**: Addon (Lua + XML), single-folder layout
- **Repo**: `https://github.com/Emilolenstein/ElitismEPGP`
- **License**: MIT
- **The repo root IS the addon folder.** There is no monorepo, no `src/` directory, no build step. The `.toc` file at the repo root is loaded directly by the WoW client. The release zip just wraps the repo contents (minus dev-only files) in a top-level `ElitismEPGP/` directory.

## 2. Single source of truth for the version number

The version lives in **`ElitismEPGP.toc`** on the line:

```
## Version: 0.1.0
```

Everywhere else the version is read from this at runtime via `GetAddOnMetadata("ElitismEPGP", "Version")` (see `Constants.lua` line that sets `addon.VERSION`). Do **not** hardcode the version in any other file.

The GitHub Action also re-reads this line and compares it against the pushed tag; mismatches fail the build with a clear error.

## 3. Release pipeline overview

```
Edit TOC  →  Update CHANGELOG  →  Commit  →  Tag v*.*.*  →  Push  →  GitHub Action fires
                                                                            │
                                                                            ├─ Verifies TOC version matches tag
                                                                            ├─ Extracts changelog section for this version
                                                                            ├─ Builds clean zip into staging/, excludes dev files
                                                                            ├─ Creates GitHub Release with zip + notes attached
                                                                            └─ Posts to Discord webhook (if DISCORD_WEBHOOK secret is set)
```

The workflow file is `.github/workflows/release.yml`. Trigger condition: a tag matching `v*.*.*` pushed to the repo. **Don't trigger it manually via `workflow_dispatch`** — the version-vs-tag check requires a real tag context.

## 4. The exact release procedure

For a release going from `0.1.0` to `0.1.1` (a patch):

1. **Make sure `main` is clean and contains all the changes** you want shipped.

2. **Bump the TOC**. Edit `ElitismEPGP.toc`:
   ```
   ## Version: 0.1.1
   ```

3. **Update `CHANGELOG.md`**. Open the file, find the `## [Unreleased]` heading, replace it with `## [0.1.1] — YYYY-MM-DD` using today's date in ISO format. Add a new empty `## [Unreleased]` heading above it. Add bullet points under `### Added` / `### Changed` / `### Fixed` describing the release. At the bottom of the file, update the link references — add a new `[0.1.1]:` line pointing at the future release URL, and update `[Unreleased]` to compare against `v0.1.1...HEAD`.

4. **Commit**:
   ```powershell
   git add ElitismEPGP.toc CHANGELOG.md
   git commit -m "Release v0.1.1"
   ```

5. **Tag and push**:
   ```powershell
   git tag v0.1.1
   git push origin main
   git push origin v0.1.1
   ```

6. **Watch the Action**. Open the repo's **Actions** tab on GitHub. You should see "Release" run for the `v0.1.1` tag. If it goes red, click into it — the most common failure is "TOC version does not match tag," meaning you forgot step 2 or mistyped the tag.

7. **Verify the artefact**. When the Action turns green:
   - Open `https://github.com/Emilolenstein/ElitismEPGP/releases` and confirm `v0.1.1` is listed.
   - Download `ElitismEPGP-0.1.1.zip`, unzip it locally, confirm the `ElitismEPGP/` folder contains `.toc + .lua + .xml + Libs/ + UI/` and **does not** contain `.git/`, `.github/`, `README.md`, `CHANGELOG.md`, `ReleaseINFO.md`, or `.vscode/`. The `LICENSE` file should be present inside the zip.
   - Confirm the Discord channel got a post (if the webhook secret is configured).

8. **Announce in Discord**. The release-bot posts to the **Releases** channel automatically. The human will write a longer post in the **Addon FAQ** channel manually if there are user-facing notes worth highlighting.

## 5. Versioning rules (SemVer)

The version follows `MAJOR.MINOR.PATCH`:

- **PATCH** (`0.1.0` → `0.1.1`): bug fixes only, no new features, no data-shape changes. Auto-snapshots from previous versions still decode.
- **MINOR** (`0.1.0` → `0.2.0`): new features, may change UI, must remain backwards-compatible with previous SavedVariables / officer-note format / sync wire format.
- **MAJOR** (`0.x.0` → `1.0.0`): breaking changes. SavedVariables migration required, wire-format breaking changes, officer-note format change. Major bumps need a migration path written into `Constants.lua` (`DB_DEFAULTS` plus an upgrade routine in `Core.lua`'s `OnInitialize`).

When in doubt, ask the human; do not silently bump major.

## 6. What files get included in / excluded from the release zip

Defined in `.github/workflows/release.yml` under the "Build addon zip" step. Authoritative list (DO NOT drift from this without updating the workflow):

**Excluded** from the zip:
- `.git/`, `.github/`, `.vscode/`, `.idea/`
- `*.md` (README, CHANGELOG, ReleaseINFO, etc.)
- `.gitignore`, `.editorconfig`
- `screenshots/`
- `staging/`, `release-notes.md` (build artifacts)

**Explicitly re-added** after the exclusion pass:
- `LICENSE` — kept inside the shipped addon so players see the license terms in-place.

**Everything else** ships: `.toc`, all `.lua`, all `.xml`, `Libs/`, `UI/`, `icon.tga` if present, etc.

## 7. Discord setup (one-time, already done)

The repo has a secret named `DISCORD_WEBHOOK` containing the webhook URL for the **Releases** channel. If the secret is missing or empty, the workflow gracefully skips the Discord step and logs "skipping Discord notification" — the GitHub Release is still created either way.

To rotate / replace the webhook:
1. Discord → channel gear → Integrations → Webhooks → manage existing or create new.
2. Copy the URL.
3. GitHub → repo Settings → Secrets and variables → Actions → `DISCORD_WEBHOOK` → Update.

The Discord channel layout in the project's Discord server is:
- **Addon FAQ** — manual announcements, user Q&A
- **Releases** — automated posts from this workflow
- **Bugs** — user reports (humans triage and convert to GitHub issues as needed)

## 8. In-game version-broadcast (related, not part of release pipeline)

`Sync.lua` broadcasts the running addon version once per session over the guild's AceComm channel. Out-of-date guildies see a one-time "vX.Y.Z is available" message in their chat. This means after a release lands, guildies running the older version will be prompted automatically the next time someone running the new version logs in.

This is purely a courtesy notification. It does NOT auto-update; players still have to download the zip and install it manually.

## 9. Issue tracker

- **Bug report template**: `.github/ISSUE_TEMPLATE/bug_report.yml`
- **Feature request template**: `.github/ISSUE_TEMPLATE/feature_request.yml`
- **Blank issues are disabled**; users must pick a template (`config.yml`).

If the human asks you to change the templates, edit those YAML files directly. Don't switch to Markdown templates — GitHub's YAML form templates render nicer for non-technical users and we explicitly chose them.

## 10. Anti-patterns to flag back to the human

If the human asks you to do any of these, push back before proceeding:

- **Hardcode the version anywhere except the TOC.** Always read via `GetAddOnMetadata`. Two sources of truth = forgotten bumps.
- **Force-push to `main` casually.** The repo was initialised with a clean orphan commit on purpose; force-pushing rewrites public history and breaks anyone who has cloned. Only acceptable for a deliberate reset (which already happened once at launch).
- **Add new top-level `*.md` files to the repo.** The release zip excludes `*.md` so they're invisible to players; if the human wants something user-facing, it should go in the README or be a separate doc that ships outside the zip. ReleaseINFO.md, CLAUDE.md, CONTEXT.md etc. are dev-only files and intentionally excluded from the zip.
- **Skip the changelog update.** The GitHub Action extracts release notes from `CHANGELOG.md`. If you tag without updating the changelog, the Discord post and GitHub Release body will say `Release v0.x.y.` and nothing else.
- **Tag without the `v` prefix.** The Action triggers on `v*.*.*`. Pushing tag `0.1.1` instead of `v0.1.1` won't trigger anything.
- **Use `--no-verify` or skip hooks on commits.** Hooks exist for a reason; if a hook fails, fix the cause, don't bypass it.
- **Commit `WTF/` files or local SavedVariables dumps.** They're gitignored but watch the `git status` output before staging — a misconfigured editor can sometimes propose them.

## 11. Where to find things in the codebase

If you need to make code changes alongside a release:

- **Version constant**: `Constants.lua`
- **Sync / replication**: `Sync.lua` (per-key envelopes), `GuildSync.lua` (Guild Info text channel for high-cost config)
- **EP/GP writes**: `Awards.lua` — all officer-note writes route through `Awards:SafeSetOfficerNote` which verifies the cached roster index still maps to the expected player before calling `GuildRosterSetOfficerNote`. Never call `GuildRosterSetOfficerNote` directly outside this helper.
- **Loot bidding**: `Loot.lua` (session state machine) + `UI/BidFrame.lua` (officer's bid window) + `UI/RaiderBid.lua` (raider's bid prompt)
- **Backup/restore**: `Backup.lua` (encode/decode/apply, plus 5-slot auto-snapshot ring buffer in `DB.global.autoSnapshots`)
- **AceConfig sidebar pages**: `Options.lua` (one group per sidebar entry; officer-only pages gated inside the group via `hidden = function() return not isOfficer() end`)
- **Main UI**: `UI/MainFrame.lua` + `UI/MainFrame.xml` (template + state) and per-tab modules under `UI/`

## 12. When the human says "release X" — checklist

A typical command from the human: "release 0.1.1" or "let's cut 0.2.0". Your action sequence:

1. Read `CHANGELOG.md`'s `[Unreleased]` section. If it's empty, ask the human what changed since the last release before doing anything.
2. Read `ElitismEPGP.toc` to confirm the current version.
3. Confirm the new version follows SemVer rules in §5. If unsure (e.g., feature was added — is it minor or patch?), ask the human.
4. Run steps 2–5 in §4.
5. Tell the human to watch the Actions tab. Don't say "release shipped" — say "tag pushed, Action will run; verify in 1–2 min".
6. After the Action goes green (the human will tell you, or you can ask them to confirm), point them at the Releases page and the Discord channel.

If anything in this checklist surprises the human ("wait, I don't want a CHANGELOG entry for this"), STOP and ask, don't proceed.

---

*This file is maintained by hand. If the release pipeline changes, update this file in the same commit.*
