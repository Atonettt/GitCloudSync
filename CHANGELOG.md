# Changelog

All notable changes to GitSync are documented here.

## [1.3.0] - 2026-11-06

### Added
- **Repositories on GitHub**: download any of your GitHub repositories to this Mac as a synced folder, open it on GitHub, or delete ones you no longer need, including ones with no folder here.
- **Download again from GitHub**: when a synced folder was deleted, download it back to where it was (or somewhere else) and keep syncing.
- **Revert to the GitHub version**: undo changes that aren't synced yet, for a file or a whole folder, from the pending-changes list or the file browser. The discarded content is kept in a local backup.
- **Documents open in Word, Excel or PowerPoint are refreshed**: after a sync downloads a newer version, an unchanged open document is reopened with the new content; one with unsaved edits asks whether to keep both versions or use GitHub's.
- **Compare changes**: next to the preview, see what changed since the previous sync point, in the main window and in version history. Word, PDF and text files show added, removed and edited paragraphs with the changed words marked; Excel lists the changed cells; images are shown side by side. Files changed at the last sync are marked Modified or New in the file list.
- Each repository in the sidebar shows whether Auto Sync is on, and one click turns it on or off. New filters: Auto Sync On and Paused.

### Changed
- GitSync uses the macOS system proxy (for example Clash) when talking to GitHub, so syncing works wherever your browser does.
- A simpler toolbar and menu bar: one Sync All button whose menu holds the sync interval, one Add Repository button for local folders and GitHub, and an Auto Sync switch in the menu bar.
- A more compact repository page, an account card at the bottom of the sidebar, and a file list that updates by itself.
- PDFs in the preview scroll through all pages and fit the width; previews refresh when a sync changes the file.
- Deleting a repository no longer asks you to type its name.
- A smaller menu bar panel.

### Fixed
- A folder linked while its GitHub repository was still empty now downloads content pushed there later, even when it is on a branch other than `main` (GitSync follows GitHub's default branch). Local files with the same names are never overwritten.
- GitSync could quit unexpectedly when a file preview closed before it finished loading.
- Choosing a sync interval now shows the checkmark on the new value.

## [1.2.0] - 2026-11-04

### Added
- **Files and preview in the main window**: browse the repository folder like Finder, see which files aren't synced yet, and preview Word, Excel, PDF, images and more inline. Word pages zoom to fit the pane.
- **Version history preview**: the history window now has three columns (versions, the files in a version, and a live preview), and can show every file as it was in a version, not only the changed ones.
- **Moved and renamed folders are followed** (like a Finder alias). If a folder really is gone, GitSync finds it with Spotlight, lets you point it to the new place, or puts it back from the Trash.
- **GitHub follows folder renames**: renaming a synced folder renames its GitHub repository to match (Chinese names become pinyin); your other Mac picks up the new name. Can be turned off in Settings.
- **Many repositories**: a native sidebar with search, filters, drag-to-reorder and sorting.
- Click the path or remote URL in the details popover to copy it.

### Changed
- A native macOS layout: full-height sidebar, toolbar in the title bar, and a single repository page with the Auto Sync switch and Sync Now side by side.
- The menu bar icon is now the app's cat with a status badge.
- Smaller app (debug symbols stripped) and cheaper disk-usage checks for large repositories.

### Fixed
- With macOS set to "prefer tabs", closing version history no longer closes the main window, and the Dock icon always reopens the main window.

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

[1.3.0]: https://github.com/Atonettt/GitCloudSync/releases/tag/v1.3.0
[1.2.0]: https://github.com/Atonettt/GitCloudSync/releases/tag/v1.2.0
[1.1.0]: https://github.com/Atonettt/GitCloudSync/releases/tag/v1.1.0
[1.0]: https://github.com/Atonettt/GitCloudSync/releases/tag/v1.0
