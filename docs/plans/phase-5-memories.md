# 階段 5：回憶（Memories）

對應 README「Not in this version」裡的 memories。地圖（階段 4）先跳過。這個階段不調 `MARKETING_VERSION`，也不寫 Version history。

使用者已決定兩件事：
- **位置**：收藏項目最上方一列回憶卡片，標題點開是全部回憶。Mac 側邊欄（iPad 側邊欄也一樣）在 Collections 下面加一項「Memories」。
- **開啟方式**：全螢幕自動播放，像 Immich 網頁版和限時動態。也可以切到網格看全部照片。

## 伺服器 API（Immich v3.x，`server/src/dtos/memory.dto.ts`）

- `GET /memories`：權限 `memory.read`。
  - 查詢參數：`for`（ISO 日期，只回傳那天要顯示的回憶）、`isSaved`、`isTrashed`、`type`、`size`、`page`、`order`。
- 回傳 `[MemoryResponseDto]`，每筆有：
  - `id`、`memoryAt`（ISO）
  - `showAt?`、`hideAt?`、`seenAt?`
  - `type`（`on_this_day`，新版還有生日）
  - `data`：`{ year, personId?, personName? }`
  - `isSaved`
  - `assets: [AssetResponseDto]`，跟搜尋結果的 item 同一種格式。
- 這階段**只讀**。不做收藏回憶（`isSaved`）、不標示已看（`seenAt`）、不刪除，免得 key 沒 `memory.update` 時跳錯。
- 實作前，先在假伺服器上確認解碼正常。真的伺服器這階段無法連，不要連使用者的伺服器。

## 資料

### `Core/ImmichAPI.swift`

```swift
/// One of Immich's memories: photos from this day in an earlier year (or a person's birthday).
struct Memory: Identifiable, Hashable, Sendable {
    let id: String
    let year: Int
    let personName: String?
    let date: Date        // memoryAt
    let assets: [Asset]   // in the server's order (oldest first)
}
```

- `func memories(for day: Date? = nil) async throws -> [Memory]`：
  - `day` 為 nil 時拿全部回憶。不是 nil 時帶 `for=yyyy-MM-dd`，用當地日曆。
  - 用現有的 `AssetDTO.asset(using:)` 轉成 `Asset`，丟掉轉不出來的，也丟掉 `assets` 是空的回憶。
  - 全部回憶要去掉還沒到 `showAt` 的，依 `date` 新的在前。
- **標題**：
  - 有 `personName` 時用 `"\(name)’s Birthday"`。
  - 否則用 `"\(n) years ago"`，其中 n = 今年減 `year`，在字串目錄裡用複數形式。
  - n 小於 1 時顯示年份本身。
- **副標題**：`date` 的日期，格式為 `.dateTime.month().day().year()`。

### `Core/Library.swift`

- `private(set) var memories: [Memory] = []` 存今天的回憶，跟 `loadCollections()` 一起載入。
  - 失敗時（例如 key 沒 `memory.read`）設成 `[]`，記到 `memoriesError`，**不跳 alert**。
- 不存到磁碟，換伺服器時清掉。
- 這是 YAGNI：回憶一天才變一次，啟動時抓一次就夠。

## 介面

### 收藏項目（`Shared/CollectionsPage.swift`）

- People 上面加一個 `section("Memories", …, page: .memories)`，`CollectionList` 加 `.memories`。
- **卡片**：
  - 第一張照片當封面：`Thumb(id:, store: library.thumbs)`。寬 `cover * 1.4`、高 `cover`，圓角 14。
  - 封面下半部疊一層由黑到透明的漸層，左下角是白字標題（`.headline`）和副標題（`.caption`）。
- 今天沒有回憶時，照其他 section 顯示「None」。key 沒權限（有 `memoriesError`）時，整個 section 不顯示。
- 卡片點擊時：
  - iOS：開全螢幕播放（`fullScreenCover`）。
  - Mac：`NavigationLink(value: memory)` 推進播放頁。

### 全部回憶頁 `MemoryGrid`

- 放在新檔 `Shared/Memories.swift`，跟卡片用同一個 view。
- 進頁時呼叫 `api.memories()`，用 `LazyVGrid(.adaptive(minimum: 220))` 排卡片。
- 載入中顯示 `ProgressView`，失敗顯示 `ContentUnavailableView`，說明 key 需要 `memory.read`。

### 播放器 `MemoryPlayer`（`Shared/Memories.swift`）

- **畫面**：黑底，照片 `scaledToFit`。
  - 先顯示 `library.thumbs` 的小圖，再換成 `thumbnail(id, size: "preview")`。
  - 下一張先預載。
- **進度條**：上方一排細進度條，一張一段，像限時動態。已看過的填滿，目前的跟著時間走。
  - 下面是標題和副標題（白字）。
- **時間**：
  - 照片每張 5 秒。
  - 影片用 `library` 現有的播放器（`Library.swift` 約 464 行附近建 `AVPlayer` 的函式），依設定「Start Muted」決定靜音。
  - 影片播完才換下一張，進度條跟著影片時間走。
  - 最後一張播完停在最後一張，暫停狀態。
- **控制**：
  - 暫停／播放：iOS 點畫面中間，Mac 按空白鍵或工具列按鈕。
  - 上一張／下一張：iOS 點左右三分之一，Mac 用 ← →。
  - 關閉：iOS 是左上 ✕ 或往下滑，Mac 是 Esc 或返回。
- **「Show All Photos」**：iOS 在右上，圖示 `square.grid.2x2`；Mac 在工具列。打開後是一般照片網格頁：
  - 用 `TimelineBrowser(title:subtitle:assets:revision:context:)`，跟 `SearchResults` 的用法一樣（`context: .search`），保持伺服器給的順序，可以開單張、選取、編輯。
  - 如果 `.search` 這個 context 的行為不合適（例如標題或選單不對），可以加 `BrowserContext.memory`，但先試現成的。
- **兩個平台**：
  - iOS 用 `fullScreenCover` 呈現播放器，網格在 cover 裡用自己的 `NavigationStack` 推入。
  - Mac 是推入 detail 的 NavigationStack，播放頁填滿 detail，背景是黑色。
- 開啟後不鎖螢幕：iOS 播放中設 `UIApplication.shared.isIdleTimerDisabled = true`，離開時還原。
- Reduce Motion 開啟時不用淡入淡出，直接切換。平時換張用 0.3 秒淡入淡出。

### 側邊欄

- **Mac**（`Mac/ImmichViewerApp.swift`）：
  - `Page` 加 `.memories`。
  - Collections 下面一行 `Label("Memories", systemImage: "memories")`；如果 SF Symbol 沒有這個名字，改用 `clock.arrow.circlepath`。
  - root 對應到 `MemoryGrid()`。
- **iPad**（`iOS/PhoneApp.swift`）：側邊欄 Collections 下面同樣加一項，開 `MemoryGrid()`。
- **導覽**：`collectionDestinations()` 加：
  - `navigationDestination(for: Memory.self)`：Mac 推播放頁，iOS 不用（iOS 用 fullScreenCover）。
  - `.memories`：對應到 `MemoryGrid()`。

## 文字（`Resources/Localizable.xcstrings`，手改，en / zh-Hant / zh-Hans）

| en | zh-Hant | zh-Hans |
|---|---|---|
| Memories | 回憶 | 回忆 |
| %lld years ago（複數 one/other） | %lld 年前 | %lld 年前 |
| %@’s Birthday | %@ 的生日 | %@ 的生日 |
| Show All Photos | 顯示所有照片 | 显示所有照片 |
| Pause / Play | 暫停 / 播放 | 暂停 / 播放 |
| No Memories | 沒有回憶 | 没有回忆 |
| The key needs the memory.read permission. | 這個 API 金鑰需要 memory.read 權限。 | 这个 API 密钥需要 memory.read 权限。 |

建置後 Xcode 自動加進來的字串，也要補上翻譯。

## README

- **What it does**：加一條 Memories：收藏項目最上方一列今天的回憶，點開全螢幕自動播放（進度條、暫停、上一張下一張、Show All Photos），標題點開是全部回憶。Mac 和 iPad 側邊欄都有。
- **iPhone and iPad**：補一句操作方式（點左右切換、點中間暫停、往下滑關閉）。
- **Setup**：瀏覽權限加 `memory.read`。
- **Not in this version**：改成只剩 Map，Planned editing 拿掉 memories。
- **Sources 表**：加 `Memories.swift`。

## 假伺服器（scratchpad `fake_immich.py`）

- 加 `GET memories`：
  - 帶 `for` 時回傳兩則今天的回憶：1 年前 3 張，含一支影片；3 年前 2 張。
  - 不帶時再多兩則較舊的。
  - `assets` 用假伺服器已有的 asset，跟 search 回傳的格式一樣。
- 加一個開關，例如環境變數或特定 key，讓它回 403，用來測沒權限的情況。

## 驗收

1. Mac 和 iOS 都建置成功，沒有新的警告。
2. **iPhone 17 Pro / iPad Pro 11 吋 (M5)** 模擬器，連假伺服器：
   - 收藏項目最上方有兩張回憶卡片。
   - 點開後自動播放，進度條會走，影片會播完才換張。
   - 點左右可以切換，點中間會暫停，往下滑會關閉。
   - Show All Photos 會開網格。
   - 標題點開全部回憶頁，有四則。
   - iPad 側邊欄有 Memories。
3. **Mac**：用隔離測試版（`local.ImmichViewerTest`，預先寫好 `servers` defaults，連假伺服器）驗證：
   - 側邊欄有 Memories，收藏項目有卡片。
   - 播放頁 ← → 可以切換，空白鍵暫停，Esc 返回。
   - Show All Photos 正常。
4. 403 的情況：收藏項目不出現回憶那一列，全部回憶頁顯示權限說明，不跳 alert。
5. 中文介面（zh-Hant）的文字都翻好了。

## 實作後的修正

- 「Show All Photos」原本用 `navigationDestination(isPresented:)` 綁在播放器的狀態上。在 Mac 上一按，SwiftUI 就無限重算版面（CPU 100%，App 卡死）。
  - 改成推入一個值 `MemoryPhotos`，目的地註冊在 `collectionDestinations()`。iOS 的 fullScreenCover 裡的 NavigationStack 也掛上這些目的地。
- Mac 推入網格時，下面的播放器不會收到 `onDisappear`，結果照片在背後繼續播。
  - 改成 `MemoryPhotos` 帶一個 `Covered`（`@Observable`，以物件身分比較），網格出現時設為 true，播放器就暫停。返回後顯示 ▶，點一下繼續。
- 暫停時畫面中間顯示 ▶。標題和進度條後面加上由黑到透明的漸層，亮的照片上也看得清楚。
- Mac 的標題和日期放在視窗標題列（`navigationTitle` / `navigationSubtitle`），畫面上只留進度條，不重複顯示。
