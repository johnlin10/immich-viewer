# Immich Viewer

A native macOS photo wall for an Immich server. Browse the whole library smoothly, and make everyday changes in place: favorites, descriptions, ratings, dates, places, archiving and deleting, people's names, and albums.

It keeps every small thumbnail (about 15 KB each) on this Mac, so scrolling reads from disk instead of asking the server for each one.

> **Language:** English and Traditional Chinese, following the macOS language (or the per-app language in System Settings > General > Language & Region). Simplified Chinese is planned; see [docs/localization.md](docs/localization.md).

## What it does (v0.9)

- A sidebar with Library, People, Albums, Tags, Archive and Trash.
- People: everyone Immich recognised (hidden people left out) as round faces, with their birthday and age when one is set; click one for their photos. A person's page shows the birthday and age next to the item count.
- Albums: own and shared albums as covers with name and count, newest first; click one for its photos.
- Filter and sort at the top right of every page. Filters can be combined, and with none on everything shows; choices in the same group (Photos and Videos, Named and Unnamed, Mine and Shared) add up, the others narrow. Photo pages (Library, Archive, Trash, a person, an album, a tag): Photos, Videos, Live Photos, Favorites, and Newest or Oldest First; the filter starts empty on every page, the order is kept. People: Named, Unnamed, Has Birthday; Default (Immich's order: favorites, then named, then most photographed), Name, Age either way. Albums: Mine, Shared (on servers that can tell); Recent, Name, Item Count. Tags: Name, A to Z or Z to A. The page's subtitle says how many a filter leaves.
- Person and album photos use the same grid, zoom, grouping and single photo view as the library, with a back button. A person opened from a photo opens on top of the page you were on, so back returns to the same place in the Library, an album or another person. While a photo is open only ✕ shows, which closes the photo.
- One square grid of the whole timeline (archived, hidden and locked items are left out, like Immich's own timeline). The grid fills the window; under the title bar the photos blur progressively, strongest at the top.
- Eight zoom steps (16 to 220 pt cells): the − / + buttons, ⌘− / ⌘=, or pinch on the trackpad.
- A pinch follows the fingers: the grid grows or shrinks with them, and the photo under the pointer stays under the pointer. Like in Photos, the grid fades into the next step on the way, with that photo in the same place in both; letting go settles on the closer step. The photo under the pointer keeps its column as far as the new column count allows (the photos around it move instead), so the rows don't always start at the left edge: the first row of that photo's group can start a few cells in. One pinch can move several steps. The buttons and ⌘− / ⌘= zoom one step in one continuous animation around the middle of the window (with Reduce Motion, a pinch moves in steps too).
- Clicks work like in Photos: a click chooses a photo (a blue ring), a double click, Return or Space opens it, and a click between photos clears the choice.
- Grouping: Days, Months or All. The date of the top row shows in a glass capsule under the window title.
- Keyboard in the grid: arrow keys move a selection ring, Return or Space opens it, Esc clears it, ⌘↑ / ⌘↓ (or Home / End) jump to the top and bottom. After closing a photo the ring stays on it.
- Time scrubber on the right edge instead of a scroll bar: hover to see the years, drag to go anywhere; while dragging, the month shows next to the handle.
- View menu: Refresh (⌘R), Zoom In / Zoom Out (⌘= / ⌘−), Days / Months / All (⌘1–⌘3), Show Whole Photos, Go to Top / Go to Bottom (⌘↑ / ⌘↓), Go to Date… (⌘J, a calendar; a day without photos goes to the next one).
- ⋯ menu (top right) > Show Whole Photos: whole photos inside the squares instead of cropped.
- ▶ marks videos.
- Sync progress and the item count show under the window title (hidden in the single photo view).
- The bottom controls are two glass capsules: zoom, and grouping. The chosen grouping sits on a tinted piece of glass that slides over to the next choice, like an iOS tab bar.
- Refresh (⌘R) reloads the list and downloads any new thumbnails. This also runs at launch.
- Zoom, grouping and the whole-photo setting are remembered.

### Editing

Changes go straight to the server and show in the app right away. Edit > Undo (⌘Z) takes back the last one, and Redo puts it back. If the server refuses a change (for example a key without the permission), an alert shows its message.

- Choose photos in the grid: ⌘-click adds or removes one, ⇧-click adds everything up to the clicked photo, ⌘A chooses all. The title shows how many are chosen. A plain click chooses just that photo.
- Right-click a photo (or the chosen ones) for: Add to / Remove from Favorites, Add to Album (or a New Album… with them), Add Tag…, Rotate Left / Right, Adjust Date and Time…, Set Location…, Download, Archive and Delete…. In an album also Remove from Album and Make Album Cover; on a tag's page Remove Tag; on a person's page Make Profile Photo.
- Keys in the grid and the single photo view: . (period) toggles Favorite, ⌘⌫ deletes.
- Delete asks first. Deleted photos go to the server's trash (Immich keeps them 30 days by default), and Undo brings them back. If the server has the trash turned off, the alert says the deletion is permanent and there is no undo.
- Archived photos leave the timeline, like in Immich, and show on the Archive page, where the menu has Unarchive.
- Trash page: right-click for Restore and Delete Permanently…; the ⋯ menu has Restore All and Empty Trash…. Permanent deletion asks first and can't be undone.
- Tags: Add Tag… takes a new or existing tag (a slash nests it, like "Trips/Japan"). The Tags page lists them; click one for its photos, right-click to delete it. The info panel shows a photo's tags, ✕ removes one.
- Rotate: the server keeps the original file and stores the turn as an edit (newer Immich servers only), then makes new thumbnails, which the app fetches again after a few seconds.
- Download saves the original files to the Downloads folder (a name already there gets " 2") and shows them in Finder. A panel in the middle of the window shows which file is downloading and how far along it is, with Cancel.
- File > Import… (⇧⌘I) uploads photos and videos. On an album's page they go into that album too. Files the server already has aren't uploaded twice.
- Adjust Date and Time: the first photo gets the new date and time, and the other chosen photos move by the same amount.
- Set Location: search for a place, or click the map to put the pin.
- In the single photo view, the info panel edits the description (saved on Return or when leaving the field) and the rating (click a star; click it again to clear), and the date and the place open their sheets. The ⋯ button has the same menu as a right-click, plus Open in Browser.
- People: right-click a face on the People page for Edit Person… (name and birthday), Merge With… and Hide Person. On a person's page the same are in the ⋯ menu. Merge With… picks someone who becomes this person (their photos move over); it can't be undone.
- A face recognised as the wrong person: in the info panel, right-click the person and choose Change Person….
- Albums: + on the Albums page makes a new album. Right-click a cover, or use ⋯ on the album's page, for Edit Album… (name and description) and Delete Album…. Deleting an album keeps its photos.

### Single photo view

- The photo grows out of its cell and shrinks back into it when closed. It fills the whole window, title bar included; the date and buttons sit over it.
- The people Immich found in the photo show as faces in the bottom left corner; click one for their photos.
- Click the photo or video to hide the title bar, the buttons, the faces and the info panel, and click again to bring them back. While they are hidden, pointing at the title bar shows it until the pointer leaves. A click while dragging a zoomed photo doesn't count.
- ← → or a two-finger swipe sideways for the previous and next photo. To close: ✕ (top left), Esc, or a two-finger swipe down; the photo follows the fingers and shrinks, and past a short distance letting go sends it back into the grid. Space closes a photo or pauses a video.
- Videos play in place with the system player controls (streamed from the server, like the web UI). The player appears once the video has grown out of its cell.
- Live Photos show LIVE in the top left corner: point at it to play the moving part, or click it. When the clip ends it fades back to the still.
- The ⋯ button has the editing menu and Open in Browser for anything else.
- Info panel (ⓘ or ⌘I, remembered): date and time, description, rating, file name, size and megapixels, camera and lens, aperture, shutter, focal length, ISO, place with a small map (click to open in Maps), and the people in it (named or not; click one for their photos).
- Zoom: pinch, double-click (3× at the pointer; again to go back) or ⌘= / ⌘−, up to 8×. Drag or scroll to move around. Zooming downloads the original for full sharpness (with `asset.download`; otherwise the large preview). Esc zooms out first, then closes.
- ⌘C copies the photo (original or preview) for pasting into other apps. Drag the photo out to Finder, Mail, Messages and so on to save it as a file under its original name.

### iPhone and iPad

The same project also builds an iPhone and iPad app (iOS 26 or later). It isn't in the Releases: build it from Xcode onto your own device.

- Tabs for Library, People, Albums, Tags and Settings (a sidebar on iPad). Albums also has Archive and Trash at the top.
- The same grid and grouping. Pinch the grid to change the column count (2 to 8): like the Mac, it follows the fingers and fades into the next count, keeping the photo under them in place. Pull down to refresh. The tab bar tucks away while scrolling down.
- Every page has its options in a ⋯ menu at the top right: filter, sort and (on photo pages) grouping, plus the page's own actions (Edit Album…, Merge With…, Empty Trash… and so on). Albums keeps + for a new album next to it. Once a page's large title shrinks it sits on the left, over a progressive blur.
- By day, each day's date sticks just under the title over the system's blur while its photos scroll past; by month, the date capsule shows instead.
- Select: tap Select (it turns into ✕), then tap photos to check them. With at least one checked, the ⋯ menu starts with what can be done to them.
- Long-press a photo for Share…, Favorite, Add to Album, Select, Archive and Delete…; in the Trash, Restore and Delete Permanently….
- Editing works like on the Mac, through the same menus and sheets: favorites, albums, tags, rotating, date and time, location, archiving, deleting, and people's, albums' and tags' own editing. Share… downloads the originals (a panel shows the progress, with Cancel) and opens the share sheet.
- Tap a photo to open it: it grows out of its square and shrinks back when closed. Swipe sideways for the next one, swipe up for its details (where the description, rating, date, place, tags and people can be changed), pinch or double-tap to zoom. The low-resolution thumbnail shows at once, then the large preview. Its ⋯ menu has the editing menu, Info and Open in Browser.
- A tap hides the bars and faces and turns the background black; another brings them back.
- Videos have their own controls under them (play or pause, a scrubber with the time left, sound on or off), which come and go with the bars and hide after a few seconds of playing.
- Live Photos: long-press the photo, or tap LIVE, to play the moving part.
- Settings: servers (tap to switch, swipe to change the key or remove one, Add Server…), appearance, video, the cache sizes with Clear Cache…, and the version.

### Settings (⌘,)

- General: appearance (System, Light, Dark); photo grid spacing, corner radius, Show Whole Photos, Mark Videos (▶); updates (check automatically, download and install automatically) and the version.
- Video: Play Automatically, Start Muted, Loop.
- Storage: thumbnail and face cache size, Show in Finder, Clear Cache… (thumbnails download again when shown, or all at once with ⌘R).
- Connection: server address and API key. Connect tries them first and says what's wrong (server not reachable, wrong port, key not accepted, missing permission); the key is only saved once it works. Settings > Connection lists every server: + adds one, − removes it (its key, list and thumbnails are deleted from this Mac), Change Key… replaces its key, and double-click or Use switches to it. The Server menu also switches. Each server keeps its own key (in the keychain), list and thumbnails.
- Server: commands that start and stop the server, see below.

## Setup

1. In the Immich web UI, open Account Settings > API Keys and create a new key. Browsing needs `asset.read`, `asset.view`, `person.read` and `album.read`; add `asset.download` if you want zooming, copying and dragging out to use the originals. Editing needs `asset.update`, `asset.delete`, `asset.upload`, `asset.download`, `tag.*`, `person.update`, `person.merge`, `face.update`, `album.create`, `album.update`, `album.delete`, `albumAsset.create` and `albumAsset.delete`. Leave out the ones you don't want: those changes then fail with the server's message. A key with all permissions works too.
2. Download the DMG from the [Releases page](https://github.com/johnlin10/immich-viewer/releases) and drag the app to Applications, or open `ImmichViewer.xcodeproj` in Xcode and run it (⌘R). The app is signed with a development certificate only, so the first time macOS blocks it: open System Settings > Privacy & Security and click Open Anyway.
3. Enter the server address and the key. The key is saved in the login keychain. Change it later in Settings (⌘,).

The first sync downloads every thumbnail (about 15 KB each), so a large library takes a while and some disk space. Progress shows under the window title.

### Server address

Use the same address you open the Immich web UI with:

- Immich on this Mac: `http://localhost:2283`
- Immich on another computer in your network (a NAS, a home server): its IP address or name and port, for example `http://192.168.1.20:2283` or `http://nas.local:2283`. The first time, macOS asks whether Immich Viewer may find devices on the local network; allow it. If you said no, turn it on in System Settings > Privacy & Security > Local Network.
- From outside your network: the `https` address of your reverse proxy, or the server's Tailscale address.

`http://` is added if you leave it out, and a trailing `/api` is ignored. Plain `http` works for any address, because home servers rarely have certificates; over the internet, use `https`.

### Starting and stopping the server

If Immich only runs while you need it, Settings > Server takes a start and a stop command. Each server has its own: the tab shows the current server's, and a server without commands (a NAS that's always on) leaves them empty. They run in zsh as in Terminal, so `docker` and `ssh` are found as usual.

| Where Immich runs | Start | Stop |
|---|---|---|
| This Mac, Docker Compose in `~/immich-app` | `cd ~/immich-app && docker compose up -d` | `cd ~/immich-app && docker compose stop` |
| Another computer, over SSH | `ssh nas 'cd immich-app && docker compose up -d'` | `ssh nas 'cd immich-app && docker compose stop'` |

SSH needs key login (no password prompt), for example with `ssh-copy-id nas`. If Docker Desktop isn't running yet, put `open -a Docker && sleep 20 && ` in front of the start command.

- The Server menu has Start Server and Stop Server. After starting, the app waits until the server answers (up to 3 minutes), then syncs.
- Two switches per server: start it when the app opens or switches to it (only if it isn't answering), and stop it when the app quits (only if the app started it, so a server that was already running for phone backups stays up). Each server the app started is stopped with its own command.
- If a command fails, its output shows in Settings > Server.

### Updates

From v0.4 the app updates itself with [Sparkle](https://sparkle-project.org): it checks about once a day, shows what's new and installs the update when you agree (Immich Viewer > Check for Updates… checks right away). Settings > General can turn the checks off or install updates without asking. Each update is signed, and the app only installs one signed with this project's key. Versions before v0.4 don't have this; install v0.4 once by hand.

## Where data is kept

Each server has its own folder, named after its address (`http://nas.local:2283` → `nas-local-2283`):

- Thumbnails: `~/Library/Caches/ImmichViewer/<server>/thumbnails` (faces in `.../faces`)
- Last lists, so pages show at once while the new ones load: `~/Library/Application Support/ImmichViewer/<server>/`, with the timeline in `assets.json`, people, albums and tags in `collections.json`, and each person's, album's and tag's photos in `pages/`
- API keys: the login keychain, one per server address
- Server addresses, start and stop commands (per server), and view settings: the app’s preferences (`local.ImmichViewer`)

Removing a server in Settings > Connection deletes its key and both folders. Updating from v0.6 moves the single server's key, thumbnails and list into its new folder, so nothing downloads again.

## Development

- macOS 26 or later (Liquid Glass), Xcode 26 or later. One target builds both the Mac app and the iPhone and iPad app (`#if os(iOS)` / `#if os(macOS)`); to run it on a phone, choose the device in Xcode. Files dropped into the `ImmichViewer/` folder (any subfolder) are added to the target automatically.
- Signing uses your Apple Development certificate (team set in the project), so the keychain keeps trusting rebuilt versions.
- Debug builds take these environment variables (Edit Scheme > Run > Arguments): `IMMICH_API_KEY` (skips the keychain), `IMMICH_SERVER` (another server address) and `IMMICH_VIEWER_PROFILE` (keeps the list and thumbnails in separate `ImmichViewer-<name>` folders, so a test server doesn't mix with your library).
- Grid and grouping checks, no Xcode needed:

```bash
swiftc ImmichViewer/Core/TimelineModel.swift ImmichViewer/Core/ThumbnailStore.swift ImmichViewer/Core/ImmichAPI.swift Tests/main.swift -o /tmp/immichviewer-check && /tmp/immichviewer-check
```

- Installer: `scripts/make-dmg.sh` builds Release and makes `build/ImmichViewer-<version>.dmg`, a window with the app, an Applications shortcut and a background (`scripts/dmg-background.tiff`) that says to drag it across. It needs [uv](https://docs.astral.sh/uv/) (`brew install uv`), which runs dmgbuild; the layout is in `scripts/dmg-settings.py`. The app is signed with a development certificate only, so on another Mac it has to be allowed once in System Settings > Privacy & Security.
- Releasing: commit with the new `MARKETING_VERSION` (the build number follows it, since Sparkle compares that), push, then run `scripts/release.sh notes.md` in Terminal. It builds the DMG, signs it into the update feed `appcast.xml` (keeping the earlier entries from the latest Release) and publishes GitHub Release `vX.Y.Z` with the DMG, the feed and the notes. The app reads the feed from `releases/latest/download/appcast.xml`, so the newest Release is always the feed. `DRY_RUN=1` stops before publishing.
- Update signing key: made once with Sparkle's `generate_keys --account immich-viewer`; the private key is in the login keychain, the public key is `SUPublicEDKey` in `Info.plist`. Back it up (`generate_keys --account immich-viewer -x <file>`, kept somewhere safe and never in the repo): without it, installed copies can't be updated any more. The first `release.sh` run asks for keychain access; allow it.

Sources are grouped by where they run. Every file is compiled for both platforms; the Mac and iOS folders are wrapped in `#if os(macOS)` / `#if os(iOS)`.

| File | Contents |
|---|---|
| **`Core/`** | Data and network, no interface (the command-line checks build these) |
| `ImmichAPI.swift` | Immich API calls, keychain |
| `Library.swift` | Connection, starting and stopping the server, asset list, sync |
| `ThumbnailStore.swift` | Disk and memory thumbnail cache |
| `TimelineModel.swift` | Asset, filters, grouping, grid geometry, row moves, date lookup, year marks |
| **`Shared/`** | Interface used on the Mac and on iPhone and iPad |
| `Collections.swift` | Filter and sort menus, People, Albums and Tags pages, one person's, album's or tag's grid, the iOS page bar |
| `Editing.swift` | Photo menu and what its actions do, page menus, date, location, album, person and tag sheets, download progress, share sheet |
| `InfoPanel.swift` | A photo's details (⌘I on the Mac, swipe up on iOS) and its row of faces |
| `LivePhoto.swift` | A Live Photo's moving part and the LIVE badge |
| **`Mac/`** | The Mac app |
| `ImmichViewerApp.swift` | App window and sidebar, View menu, timeline page, bottom bar, title bar blur |
| `PhotoGrid.swift` | NSCollectionView grid, zoom, clicks, pinch, keyboard selection, cells, headers |
| `PhotoViewer.swift` | Single photo view, zoom and pan, copy and drag-out, video player, swipes |
| `Scrubber.swift` | Date capsule, time scrubber, Go to Date sheet |
| `Settings.swift` | Settings window: appearance, grid, video, storage, connection |
| **`iOS/`** | The iPhone and iPad app |
| `PhoneApp.swift` | Tabs |
| `PhoneGrid.swift` | UICollectionView grid, pinch, sticky dates, checkmarks, long-press menu, open and close transitions |
| `PhoneTimeline.swift` | Photo page and photo view: Select, menus, pager, zoom, video controls |
| `PhoneSettings.swift` | Settings tab and connect form |
| **`Resources/`** | |
| `Localizable.xcstrings` | Interface text and its translations |
| `InfoPlist.xcstrings` | The app's name in each language |

## Not in this version

Searching, map, memories, Simplified Chinese interface, and noticing deletions made in the browser until the next refresh. Thumbnails of deleted photos stay in the cache.

Planned editing: cropping, dropping files on the window to upload, then stacks, sharing, duplicates and memories.

## Version history

### v0.9.0 (current)

- Downloading shows a panel with the file it's on, a progress bar and Cancel (the Mac's Download, and Share… on iOS).
- People, albums and tags, and each person's, album's and tag's photos, are kept on disk: they show at once when the app opens or a page opens, and update when the server's lists differ. People, albums and tags load alongside the timeline instead of after it.
- iPhone and iPad: editing. Select mode with checkmarks, a ⋯ menu on every page with filter, sort, grouping and the selection's actions, a long-press menu, Share…, editing in the photo view and its details, and editing people, albums and tags. Archive and Trash at the top of Albums.
- iPhone and iPad: the Servers tab became Settings, with servers, appearance, video and storage.
- iPhone and iPad: page titles sit on the left once they shrink, over a progressive blur on every page; a person's, album's or tag's page opens with its buttons and item count already in place, at the top.

### v0.8.1

- Source files grouped in folders by where they run: Core, Shared, Mac, iOS and Resources. The photo details panel moved to its own file, shared by both apps. No change in the app.

### v0.8.0

- An iPhone and iPad app in the same project, for browsing (built from Xcode, not in the Releases): Library, People, Albums, Tags and Servers; the same grid, filters and grouping; a photo view with swipes, zoom, details, faces and video controls.
- Live Photos: LIVE in the photo view plays the moving part (point at it or click it on the Mac; long-press or tap it on iOS).
- A Live Photos filter on photo pages. Older lists learn which photos are Live Photos on the next refresh.

### v0.7.2

- Filter and sort at the top right of every page, with icons. Photo pages: Photos, Videos, Favorites; Newest or Oldest First (moved here from Settings > General). People: Named, Unnamed, Has Birthday; Default, Name, Age. Albums: Mine, Shared; Recent, Name, Item Count. Tags: Name, A to Z or Z to A.
- Filters combine, and with none on everything shows; the subtitle says how many are shown.
- The selected count updates when a filter hides chosen photos.

### v0.7.1

- People with a birthday show it and their age (whole years) under their name on the People page, and next to the item count on their own page.

### v0.7.0

- Several servers: Settings > Connection lists them with + and −, Change Key… and Use (or double-click). The Server menu also switches.
- Each server keeps its own API key, asset list, thumbnails, and start and stop commands. Switching stops a running sync first.
- Start Automatically also starts a server when you switch to it; Stop When Quitting stops each server the app started, with its own command.
- Updating from v0.6 moves the existing key, thumbnails, list and commands to the current server.

### v0.6.2

- Archive, Trash and Tags pages. Restore, delete permanently, empty the trash.
- Add and remove tags, rotate photos, download originals, upload with File > Import….
- Merge people, and move a face to the right person.
- With Show Whole Photos on, opening and closing a photo animates from the whole photo, not the filled square.

### v0.6.1

- Faces of the people in a photo in the bottom left corner of the single photo view.
- Opening a person from a photo keeps your place: back returns to the Library (or album) where you were. In a person's or album's photo, ✕ is the only button on the left, so it can't jump back two pages.

### v0.6

- Editing: choose several photos (⌘-click, ⇧-click, ⌘A) and right-click them; favorites, ratings, descriptions, dates, places, archive and delete (to the trash, with undo); people's names, birthdays, hiding and profile photos; new albums, renaming, descriptions, covers, adding and removing photos, deleting albums. Undo and Redo for each change.
- Clicks like in Photos: a click chooses a photo and a double click opens it (until v0.5 a click opened it, or zoomed in at the five smallest steps).

### v0.5

- Single photo view: the photo fills the window, a click hides and shows the controls, ✕ moved to the top left, swipe down to close, clickable people (unnamed ones too) in the info panel, and a video no longer shows twice while it opens.
- Grid: pinching follows the fingers around the photo under the pointer and crossfades between zoom steps, like in Photos, and that photo keeps its column when the step changes; the grouping selection is a piece of glass that slides to the new choice.

### v0.4

- Updates inside the app with Sparkle: automatic checks, Check for Updates…, release notes, install and relaunch. `scripts/release.sh` publishes a version.
- The DMG runs on Intel Macs too (until v0.3 it was Apple silicon only).

### v0.3

- Start and stop commands for the server (Settings > Server, Server menu), optionally run when the app opens and quits.
- Servers on other computers: addresses without `http://`, plain `http` to any host, the Local Network permission, and Connect checks the address and key before saving.

### v0.2

- English and Traditional Chinese interface, following the macOS language. English is now the source language; the translations live in `ImmichViewer/Resources/Localizable.xcstrings`.
- A DMG installer (`scripts/make-dmg.sh`): drag the app to Applications.

### v0.1

- First version: a grid of the whole Immich library, people and albums, single photo view and video playback.
- Info panel, zoom in the single photo view, copy and drag-out, time scrubber, keyboard navigation, View menu and Settings window.

## License

MIT License, see [LICENSE](LICENSE).
