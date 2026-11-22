# 階段 2：拖放上傳、簡體中文

README 裡對應的兩項：

- Planned editing: "dropping files on the window to upload"
- Not in this version: "a Simplified Chinese interface"

這個階段不調 `MARKETING_VERSION`，也不寫 Version history。

分兩步做，**依序**進行，因為兩步都會動到字串目錄：

- **2A 拖放上傳**：只寫英文字串，不動 `Localizable.xcstrings`。
- **2B 簡體中文**：先從建置結果同步字串目錄（2A 的新字串會自動進來），再補上缺的 zh-Hant 和全部的 zh-Hans。

## 2A：拖放上傳

### 規則（Mac 和 iOS 一樣）

- **哪些頁面可以拖放**：只有圖庫和相簿頁，和 iOS「Upload from Photos…」出現的頁面一樣（`context == .library || album != nil`）。在相簿頁放下的檔案，上傳後也會加進那本相簿。封存、垃圾桶、人物、標籤、搜尋頁不接受拖放，免得檔案上傳到一個看不到它們的地方。
- **什麼時候不接受**：
  - 已有上傳或下載正在進行（`library.transfer != nil`）：進度面板一次只能顯示一個。
  - 單張檢視開著（Mac：`viewer != nil`）。
  - iOS 正在 Select 模式中。
  - 這些情況下 handler 回傳 `false`，也不顯示提示框。
- **上傳流程**：走現有的 `library.upload(count:album:item:)`，和 File > Import… 完全相同，也就是同一個進度面板、可以取消、伺服器已經有的檔案不會重傳、沒有日期的檔案會補上日期。
- **拖到頁面上方時**：疊一層提示，邊緣一圈 accent 色圓角框，加上中間一顆玻璃膠囊顯示文字。這個提示是共用 view，放在 `Shared/Editing.swift` 的 `TransferPanel` 旁邊，叫 `DropHighlight(album: String?)`：
  - 有相簿時顯示 `"Drop to Add to “\(name)”"`
  - 沒有相簿時顯示 `"Drop to Upload"`
  - 相簿名稱用 `library.albums` 依 id 查。
  - 加上 `.allowsHitTesting(false)`。

### Mac（`Mac/ImmichViewerApp.swift`，就是有 `.focusedSceneValue(\.browser, …)` 的那個頁面 view）

- `@State private var dropTargeted = false`
- `.dropDestination(for: URL.self) { urls, _ in … } isTargeted: { dropTargeted = $0 }`
  - 只收 file URL，而且 `contentType` 要符合 `.image` 或 `.movie`（用 `resourceValues(forKeys: [.contentTypeKey])` 判斷）。資料夾和其他檔案略過。一個能用的都沒有就回傳 `false`。
  - 開始上傳：`Task { await library.upload(count: files.count, album: album?.id) { [UploadFile(url: files[$0])] } }`。這和 `ImportCommands` 裡的呼叫一樣。如果寫成小 helper 能讓兩處共用，就共用；不行也不要勉強抽象。
  - 不能拖放的情況（見上面的規則）回傳 `false`。
- `.overlay { if dropTargeted, canDrop { DropHighlight(album: album?.id) } }`
- **風險**：格狀頁是 `NSCollectionView`（`Mac/PhotoGrid.swift`）。如果它自己註冊了拖曳型別，SwiftUI 的 `dropDestination` 可能收不到。先查 `PhotoGrid.swift` 有沒有呼叫 `registerForDraggedTypes` 或 `setDraggingSourceOperationMask`：
  - 只做拖出（dragging source）不會擋住拖入。
  - 如果真的被擋，就在 `NSCollectionView` 上實作 `collectionView(_:validateDrop:…)` / `acceptDrop`，轉給同一個 handler。
  - 驗證時要實際確認拖入可以運作（見最後的驗證段）。

### iOS 和 iPadOS（`iOS/PhoneTimeline.swift` 的頁面 view，就是有 `uploadShown` 的那個）

- 把 `iOS/PhotosUpload.swift` 的 `PickedFile` 從 `private` 改成 internal（同一個 `#if os(iOS)` 區塊內），重用它來接收拖進來的檔案。它的 `FileRepresentation(importedContentType: .item)` 會把檔案複製到暫存目錄。
- `.dropDestination(for: PickedFile.self) { files, _ in … } isTargeted: { dropTargeted = $0 }`
  - 上傳：`library.upload(count: files.count, album: album) { [UploadFile(url: files[$0].url, name: files[$0].name, temporary: true)] }`
  - 不能拖放的情況回傳 `false`，而且要刪掉已經複製出來的暫存檔。
- `.overlay { if dropTargeted, canDrop { DropHighlight(album: album) } }`
- iPhone 也能從別的 App 拖進來，同一份程式碼就能用，不必特別處理。
- 從「照片」App 拖進來的照片，拿到的是檔案本身，沒有照片圖庫的日期和喜好，和「沒有圖庫權限時」的行為相同。需要完整資訊的人，可以改用 Upload from Photos…。
- 在 `PickedFile` 旁邊加一行 `// ponytail:`：拖進來的檔案會在上傳前全部複製一份，數量很多的大影片會先佔用暫存空間。

### README（英文，照現有寫法）

- Mac 的 File > Import… 那一條加上：也可以把 Finder 裡的檔案拖到圖庫或相簿頁上，在相簿頁上放下的會加進那本相簿。
- iPhone and iPad 的 Upload from Photos 那一條後面加一句：從其他 App（例如「檔案」或「照片」）把照片或檔案拖到圖庫或相簿頁上也會上傳，但只帶檔案本身的日期。
- Planned editing 刪掉 "dropping files on the window to upload"，句子保持通順。

## 2B：簡體中文（zh-Hans）

照 `docs/localization.md` 做，它的「Glossary」和「Not translated」是規範。

### 步驟

1. **先同步字串目錄**（2A 加了新字串，而且命令列建置不會更新目錄）：
   - 建置 macOS 和 iOS Simulator 兩個平台（`-derivedDataPath build/dd`）。
   - 執行 `xcrun xcstringstool sync ImmichViewer/Resources/Localizable.xcstrings --stringsdata <每個 .stringsdata>`。兩個平台的 `.stringsdata` 都要帶上，因為有些字串只在其中一個平台出現。用 `find build/dd -name '*.stringsdata'` 找出來。
   - 同步後，`extractionState == "stale"` 的字串（程式碼已經不用的）直接刪掉。
2. **補 zh-Hant**：凡是有 `en` 但沒有 `zh-Hant` 的字串（2A 的新字串），補上台灣用語的翻譯，風格和既有翻譯一致。空字串 key `""` 不用管。
3. **加 zh-Hans**：每一條有 zh-Hant 的字串都加一個 `"zh-Hans": {"stringUnit": {"state": "translated", "value": …}}`。
   - 結構照 zh-Hant 的寫法。目前沒有 plural variations；萬一遇到，結構也要比照 zh-Hant。
   - **用大陸用語重新翻譯，不是逐字繁轉簡。** 先套用詞彙表，再逐條檢查常見的台陸差異，例如：
     - 檔案/文件、設定/设置、影片/视频、網路/网络、伺服器/服务器、相簿/相册
     - 資訊/信息、預設/默认、螢幕/屏幕、滑鼠/鼠标、快取/缓存、縮圖/缩略图
     - 登入/登录、連線/连接、支援/支持、程式/程序、選取/选择、喜好項目/个人收藏
     - 封存/归档、垃圾桶/废纸篓、復原/恢复、拷貝/拷贝、輸入…/导入…、重新整理/刷新
     - 「項」在計數裡也要符合簡中習慣，例如「%lld 项」
     - 標點用簡中慣用的全形標點
   - 格式符號（`%@`、`%lld`、`%1$lld`、`%2$@`…）的種類、數量、位置編號都必須和 zh-Hant 一致。
   - 寫法建議：先輸出一個 key → zh-Hans 的對照 JSON 檔（放在 scratchpad），逐條檢查後，再用腳本合併進 xcstrings，並保留原檔的格式（Xcode 的 JSON 排版：2 空格縮排、`" : "` 分隔）。合併後跑一次 `xcrun xcstringstool` 驗證，或用建置確認檔案還能讀。
4. **`InfoPlist.xcstrings`**：5 條都加 zh-Hans。App 名稱維持 "Immich Viewer"；權限說明（區域網路、照片圖庫）用大陸用語。
5. **專案設定**：`ImmichViewer.xcodeproj/project.pbxproj` 的 `knownRegions` 加上 `"zh-Hans"`（放在 `"zh-Hant"` 後面）。
6. **文件**：
   - `docs/localization.md`：Status 改成 step 2 已完成；Steps 的第 2 步標成 done。
   - `README.md`：開頭的 Language 註記改成 English, Traditional Chinese and Simplified Chinese，並拿掉 "Simplified Chinese is planned; see …" 這句。可以保留一句指向 localization.md 的說明，給要加新語言的人。
   - 「Not in this version」刪掉 "a Simplified Chinese interface"，句子保持通順。

## 驗證（另一個 Sonnet 子代理）

1. `swiftc ImmichViewer/Core/TimelineModel.swift ImmichViewer/Core/ThumbnailStore.swift ImmichViewer/Core/ImmichAPI.swift ImmichViewer/Core/ServerEvents.swift Tests/main.swift -o /tmp/immichviewer-check && /tmp/immichviewer-check`
2. macOS 和 generic iOS Simulator 兩個平台都要建置成功，而且改到的檔案沒有新的警告。
3. 字串目錄的腳本檢查：
   - 每一條非空的 key 都有 en（或是 source key）、zh-Hant、zh-Hans 三種語言。
   - 每一條的 zh-Hans 和 zh-Hant 有相同的格式符號集合（用 regex 抽出 `%(\d+\$)?(lld|ld|d|@|f|\.\d+f)` 比對）。
   - 沒有 `stale` 的字串。
   - 抽查 zh-Hans 有沒有殘留繁體字或台灣用語：腳本掃常見繁體字（例如 這 個 為 與 設 檔 網 圖 張 項 刪 復 選 啟 處 讀 載 輸 錄）和台灣詞（檔案 設定 影片 網路 伺服器 相簿 資訊 預設 螢幕），列出命中的字串。
4. 用 `-AppleLanguages "(zh-Hans-CN)"` 啟動建好的 Mac App（Debug，`IMMICH_VIEWER_PROFILE=verify`），截圖確認選單列和側欄是簡體字。不要動用 keychain 裡的 key；沒有連線也沒關係，連線表單和選單本身就看得出語言。iOS Simulator 也可以用同樣的方式截圖。
5. 拖放：
   - 讀 code，確認上面每一條規則都有做到：頁面限制、`transfer` 期間不接受、viewer 開著時不接受、類型過濾、暫存檔清理。
   - 確認 `PhotoGrid.swift` 不會擋住拖入。如果能用 `osascript` 或 Swift 腳本模擬一次拖放就做；做不到就明確回報「無法自動驗證拖放，需要人工試一次」。
