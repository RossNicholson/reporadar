# RepoRadar

Open-source (MIT) macOS menu bar app that lists the local git repos under watched folders that have
loose ends: uncommitted changes, unpushed commits (on any branch), no remote, mid-merge/rebase. Same
look as BrewDock, ClawdBar, Mop Up and KeyBar via the shared HouseStyle package. GitHub:
RossNicholson/reporadar (public). Cask: `reporadar` in RossNicholson/homebrew-tap. Page: rossnicholson.dev/reporadar.

Ross's decisions (2026-11-12): MIT, public, mascot is a radar dish with a face, 1.0 is status only
(no commit/push/pull buttons; Fetch all and the open actions are fine). Not in 1.0: commit, CI status
(steipete/RepoBar covers the GitHub side, stay local-first), iCloud sync, worktree lists.

## Layout
- `RepoRadar/Git/`: `Git` (finds Homebrew's or Apple's git, runs it with optional locks off, no
  prompts, BatchMode ssh, timeouts), `RepoInspector` + `StatusParser` (porcelain v2 status, remotes,
  last commit, `rev-list --branches --not --remotes` for unpushed, marker files for mid-operations),
  `RemoteURL` (remote → web page).
- `RepoRadar/Model/`: `RepoStatus` (state, `issues`, `level`, `needsAttention`/`worthALook`),
  `RepoStore` (scan, refresh, fetch, the lists the panel shows), `RepoScanner` (finds repos, skip
  list), `FolderWatcher` (FSEvents), `Preferences` (UserDefaults, injectable), `AppChoice`/`Opener`,
  `Reminder`.
- `RepoRadar/Views/`: `PanelView` (header, cards, list, footer), `RepoRow`/`ClearRow`/`RepoMenu`,
  `SettingsView`.
- `RepoRadar/Theme/`: `Mascot` (Canvas drawing, `tilt` sways while scanning), `MenuBarIcon` (template
  radar image, blip when count > 0).

## Commands
- `make run`: signed (Developer ID) dev build, opens it. Run unsandboxed.
- `make test`: unit tests; `GitTests` build throwaway repos with the user's git config ignored.
- `make screenshots`, `make icon` (redraws the app icon from Mascot).
- `-demo YES` launch argument (Debug only): sample repos, no git.
- Release: `make release VERSION=x.y.z` (see RELEASING.md). Ask Ross before releasing.

## Gotchas
- Tests run inside the app as host and share its UserDefaults domain: use a suite (`Preferences(defaults:)`).
- `git status` must keep `GIT_OPTIONAL_LOCKS=0`, or it rewrites the index, which wakes the folder
  watcher, which runs status again (`testStatusDoesNotTouchTheIndex`).
- After dev builds, `lsregister -u` the build copy so it can't hijack launches of the installed app.

## Where we left off (2026-11-12)
- **1.0.0 released** 2026-11-12: GitHub release with notes, notarized universal DMG, cask bumped by CI.
  Also live: website page + home card + privacy/terms/support/sitemap, HouseStyle 1.3.0 (More apps),
  BrewDock main has the Discover entry (ships with BrewDock's next release).
- On main, not released: panel title reads "Repo Radar" (two words; Ross asked, title only, don't
  rename elsewhere without asking). Next release: 1.0.1 (ask Ross first).
- GitHub's macOS arm64 runners were short on capacity on release day: three runs sat queued and were
  cancelled after 15 min ("job was not acquired by Runner"). A fresh `gh workflow run release.yml
  --ref vX.Y.Z -f publish=true` eventually ran; version comes from the built app, so that's equivalent.
