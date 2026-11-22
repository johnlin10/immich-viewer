# 階段 1：網頁端的變更即時反映、清掉已刪照片的縮圖

README「Not in this version」裡的兩項：

- noticing deletions made in the browser until the next refresh
- Thumbnails of deleted photos stay in the cache

這一階段不調 `MARKETING_VERSION`，也不寫 Version history（整波做完才發佈一次）。不新增介面字串，所以這階段不需要翻譯。

## 已確認的伺服器行為（Immich v3.4.0，本機 Docker `immich_server`）

- socket.io 4.8.4，path `/api/socket.io`，`transports: ['websocket']`（只接受 WebSocket，不能用 long polling）。
- 驗證：連線時用 `authService.authenticate({ headers, queryParams })`，**`x-api-key` header 可以用**。驗證失敗時伺服器呼叫 `client.disconnect()`。成功後 client 加入 `user.id` 這個 room。
- 會收到的事件（`ClientEventMap`）：
  - `on_asset_trash: [string[]]`：移到垃圾桶（單張或多張）
  - `on_asset_delete: [string]`：永久刪除，一次一張
  - `on_asset_hidden: [string]`
  - `on_asset_restore: [string[]]`：從垃圾桶復原
  - `on_asset_update: [AssetResponseDto]`：改了喜好、封存、日期、說明等。`PUT /assets` 每張發一次，所以本 App 自己做的編輯也會收到回聲
  - `on_upload_success: [AssetResponseDto]`
  - 其他（`on_album_update`、`on_person_thumbnail`、`on_asset_stack_update`、`AssetEditReadyV2`、`on_server_version`…）這階段一律忽略。`AssetEditReadyV2` 留到裁切階段，拿來取代旋轉後固定等 3 秒的寫法。

## 協定（Engine.IO v4 + socket.io v5 封包）

- 網址：`server` 的 scheme 換成 `ws`/`wss`，路徑 `api/socket.io/`，query `EIO=4&transport=websocket`。header 帶 `x-api-key`。
- 每個 WebSocket 文字訊息就是一個封包，不會合併：
  - `0{...}`：open（內含 `pingInterval`）。收到後送 `40`（連線到預設 namespace）。
  - `40{...}`：namespace 連上了。
  - `2`：伺服器 ping，**要馬上回 `3`**，否則約 45 秒後伺服器會斷線。
  - `42["event", arg]`：事件。去掉前兩個字元，剩下的是 JSON 陣列。
  - `41`（namespace 斷線）、`44{...}`（連線錯誤，例如 key 被拒）、`1`（close）：結束這次連線（拋錯，交給外層重連）。
  - 其餘忽略。

## 程式改動

### 1. 新檔 `ImmichViewer/Core/ServerEvents.swift`

不加套件，用 `URLSessionWebSocketTask`。

```swift
/// One socket.io packet, as Immich sends them over the WebSocket.
enum SocketPacket: Equatable {
    case open            // "0{...}"
    case connected       // "40..."
    case ping            // "2"
    case event(String, Data) // "42[...]": the name and the first argument as JSON (Data so it stays Equatable/Sendable)
    case closed          // "1", "41", "44..."
    case other

    init(_ text: String) { ... }  // pure, no I/O: Tests/main.swift checks it
}

/// What a live event means for the local lists.
enum ServerEvent: Sendable {
    case removed([String])            // trash, hidden
    case deleted([String])            // gone for good: also drop the thumbnail
    case changed(AssetChange)         // on_asset_update
    case added                        // upload, restore: reload the list
}
```

- `ServerEvent` 由 `SocketPacket.event` 轉換而來（`static func from(name:json:) -> ServerEvent?`，未知事件回 nil）。
- `extension ImmichAPI { func events() -> AsyncThrowingStream<ServerEvent, Error> }`：
  - 一次連線：建立 task、`resume()`，用迴圈 `receive()`。依上面的協定處理 open/ping/closed，事件就 `yield`。
  - stream 的 `onTermination` 時 `cancel` WebSocket task。
  - 連線結束（closed、錯誤、伺服器斷線）就 `finish(throwing:)`，重連交給呼叫端。
- `AssetChange`：從 `AssetResponseDto` 解出 `id`、`type`、`localDateTime`、`isFavorite`、`livePhotoVideoId`、`visibility`、`isTrashed`。
  - 計算屬性 `onTimeline`：`visibility == "timeline" && isTrashed != true`。
  - `asset: Asset?`：和搜尋結果同一套轉換。

**重用：** `ImmichAPI.searchPage` 裡的 `Item` 結構和 `Item → Asset` 的轉換，移到檔案層級，例如 `struct AssetItem: Decodable`，加上選填的 `visibility`、`isTrashed`，並提供 `var asset: Asset?`。`searchPage` 和 `AssetChange` 都改用它，不要寫兩份。`AssetChange` 可以直接就是 `AssetItem`。

### 2. `Library.swift`：監聽與合併

- 新增 `private var listenTask: Task<Void, Never>?`。
- `func listen()`：先 cancel 舊的，再開新的 task。
  - 迴圈：`for try await e in api.events() { receive(e) }`。結束或出錯後等 5 秒重連（`// ponytail: fixed 5 s retry`）。
  - **第二次以後連上**（中間可能漏了事件），排一次重新整理（走下面的 `settle(refresh: true)`）。用「這次 stream 收到的第一個事件之前」判斷不準，改成：`events()` 收到 `40` 時 yield 一個 `.connected`。所以 `ServerEvent` 要多一個 `case connected`，Library 收到第二次以後的 `.connected` 時就排重新整理。
  - `api` 換掉（切換伺服器）時，舊 task 已經被 cancel。
- `func stopListening()`：cancel 並設為 nil。
- 呼叫點：
  - `launch()` 的最前面呼叫 `listen()`。啟動時和切換伺服器時都會走到這裡。
  - `stopSync()` 裡也 cancel `listenTask`，`remove` 伺服器後 `api = nil` 的路徑因此也會停止。
- **合併事件，不要每個事件都刷新畫面**：`PUT /assets` 一次改 1000 張，就會來 1000 個 `on_asset_update`。
  - 暫存：`pendingRemoved: Set<String>`、`pendingChanged: [String: AssetChange]`、`pendingRefresh: Bool`，再加一個 `settleTask`。
  - `receive(_:)`：
    - `.removed(ids)`：加進 `pendingRemoved`。
    - `.deleted(ids)`：加進 `pendingRemoved`，並對每個 id 呼叫 `thumbs.forget(id)`。
    - `.changed(c)`：
      - 不在時間軸上（`!c.onTimeline`）就把 id 加進 `pendingRemoved`。
      - 在時間軸上、而且 `assets` 裡有：放進 `pendingChanged`。
      - 在時間軸上、但 `assets` 裡沒有（例如剛取消封存）：`pendingRefresh = true`。
    - `.added`：`pendingRefresh = true`。
    - 每種情況最後都呼叫 `scheduleSettle()`。
  - `scheduleSettle()`：如果 `settleTask` 已經在等就不重開（第一個事件後固定等 1 秒，把這段時間內的事件一起處理，不是每來一個事件就往後延）。
  - 等完後：
    1. 如果有 removed 或 changed：用現有的 `patch {}` 一次套用，只更新 `date`/`isFavorite`/`isLive`，而且只有和現在不同時才算改動。全部都沒變就不要呼叫 `patch`，因為回聲事件很常見。
    2. 如果 `pendingRefresh`：等到 `!syncing`（每 0.5 秒檢查一次），再 `await refresh()`。
    3. `edits += 1`，讓已開的人物、相簿、封存、垃圾桶、搜尋頁和資訊面板重新抓。前提是步驟 1 或 2 真的有做事，或者有任何 `.changed`（說明、評分等時間軸看不到的欄位可能變了）。
    4. 清空暫存。
- `edits` 目前是 `private(set)`，在 Library 內部改沒問題。

### 3. iOS：進背景就斷線

在 `PhoneApp.swift` 的根 view 加上 `@Environment(\.scenePhase)` 和 `.onChange(of: scenePhase)`：

- 變成 `.background`：`library.stopListening()`。
- 從 `.background` 回到 `.active`：`library.listen()`，並 `Task { await library.refresh() }`。
- 只在「從 background 回來」時這麼做。App 剛啟動時的 inactive → active 不要觸發，因為 `launch()` 已經處理了。

Mac 不必處理，一直連著。

### 4. 縮圖快取清理

- `ThumbnailStore.prune(keeping ids: Set<String>) -> Int`：列出 `dir` 裡的檔案，刪掉檔名不在 `ids` 裡的，回傳刪了幾個。memory cache 不用管。
- Library 加 `private func pruneCaches() async`，丟到背景執行（`Task.detached`，這個專案是 Swift 5 模式），不要在 main actor 上列舉大量檔案。保留的 id：
  - 時間軸 `assets` 的 id
  - `pages/*.json` 裡每個 `[Asset]` 的 id，也就是人物、相簿、標籤、封存、垃圾桶上次的清單（`pageFile` 的資料夾；讀不了的檔案就跳過）
  - `albums` 的 `albumThumbnailAssetId`（相簿封面可能不在時間軸上）
- 呼叫點：`sync()` 成功、`saveList()` 之後，Mac 上 `downloadMissing` 之前，而且 `!Task.isCancelled`。
- 人臉：在 `loadCollections()` 成功的路徑上，用 `faces.prune(keeping: Set(newPeople.map(\.id)))`。隱藏的人物不在清單裡，資訊面板顯示時會重新下載，可以接受。
- 一定要在同一個伺服器的 store 上執行：拿進入時的 `thumbs`/`faces` 參考，不要在 await 之後重讀 `self.thumbs`。

### 5. `Tests/main.swift`

加兩段檢查，並把 `ImmichViewer/Core/ServerEvents.swift` 加進檔頭註解和 README 的 `swiftc` 指令：

- `SocketPacket`：
  - `"0{\"sid\":\"x\",\"pingInterval\":25000}"` → `.open`
  - `"40{\"sid\":\"y\"}"` → `.connected`
  - `"2"` → `.ping`
  - `"42[\"on_asset_trash\",[\"a\",\"b\"]]"` → `.event("on_asset_trash", …)`，再轉成 `ServerEvent.removed(["a","b"])`
  - `"42[\"on_asset_delete\",\"a\"]"` → `.deleted(["a"])`
  - `"44{\"message\":\"x\"}"` → `.closed`
  - `"41"` → `.closed`
  - `"42[\"on_server_version\",{}]"` → `ServerEvent` 轉不出來（nil）
- `on_asset_update` 的 JSON，`visibility: "archive"` → `onTimeline == false`；`visibility: "timeline"`、`isTrashed: false` → `true`，而且 `asset` 的 id 和日期正確。
- `ThumbnailStore.prune`：在暫存資料夾建一個 store，寫入 `a`、`b`、`c` 三個檔案，`prune(keeping: ["a"])` 回傳 2，最後只剩 `a`。

### 6. README

- 「Not in this version」刪掉 "noticing deletions made in the browser until the next refresh" 和 "Thumbnails of deleted photos stay in the cache."，其餘句子保持通順。
- 在「What it does」的 Refresh 那一條後面加一條：在網頁或其他裝置上刪除、移到垃圾桶、封存、加喜好、上傳時，App 會即時跟著更新（透過伺服器的即時事件），不必按 ⌘R。iOS 回到前景時會補一次重新整理。
- Storage 相關的說明裡補一句：每次同步都會清掉已經不在伺服器上的縮圖。
- Development 的檔案表格：在 Core 下加 `ServerEvents.swift | Live changes from the server (socket.io over a WebSocket)`。

## 不做

- `on_album_update`、`on_person_thumbnail`、堆疊事件：之後的階段需要時再接。
- 重連的指數退避：固定 5 秒，標 `ponytail:`。

## 驗證（交給另一個 Sonnet 子代理）

1. `swiftc ImmichViewer/Core/TimelineModel.swift ImmichViewer/Core/ThumbnailStore.swift ImmichViewer/Core/ImmichAPI.swift ImmichViewer/Core/ServerEvents.swift Tests/main.swift -o /tmp/immichviewer-check && /tmp/immichviewer-check`
2. 兩個平台都要建置成功，而且沒有新增警告：
   - `xcodebuild -project ImmichViewer.xcodeproj -scheme ImmichViewer -destination 'platform=macOS' -derivedDataPath build build`
   - `xcodebuild -project ImmichViewer.xcodeproj -scheme ImmichViewer -destination 'generic/platform=iOS Simulator' -derivedDataPath build build`
3. 不帶 key 的協定檢查（只用本機伺服器）：用小腳本（Python `websockets`，或 `swift` 腳本直接用 `ServerEvents.swift` 的連線碼）連 `ws://localhost:2283/api/socket.io/?EIO=4&transport=websocket`。確認先收到 `0{...}`，送 `40` 之後被斷線或收到 `44`/`41`，證明 path、EIO 正確，而且沒有 key 會被拒。**不要讀 keychain 裡的 API key。**
4. 對照本文件逐項檢查 diff：
   - 合併邏輯：1 秒窗口、只有真的改變才 `patch`
   - iOS 的 scenePhase 只在從 background 回來時觸發
   - `prune` 的保留清單
   - 切換伺服器時舊的 listener 和舊 store 不會被誤用
