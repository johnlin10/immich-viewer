# Immich Viewer

A native macOS photo wall for an Immich server. It only browses; deleting, editing, naming people and changing albums stay in the Immich web UI.

It keeps every small thumbnail (about 15 KB each) on this Mac, so scrolling reads from disk instead of asking the server for each one.

> **Language:** English and Traditional Chinese, following the macOS language (or the per-app language in System Settings > General > Language & Region). Simplified Chinese is planned; see [docs/localization.md](docs/localization.md).

## What it does (v0.3)

- A sidebar with Library, People and Albums.
- People: everyone Immich recognised (hidden people left out) as round faces; click one for their photos.
- Albums: own and shared albums as covers with name and count, newest first; click one for its photos.
- Person and album photos use the same grid, zoom, grouping and single photo view as the library, with a back button.
- One square grid of the whole timeline (archived, hidden and locked items are left out, like Immich's own timeline). The grid fills the window; under the title bar the photos blur progressively, strongest at the top.
- Eight fixed zoom steps (16 to 220 pt cells): the − / + buttons, ⌘− / ⌘=, or pinch on the trackpad. One pinch can move several steps. Each step is one continuous zoom: the old grid and the new one scale together around the photo you clicked or pinched (the − / + buttons zoom around the middle of the window).
- In the five smallest steps a click zooms in one step and keeps the clicked photo where it was on screen. From 110 pt on, a click opens the photo.
- Grouping: Days, Months or All. The date of the top row shows in a glass capsule under the window title.
- Keyboard in the grid: arrow keys move a selection ring, Return or Space opens it, Esc clears it, ⌘↑ / ⌘↓ (or Home / End) jump to the top and bottom. After closing a photo the ring stays on it.
- Time scrubber on the right edge instead of a scroll bar: hover to see the years, drag to go anywhere; while dragging, the month shows next to the handle.
- View menu: Refresh (⌘R), Zoom In / Zoom Out (⌘= / ⌘−), Days / Months / All (⌘1–⌘3), Show Whole Photos, Go to Top / Go to Bottom (⌘↑ / ⌘↓), Go to Date… (⌘J, a calendar; a day without photos goes to the next one).
- ⋯ menu (top right) > Show Whole Photos: whole photos inside the squares instead of cropped.
- ▶ marks videos.
- Sync progress and the item count show under the window title (hidden in the single photo view).
- The bottom controls are two glass capsules: zoom, and grouping (the options sit right in the capsule).
- Refresh (⌘R) reloads the list and downloads any new thumbnails. This also runs at launch.
- Zoom, grouping and the whole-photo setting are remembered.

### Single photo view

- The photo grows out of its cell and shrinks back into it when closed. The date sits in the middle of the title bar, the photo below it.
- ← → or a two-finger swipe for the previous and next photo, Esc or ✕ to close. Space closes a photo or pauses a video.
- Videos play in place with the system player controls (streamed from the server, like the web UI).
- Editing opens in the browser (Safari button).
- Info panel (ⓘ or ⌘I, remembered): date and time, file name, size and megapixels, camera and lens, aperture, shutter, focal length, ISO, place with a small map (click to open in Maps), named people, and the description.
- Zoom: pinch, double-click (3× at the pointer; again to go back) or ⌘= / ⌘−, up to 8×. Drag or scroll to move around. Zooming downloads the original for full sharpness (with `asset.download`; otherwise the large preview). Esc zooms out first, then closes.
- ⌘C copies the photo (original or preview) for pasting into other apps. Drag the photo out to Finder, Mail, Messages and so on to save it as a file under its original name.

### Settings (⌘,)

- General: appearance (System, Light, Dark); photo grid sort order (Newest First, Oldest First), spacing, corner radius, Show Whole Photos, Mark Videos (▶).
- Video: Play Automatically, Start Muted, Loop.
- Storage: thumbnail and face cache size, Show in Finder, Clear Cache… (thumbnails download again when shown, or all at once with ⌘R).
- Connection: server address and API key. Connect tries them first and says what's wrong (server not reachable, wrong port, key not accepted, missing permission); the key is only saved once it works.
- Server: commands that start and stop the server, see below.

## Setup

1. In the Immich web UI, open Account Settings > API Keys and create a new key with only `asset.read`, `asset.view`, `person.read` and `album.read`. Add `asset.download` if you want zooming, copying and dragging out to use the originals.
2. Open `ImmichViewer.xcodeproj` in Xcode and run it (⌘R), or install the DMG from the Releases page.
3. Enter the server address and the key. The key is saved in the login keychain. Change it later in Settings (⌘,).

The first sync downloads all thumbnails, about 2.5 GB for 165,000 items. Progress shows under the window title.

### Server address

Use the same address you open the Immich web UI with:

- Immich on this Mac: `http://localhost:2283`
- Immich on another computer in your network (a NAS, a home server): its IP address or name and port, for example `http://192.168.1.20:2283` or `http://nas.local:2283`. The first time, macOS asks whether Immich Viewer may find devices on the local network; allow it. If you said no, turn it on in System Settings > Privacy & Security > Local Network.
- From outside your network: the `https` address of your reverse proxy, or the server's Tailscale address.

`http://` is added if you leave it out, and a trailing `/api` is ignored. Plain `http` works for any address, because home servers rarely have certificates; over the internet, use `https`.

### Starting and stopping the server

If Immich only runs while you need it, Settings > Server takes a start and a stop command. They run in zsh as in Terminal, so `docker` and `ssh` are found as usual.

| Where Immich runs | Start | Stop |
|---|---|---|
| This Mac, Docker Compose in `~/immich-app` | `cd ~/immich-app && docker compose up -d` | `cd ~/immich-app && docker compose stop` |
| Another computer, over SSH | `ssh nas 'cd immich-app && docker compose up -d'` | `ssh nas 'cd immich-app && docker compose stop'` |

SSH needs key login (no password prompt), for example with `ssh-copy-id nas`. If Docker Desktop isn't running yet, put `open -a Docker && sleep 20 && ` in front of the start command.

- The Server menu has Start Server and Stop Server. After starting, the app waits until the server answers (up to 3 minutes), then syncs.
- Two switches: start the server when the app opens (only if it isn't answering), and stop it when the app quits (only if the app started it, so a server that was already running for phone backups stays up).
- If a command fails, its output shows in Settings > Server.

## Where data is kept

- Thumbnails: `~/Library/Caches/ImmichViewer/thumbnails` (faces in `.../faces`)
- Last asset list (for instant start): `~/Library/Application Support/ImmichViewer/assets.json`
- Server address, start and stop commands, and view settings: the app’s preferences (`local.ImmichViewer`)

Delete these folders to start fresh, for example after switching servers.

## Development

- macOS 26 or later (Liquid Glass), Xcode 26 or later. Files dropped into the `ImmichViewer/` folder are added to the target automatically.
- Signing uses your Apple Development certificate (team set in the project), so the keychain keeps trusting rebuilt versions.
- Debug builds take these environment variables (Edit Scheme > Run > Arguments): `IMMICH_API_KEY` (skips the keychain), `IMMICH_SERVER` (another server address) and `IMMICH_VIEWER_PROFILE` (keeps the list and thumbnails in separate `ImmichViewer-<name>` folders, so a test server doesn't mix with your library).
- Grid and grouping checks, no Xcode needed:

```bash
swiftc ImmichViewer/TimelineModel.swift ImmichViewer/ThumbnailStore.swift ImmichViewer/ImmichAPI.swift Tests/main.swift -o /tmp/immichviewer-check && /tmp/immichviewer-check
```

- Installer: `scripts/make-dmg.sh` builds Release and makes `build/ImmichViewer-<version>.dmg`, a window with the app, an Applications shortcut and a background (`scripts/dmg-background.tiff`) that says to drag it across. It needs [uv](https://docs.astral.sh/uv/) (`brew install uv`), which runs dmgbuild; the layout is in `scripts/dmg-settings.py`. The app is signed with a development certificate only, so on another Mac it has to be allowed once in System Settings > Privacy & Security.

| File | Contents |
|---|---|
| `ImmichViewerApp.swift` | App window and sidebar, View menu, timeline page, bottom bar, title bar blur |
| `Settings.swift` | Settings window: appearance, grid, video, storage, connection |
| `Scrubber.swift` | Date capsule, time scrubber, Go to Date sheet |
| `Library.swift` | Connection, starting and stopping the server, asset list, sync |
| `ImmichAPI.swift` | Immich API calls, keychain |
| `ThumbnailStore.swift` | Disk and memory thumbnail cache |
| `PhotoGrid.swift` | NSCollectionView grid, zoom, clicks, pinch, keyboard selection, cells, headers |
| `PhotoViewer.swift` | Single photo view, zoom and pan, info panel, copy and drag-out, video player, swipes |
| `Collections.swift` | People and album pages, one person's or album's grid |
| `TimelineModel.swift` | Asset, grouping, grid geometry, row moves, date lookup, year marks |
| `Localizable.xcstrings` | Interface text and its translations |

## Not in this version

Searching, map, memories, Simplified Chinese interface, and noticing deletions made in the browser until the next refresh. Thumbnails of deleted photos stay in the cache.

## Version history

### v0.3 (current)

- Start and stop commands for the server (Settings > Server, Server menu), optionally run when the app opens and quits.
- Servers on other computers: addresses without `http://`, plain `http` to any host, the Local Network permission, and Connect checks the address and key before saving.

### v0.2

- English and Traditional Chinese interface, following the macOS language. English is now the source language; the translations live in `ImmichViewer/Localizable.xcstrings`.
- A DMG installer (`scripts/make-dmg.sh`): drag the app to Applications.

### v0.1

- First version: a grid of the whole Immich library, people and albums, single photo view and video playback.
- Info panel, zoom in the single photo view, copy and drag-out, time scrubber, keyboard navigation, View menu and Settings window.

## License

MIT License, see [LICENSE](LICENSE).
