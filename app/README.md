# Fleet.app (v0.1 prototype)

A native macOS cockpit for running several coding agents (Claude Code, Codex,
anything else) at once — organized into **Screens**, each an independent
workspace with its own tiled terminal grid and, optionally, its own git
worktree, so agents in different screens never touch the same files.

Built with SwiftUI + [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)
(real PTYs, not a toy terminal) via Swift Package Manager — no Xcode project
needed. This is the "v1.5" native counterpart to the `fleet` CLI in `../bin`;
they share `~/.config/fleet/`.

## What it does today

- **Sidebar** (Codex/Claude-app style) — Screens are grouped by **Project**
  (the repo they're worktree'd from), each expandable, plus a **Recents**
  list of your most recently active screens across every project. Hover a
  project header for two one-click buttons — spin up a new `claude` or
  `codex` screen in that project instantly, no dialog. The "+" at the top
  opens the full New Screen sheet when you want a specific branch/pane count.
- **Screens** — each an independent workspace with its own tiled grid of
  terminal panes. All screens keep running in the background when you switch
  between them in the sidebar — nothing pauses or restarts.
- **Git worktrees** — "+" → optionally point a screen at a repo + branch.
  Fleet runs `git worktree add` into `<repo>-worktrees/<branch>` next to the
  repo and starts every pane there. Two screens on two branches never share a
  working tree.
- **Sync / Push** — per git-backed screen: fetch + rebase onto the base
  branch, or push the branch upstream. This is plain `git`, run for you —
  not a merge tool. Conflicts stop at the rebase and you resolve them in the
  pane like normal.
- **Cost + context HUD** — every pane border shows model / cost / context %,
  read from the same `~/.config/fleet/sessions/*.json` the CLI's `fleet hud`
  writes. Turn the HUD on with `fleet hud install` first.
- **Native power control** — `IOPMAssertionCreateWithName`, not `caffeinate`.
  Three modes: Display on / System awake / Off. This is the actual fix for
  "the screen blanks randomly" — see `../PowerManager.swift`.
- **Display pinning** — pick which physical display the window lives on; if
  that display disappears (a dead built-in panel, an unplugged monitor) the
  window falls back to the main display instead of following it into nothing.

## What "sync" is *not*

It is not automatic conflict resolution and it does not coordinate what
different agents work on — that's still your call. It's the git plumbing
so an isolated screen can catch up with `main` or publish its branch without
you leaving the app.

## Build & run

```bash
swift build              # first build fetches SwiftTerm via SPM
./build-app.sh            # assembles Fleet.app, ad-hoc signed for local use
open Fleet.app
```

Config: `~/.config/fleet/app.json` — `screens[]`, each with `panes[]`
(name/command/cwd), plus git fields when the screen is worktree-backed.
Edited by the app; hand-editing is safe (missing fields fall back to sane
defaults; a legacy single-screen `{panes:[...]}` file is migrated on load).

## Known rough edges (v0.1)

- No visual QA pass yet — built and driven headlessly (process/PTY/config
  checks) in an environment without screen-recording permission. If a layout
  looks off, it's unverified, not deliberate.
- Ad-hoc signed only; not notarized. Fine for local use, not for distributing
  outside this Mac yet.
- One tab bar per app window; no separate OS windows per screen yet.
- Sync/push need a working `origin` remote — untested against one in this
  environment (the fleet repo itself has none).
