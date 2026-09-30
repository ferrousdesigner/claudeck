<div align="center">

# ✦ Claudeck

**A native macOS dashboard for [Claude Code](https://docs.claude.com/en/docs/claude-code).**

See what Claude is doing right now, browse and search every past session, track cost, find out how to spend fewer tokens, and manage MCP servers, hooks and permissions without editing JSON.

[![Latest release](https://img.shields.io/github/v/release/ferrousdesigner/claudeck?label=release&color=D97757)](https://github.com/ferrousdesigner/claudeck/releases/latest)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)
![Swift](https://img.shields.io/badge/Swift-5.10%2B-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0A84FF)
![No server](https://img.shields.io/badge/server-none-2ea44f)
![License: MIT](https://img.shields.io/badge/license-MIT-blue)

</div>

---

Claude Code already records every session in `~/.claude`. Claudeck reads those files, so there is nothing to set up. Open it and your history is already there. New sessions show up within a few seconds, whether you run Claude in the terminal or in your editor.

It has no account, no server and no telemetry. Everything stays on your Mac.

## Features

### Watch what's happening
- **Status**: every running Claude Code session with a live working/idle indicator and a context meter showing how full the context window is. It also shows today's spend and any approvals waiting for you.
- **Menu bar**: a ✦ icon that shows live sessions, today's cost against your budget, and pending permission requests, even when the window is closed.
- **Approvals from anywhere** (optional): answer Claude's *"can I run this command?"* prompts from a notification with **Allow** / **Deny**. If you don't answer, the terminal asks you as usual.

### Review past work
- **Sessions**: every session, newest first, with tokens, cost, the tools used and the full conversation. It also includes:
  - An **AI summary** of each session, cached after the first time you open it.
  - **Files changed**: diffs against the file before the session, with a *Restore original* button.
  - **Continue here** or **Resume in Terminal** (`claude --resume`).
  - Export to Markdown, Word or PDF.
  - Each session saved automatically as a readable Markdown **memory doc** in `~/Documents/Claudeck/Sessions`.
- **Search** (⇧⌘F): full-text search across everything you and Claude wrote, and every command Claude ran, in all projects.
- **Projects**: every folder you've used Claude Code in, with its branch, uncommitted changes, unpushed commits, and open threads taken from session summaries.

### Understand and cut your spend
- **Cost & Tokens**: tokens and estimated cost by day, session, model and project, with the input, output, cache write and cache read split.
- **Improvements**: ranked, concrete ways to spend fewer tokens, worked out from your last 30 days of sessions. Each suggestion comes with an estimated monthly saving, the sessions or files that triggered it, and a button that takes you where you can fix it. It looks for:

  | Check | What it catches |
  |---|---|
  | Premium model on light work | Opus used for sessions Sonnet could have handled |
  | Long sessions | Conversations dragging a huge context into every reply |
  | Cache misses | The prompt cache expiring and the whole context being written to cache again |
  | Startup context | Large CLAUDE.md files, memory files and MCP servers loaded before you've typed anything |
  | Noisy tool output | Tool calls that dump tens of thousands of characters into context |
  | Tool errors | High failure rates that waste round trips |
  | Output-heavy usage | Output tokens making up an unusually large share of cost |

- **Insights**: your busiest hours, the tools used most, failure rates, and an AI-written digest of the last day or week, with a standup blurb you can paste.
- **Budgets**: daily, weekly and monthly limits, with a notification at 80% and at 100%.

### Run and configure Claude Code
- **Ask Claude (⌘K)**: send a prompt to your local `claude` CLI in any project folder. You pick the model and the permission mode. You can use templates with `{{blanks}}`, and run **2–4 parallel attempts in separate git worktrees** to compare their diffs side by side.
- **Prompts & Schedules**: save prompts you reuse and run them on a schedule: daily, on chosen weekdays, or every N minutes.
- **Extensions**, all without editing JSON:
  - **Skills, subagents and slash commands**: see what's installed, or create new ones.
  - **Plugins**: browse marketplaces, install, enable and disable.
  - **MCP servers**: add them with a form, pick from a gallery, or import from Claude Desktop, at user or project scope.
  - **Hooks**: start from ready-made recipes, such as a sound when Claude finishes or blocking edits to `.env`.
  - **Permissions**: allow and deny rules, with risky rules flagged.
  - **CLAUDE.md and memory**: edit them, with broken file references highlighted.
- **Security**: scans your transcripts for API keys, tokens, private keys, passwords and database URLs that ended up in Claude's context. Values are shown masked. It also flags every time Claude read a `.env` or credentials file.

## Install

### Download

**[⬇ Download Claudeck.dmg](https://github.com/ferrousdesigner/claudeck/raw/main/download/Claudeck.dmg)**: the latest version, a universal build for Apple silicon and Intel Macs, about 5 MB. Older versions and release notes are on the [Releases](https://github.com/ferrousdesigner/claudeck/releases) page, and every change is listed in the [CHANGELOG](CHANGELOG.md).

1. Open the `.dmg` and drag **Claudeck** into **Applications**.
2. The app is ad-hoc signed, not notarized, so the first time you open it macOS may say it can't verify the developer. Right-click the app, choose **Open**, then **Open** again. On macOS 15 and later, you may instead need to go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Requirements
- macOS 14 Sonoma or later
- [Claude Code](https://docs.claude.com/en/docs/claude-code) installed and signed in. Browsing history works without it; Ask Claude, summaries and digests need it.
- To build from source: Xcode 15.3+ or the Swift 5.10+ command-line tools.

### Build from source

```bash
git clone https://github.com/ferrousdesigner/claudeck.git
cd claudeck
scripts/build_app.sh --install
```

This builds a universal release binary, packages `Claudeck.app` and a `.dmg` in `dist/`, and copies the app into `/Applications`. Leave off `--install` to only build.

### Run in development

```bash
swift build
.build/debug/Claudeck                 # launch the app
.build/debug/Claudeck --selftest      # run the self-tests against your real ~/.claude data
.build/debug/Claudeck --tab Improvements   # open straight to a tab
```

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌘K | Ask Claude |
| ⌘1 … ⌘9 | Switch tabs |
| ⇧⌘F | Search every session |
| ⌘R | Refresh |
| ⌘, | Settings |
| ⌘? | Built-in guide |

## Privacy

Claudeck has no backend. Here is everything it touches:

- **Reads** `~/.claude`: sessions, settings, skills, plugins and file history.
- **Writes**:
  - Memory docs and digests to `~/Documents/Claudeck`.
  - App data to `~/Library/Application Support/Claudeck`.
  - `~/.claude` settings, only when you change something in the app. Before its first change to a settings file it saves a backup next to it (`*.claudeck.bak`).
- **Network**: none of its own. The only network traffic comes from Claude Code runs you start. AI summaries and digests count as those runs, and they aren't saved as sessions.

Costs are estimated at API list prices. On a Pro or Max plan you aren't billed per token, so read them as a measure of how hard you're using your plan.

## Project layout

```
VERSION                  # current version, e.g. 1.0.0
CHANGELOG.md             # one entry per release
download/                # prebuilt Claudeck.dmg (latest release)
Sources/Claudeck/
├── App.swift            # app entry, tabs, menus, launch arguments
├── Core/                # parsing, pricing, cost advisor, settings, MCP, runner, search
└── Views/               # one SwiftUI view per tab, plus the guide, menu bar and composer
scripts/
├── build_app.sh         # release build → .app + .dmg (+ --install)
├── release.sh           # bump version, build, commit, tag, push, GitHub Release
└── make_icon.swift      # renders the app icon
```

There are no third-party dependencies. It uses only SwiftUI, AppKit, Charts and Foundation.

## Contributing

Issues and pull requests are welcome. Before opening a PR, run `swift build` and `.build/debug/Claudeck --selftest`, and check that the self-test ends with `ALL PASSED`.

## Versioning and releases

Claudeck uses [semantic versioning](https://semver.org). The `VERSION` file is the single source of truth: it becomes the app's version in *About Claudeck*, and each release is tagged `vX.Y.Z`.

Every commit to `main` is made as a release:

```bash
scripts/release.sh patch "Fix the sessions sidebar being pushed off-screen"
scripts/release.sh minor "Add the Improvements tab"
scripts/release.sh major "Redesigned navigation"
scripts/release.sh 1.4.0 "Set an exact version"
```

The script runs these steps in order:

1. Bumps `VERSION`.
2. Runs the self-test, and stops without committing if it fails.
3. Rebuilds `download/Claudeck.dmg`.
4. Adds a `CHANGELOG.md` entry.
5. Commits as `vX.Y.Z: <notes>`, tags it, and pushes.
6. Publishes a [GitHub Release](https://github.com/ferrousdesigner/claudeck/releases) with the `.dmg` attached.

The build number is the commit count.

## License

[MIT](LICENSE)

---

<sub>Claudeck is an independent project and is not affiliated with or endorsed by Anthropic. "Claude" and "Claude Code" are trademarks of Anthropic.</sub>
