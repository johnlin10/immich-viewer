# Immich Viewer

A native macOS photo wall for an Immich server. It only browses; deleting, editing, naming people and changing albums stay in the Immich web UI.

It keeps every small thumbnail (about 15 KB each) on this Mac, so scrolling reads from disk instead of asking the server for each one.

## What it does (v0.1.0)

- A sidebar with 圖庫, 人物 and 相簿.
- 人物: everyone Immich recognised (hidden people left out) as round faces; click one for their photos.
- 相簿: own and shared albums as covers with name and count, newest first; click one for its photos.
- Person and album photos use the same grid, zoom, grouping and single photo view as the library, with a back button.
- One square grid of the whole timeline (archived, hidden and locked items are left out, like Immich's own timeline). The grid fills the window; under the title bar the photos blur progressively, strongest at the top.
- Eight fixed zoom steps (16 to 220 pt cells): the − / + buttons, ⌘− / ⌘=, or pinch on the trackpad. One pinch can move several steps. Each step is one continuous zoom: the old grid and the new one scale together around the photo you clicked or pinched (the − / + buttons zoom around the middle of the window).
- In the five smallest steps a click zooms in one step and keeps the clicked photo where it was on screen. From 110 pt on, a click opens the photo.
- Keyboard in the grid: arrow keys move a selection ring, Return or Space opens it, Esc clears it, ⌘↑ / ⌘↓ (or Home / End) jump to the top and bottom. After closing a photo the ring stays on it.
- Time scrubber on the right edge instead of a scroll bar: hover to see the years, drag to go anywhere; while dragging, the month shows next to the handle.
- 顯示方式 menu: 重新整理 (⌘R), 放大 / 縮小 (⌘= / ⌘−), 依日 / 依月 / 不分組 (⌘1–⌘3), 顯示完整比例, 跳到最上方 / 最下方 (⌘↑ / ⌘↓), 跳到日期… (⌘J, a calendar; a day without photos goes to the next one).
- Single photo view: the photo grows out of its cell and shrinks back into it when closed. The date sits in the middle of the title bar, the photo below it. ← → or a two-finger swipe for the previous and next photo, Esc or ✕ to close. Videos play in place with the system player controls (streamed from the server, like the web UI). Editing opens in the browser (Safari button).
- Info panel (ⓘ or ⌘I, remembered): date and time, file name, size and megapixels, camera and lens, aperture, shutter, focal length, ISO, place with a small map (click to open in Maps), named people, and the description.
- Zoom in the single photo view: pinch, double-click (3× at the pointer; again to go back) or ⌘= / ⌘−, up to 8×. Drag or scroll to move around. Zooming downloads the original for full sharpness (with `asset.download`; otherwise the large preview). Esc zooms out first, then closes. Space closes a photo or pauses a video.
- ⌘C copies the photo (original or preview) for pasting into other apps. Drag the photo out to Finder, Mail, Messages and so on to save it as a file under its original name.
- ⋯ menu (top right) > 顯示完整比例: whole photos inside the squares instead of cropped.
- Grouping: 依日, 依月 or 不分組. The date of the top row shows in a glass capsule under the window title.
- ▶ marks videos.
- Sync progress and the item count show under the window title (hidden in the single photo view).
- The bottom controls are two glass capsules: zoom, and grouping (the options sit right in the capsule).
- 顯示方式 > 重新整理 (⌘R) reloads the list and downloads any new thumbnails. This also runs at launch.
- Zoom, grouping and the whole-photo setting are remembered.
- Settings (⌘,):
  - 一般: appearance (system, light, dark); grid sort order (newest or oldest first), spacing, corner radius, whole photos, ▶ video marks.
  - 影片: autoplay, start muted, loop.
  - 儲存空間: thumbnail and face cache size, show in Finder, clear the cache (thumbnails download again when shown, or all at once with ⌘R).
  - 連線: server address and API key.

## Setup

1. In the Immich web UI, open 帳號設定 > API 金鑰 and create a new key with only `asset.read`, `asset.view`, `person.read` and `album.read`. Add `asset.download` if you want zooming, copying and dragging out to use the originals.
2. Open `ImmichViewer.xcodeproj` in Xcode and run it (⌘R).
3. Enter the server address (default `http://localhost:2283`) and the key. The key is saved in the login keychain. Change it later in Settings (⌘,).

The first sync downloads all thumbnails, about 2.5 GB for 165,000 items. Progress shows under the window title.

## Where data is kept

- Thumbnails: `~/Library/Caches/ImmichViewer/thumbnails` (faces in `.../faces`)
- Last asset list (for instant start): `~/Library/Application Support/ImmichViewer/assets.json`
- Server address and view settings: the app's preferences (`local.ImmichViewer`)

Delete these folders to start fresh, for example after switching servers.

## Development

- macOS 26 or later (Liquid Glass), Xcode 26 or later. Files dropped into the `ImmichViewer/` folder are added to the target automatically.
- Signing uses your Apple Development certificate (team set in the project), so the keychain keeps trusting rebuilt versions.
- Debug builds take these environment variables (Edit Scheme > Run > Arguments): `IMMICH_API_KEY` (skips the keychain), `IMMICH_SERVER` (another server address) and `IMMICH_VIEWER_PROFILE` (keeps the list and thumbnails in separate `ImmichViewer-<name>` folders, so a test server doesn't mix with your library).
- Grid and grouping checks, no Xcode needed:

```bash
swiftc ImmichViewer/TimelineModel.swift ImmichViewer/ThumbnailStore.swift ImmichViewer/ImmichAPI.swift Tests/main.swift -o /tmp/immichviewer-check && /tmp/immichviewer-check
```

| File | Contents |
|---|---|
| `ImmichViewerApp.swift` | App window and sidebar, 顯示方式 menu, timeline page, bottom bar, title bar blur |
| `Settings.swift` | Settings window: appearance, grid, video, storage, connection |
| `Scrubber.swift` | Date capsule, time scrubber, jump-to-date sheet |
| `Library.swift` | Connection, asset list, sync |
| `ImmichAPI.swift` | Immich API calls, keychain |
| `ThumbnailStore.swift` | Disk and memory thumbnail cache |
| `PhotoGrid.swift` | NSCollectionView grid, zoom, clicks, pinch, keyboard selection, cells, headers |
| `PhotoViewer.swift` | Single photo view, zoom and pan, info panel, copy and drag-out, video player, swipes |
| `Collections.swift` | People and album pages, one person's or album's grid |
| `TimelineModel.swift` | Asset, grouping, grid geometry, row moves, date lookup, year marks |

## Not in this version

Searching, map, memories, and noticing deletions made in the browser until the next refresh. Thumbnails of deleted photos stay in the cache.

## 版本歷程

### v0.1（目前版本）

- 第一版：整個 Immich 圖庫的方格牆，人物和相簿，單張檢視與影片播放
- 資訊面板、放大檢視、拷貝與拖出、時間捲軸、鍵盤操作、顯示方式選單和設定視窗

## 授權

MIT License，見 [LICENSE](LICENSE)。
