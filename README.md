<p align="center">
  <img src="GitCloudSync/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" alt="GitSync icon">
</p>

<h1 align="center">GitSync</h1>

<p align="center"><b>English</b> · <a href="README.zh-CN.md">简体中文</a></p>

<p align="center">
  Use private GitHub repositories as your Mac's cloud drive.<br>
  Folders sync automatically in both directions, keep every version, and never overwrite your work.
</p>

<p align="center">
  <a href="https://github.com/Atonettt/GitCloudSync/releases/latest"><img src="https://img.shields.io/github/v/release/Atonettt/GitCloudSync?label=release" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20silicon%20%26%20Intel-universal-lightgrey" alt="Universal">
  <img src="https://img.shields.io/badge/Swift-6-orange" alt="Swift 6">
</p>

<p align="center">
  <a href="https://github.com/Atonettt/GitCloudSync/releases/latest/download/GitSync.dmg"><b>Download GitSync.dmg</b></a>
</p>

---

## Features

- **Automatic two-way sync** — uploads your changes and downloads changes from your other Macs every few minutes, quietly from the menu bar.
- **Drag a folder in** — drop any folder onto the window and GitSync creates a private GitHub repository with the same name and uploads it.
- **Version history** — browse every synced version by time, by file, or among recently deleted files; preview with Quick Look, save a copy, or restore a single file or the whole folder.
- **Never overwrites** — when the same file changed on two Macs, you choose what to keep (or keep both). GitSync never force-pushes or rewrites history.
- **Disk usage at a glance** — see how much space files and history take, with a warning before a repository grows past GitHub's recommended size.
- **Follows your folders** — move or rename a synced folder and GitSync keeps tracking it; if it really is gone, GitSync helps you find it.
- **Browse and preview** — see the folder's files and preview Word, PDF, images and more right in the window, now or in any earlier version.
- **Built for many repositories** — a searchable, filterable sidebar you can reorder by dragging.
- **Delete independently** — remove the repository on GitHub or the local folder (to the Trash) without touching the other.
- **Native and bilingual** — a SwiftUI app with Liquid Glass on macOS 26, in English and Simplified Chinese.

## Installation

1. Download [**GitSync.dmg**](https://github.com/Atonettt/GitCloudSync/releases/latest/download/GitSync.dmg), open it, and drag **GitSync** into **Applications**.
2. The first time you open it, macOS says it can't verify the developer (the app isn't notarized with a paid Apple Developer ID). Click **Done**, open **System Settings › Privacy & Security**, scroll down, and click **Open Anyway**. You only need to do this once.
3. If macOS asks to install the **command line developer tools**, click **Install** — GitSync uses the Git that comes with them.

**Requirements:** macOS 14 Sonoma or later, Apple silicon or Intel, and a GitHub account.

## Getting started

1. **Sign in to GitHub.** In **Settings › GitHub Account**, paste a personal access token — [create one here](https://github.com/settings/tokens/new?scopes=repo,delete_repo&description=GitSync) with the scopes already selected. If you use the [GitHub CLI](https://cli.github.com) and have run `gh auth login`, GitSync picks it up automatically.
2. **Add folders.** Drag folders into the GitSync window. Folders already on GitHub are added as they are; plain folders get a new private repository.
3. **Turn on Auto Sync** on a repository card. It syncs right away, then at the interval you choose (5 minutes by default). Closing the window keeps GitSync syncing from the menu bar.

To switch the interface language, go to **Settings › General › Language**.

## FAQ

<details>
<summary><b>Is my data private?</b></summary>

GitSync creates **private** repositories by default, so only you (and collaborators you invite) can see them. Files go straight from your Mac to GitHub; there is no other server. Your token is stored in the macOS Keychain.
</details>

<details>
<summary><b>How is this different from iCloud Drive or Dropbox?</b></summary>

It works the same way — a normal folder that stays in sync — but the storage is your own GitHub account, and every sync is kept as a version you can browse and restore.
</details>

<details>
<summary><b>What happens if I edit the same file on two Macs?</b></summary>

GitSync detects the conflict, pauses that repository, and leaves both versions intact: yours on disk and the other one on GitHub. You then choose **Keep Both** (recommended), **Keep Local**, or **Use Remote** for each file. A backup reference is created before anything changes.
</details>

<details>
<summary><b>Can I get back an older version or a deleted file?</b></summary>

Yes, from **Version History** on the repository card. Note that you can only go back to states that were synced: edits made between two syncs are not recorded.
</details>

<details>
<summary><b>Are there size limits?</b></summary>

GitHub rejects single files over 100 MB, so GitSync keeps those local and tells you. GitHub also recommends keeping a repository under 1 GB. History grows as files change (Word, PowerPoint, and images add roughly a full copy each time), so GitSync shows each repository's size and warns you when it gets large.
</details>

<details>
<summary><b>Should I keep repositories in iCloud-synced folders?</b></summary>

It's better not to. If Desktop & Documents are synced by iCloud, iCloud may move files to the cloud or create conflict copies, which can confuse Git. A folder such as `~/GitSync` works best.
</details>

## Building from source

Requires Xcode 16 or later.

```bash
git clone https://github.com/Atonettt/GitCloudSync.git
cd GitCloudSync
xcodebuild -project GitCloudSync.xcodeproj -scheme GitCloudSync -configuration Release \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/GitCloudSync build
```

Run the tests with:

```bash
xcodebuild -project GitCloudSync.xcodeproj -scheme GitCloudSyncTests \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/GitCloudSync test
```

The tests drive real Git against temporary local repositories that stand in for GitHub and a second Mac. Architecture notes are in [Docs/Architecture.md](Docs/Architecture.md) (Chinese).

## Changelog

See [CHANGELOG.md](CHANGELOG.md) or the [releases page](https://github.com/Atonettt/GitCloudSync/releases).
