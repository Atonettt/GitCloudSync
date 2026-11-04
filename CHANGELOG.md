# Changelog

All notable changes to GitSync are documented here.

## [1.1.0] - 2026-11-04

### Added
- **Version history** in its own two-column window: browse versions by time, by file, or among recently deleted files; preview with Quick Look, save a copy next to the original, restore a single file, recover deleted files, or return the whole folder to an earlier sync after reviewing the changes.
- **Create repositories by dragging folders in**: plain folders get a new private GitHub repository with the same name, initialized and uploaded automatically.
- **Delete independently**: delete the repository on GitHub or move the local folder to the Trash, separately or together, with checks for anything not yet synced.
- **Disk usage**: each repository shows its file and history size, warns above GitHub's recommended 1 GB and 5 GB warning level, and lists the files taking the most history space.
- **English interface**, alongside Simplified Chinese, selectable in Settings › General › Language.

### Changed
- Auto sync is now controlled only by each repository's own switch, and turning it on syncs right away. "Pause All" and "Turn All On" are in the menu bar panel and the Sync menu. Existing settings are migrated without changing what syncs.
- Refreshed design: frosted glass panels (Liquid Glass on macOS 26) over a soft color backdrop.
- Repository cards are more compact, with path, remote, and branch folded under "Details".
- Menu bar panel buttons are clearer, and new commits use the app's language for their messages.

### Fixed
- The repository list in the menu bar panel was empty.
- A repository deleted on GitHub was reported as a sign-in problem.

## [1.0] - 2026-11-03

First release: automatic two-way sync of multiple folders with GitHub, safe conflict handling, GitHub sign-in via GitHub CLI, OAuth device flow, or personal access token, ignore rules for macOS and Office temporary files, menu bar operation, and sync logs.

[1.1.0]: https://github.com/Atonettt/GitCloudSync/releases/tag/v1.1.0
[1.0]: https://github.com/Atonettt/GitCloudSync/releases/tag/v1.0
