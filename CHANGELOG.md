# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.3.1] - 2026-10-12

### Changed
- The app is now called **Clair** (previously ClairClass): app name, window title, menus, permission prompts, `Clair.app` and the DMG name.
- New app icon: the “clair” wordmark on a white rounded square, built from `Resources/AppIcon.png` instead of being drawn in code.

### Notes
- The bundle identifier (`local.clairclass.mac`) and the data folder (`~/Library/Application Support/ClairClass/`) are unchanged, so existing classes, settings and permissions carry over.

## [0.3.0] - 2026-10-12

First public release.

### Added
- macOS 26 redesign: Mail-style folder title, native sidebar counts, class header, Liquid Glass capture bar with timer and input level, "jump to latest" while reading back, citation highlight, ⌘K palette with keyboard navigation, View menu text size (⌘+ / ⌘− / ⌘0), ⌥⌘F search.
- Multi-selection with batch move, move to Recently Deleted and restore; permanent deletion from Recently Deleted (single, batch or "Empty Recently Deleted"), always confirmed.
- Project deletion (classes move to Unfiled), drag classes onto Unfiled / Recently Deleted, drag audio files into the window to import.
- Per-line copy and re-translate; Markdown tables, lists and quotes in assistant answers.
- Translation quality: sentence halves split by pauses are merged before translation, fillers and stutters are removed from the translation input, fallback lines are re-translated with Gemma when idle, the translation model stays loaded for 2 h, and the model service restarts automatically.
- Uncertain-word marks from recogniser confidence (content words below 0.5), with a setting to turn them off.
- Launch arguments for UI checks against fixture data (`-ClairClassDataRoot` and `-ClairClassUITest…`).

### Fixed
- Launch could replace a capture started during model warm-up; history was loaded twice.
- The input meter redrew the whole window about 23 times per second.
- "Show French" changed from the toolbar was not saved unless Settings was open.
- ⌘R paused an audio import that could not be resumed.
- Reopened classes showed "translating…" forever for abandoned lines.
- Following the same citation twice did nothing; the ⌘K palette ignored arrow keys.
- Selecting a class rewrote the previous one to disk; autosave scanned the whole library.
- French closing guillemets (`? »`) made finished sentences look unfinished.
- Swift 6 strict-concurrency warnings.

## [0.2.0] - 2026-10-11

### Added
- Three-column interface with projects, rename, Recently Deleted and restore.
- Class assistant (notes, minutes, Q&A) with timestamp citations.
- Model selection and download in Settings.
