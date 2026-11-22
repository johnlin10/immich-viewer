# 階段 3：搜尋篩選（人物、地點、日期）

對應 README「Not in this version」裡的 "Search filters (people, places, dates)"。這個階段不調 `MARKETING_VERSION`，也不寫 Version history。

## 已確認的伺服器行為（Immich v3.4.0）

- `POST /search/metadata` 和 `POST /search/smart` 的舊格式欄位都還接受下面這些，App 現在就用這種格式：
  - `personIds: [uuid]`：**同時**有這些人才算符合（`hasPeople`）。
  - `city`、`state`、`country`：字串。
  - `takenAfter`、`takenBefore`：ISO 8601 日期時間。
- `GET /search/suggestions?type=country`：取得國家清單。
- `GET /search/suggestions?type=state&country=X`：取得某國的州／省。
- `GET /search/suggestions?type=city&country=X[&state=Y]`：取得城市。
- 這三個 suggestions 都回傳 `[String]`。不帶 `includeNull`，所以沒有 null 項目。

## 使用者看到的樣子（Mac 和 iOS 共用）

- 搜尋頁的工具列多一個按鈕「Search Filters」，圖示是 `slider.horizontal.3`：
  - 有篩選時圖示改用 tint 色，並加上 `.symbolVariant(.fill)` 或等效的寫法。
  - 這個按鈕和現有 ⋯ 選單裡的「Filter」（照片、影片、原況照片、喜好）是兩回事：前者決定向伺服器搜什麼，後者只過濾目前的結果。
- 點按鈕會開 popover。Mac 是 popover，iPhone 會自動變成 sheet，這是 SwiftUI 預設行為。內容是一個表單：
  - **People**：
    - 已選的人排成一列，每人一個小頭像加名字，旁邊的 ✕ 可以移除。
    - 下面一個「Add Person」Menu，列出還沒選的、**有名字**的人，依名字排序（用 `localizedStandardCompare`）。
    - 說明文字："Photos with all of them."
  - **Place**：
    - 三個 Picker：Country、State（地區）、City。每個都有 "Any" 選項。
    - 選項來自 suggestions。換國家時清掉 State 和 City；換 State 時清掉 City。
    - State 要先選國家才能用；City 只要有國家就能用。
  - **Date**：
    - 「From」開關，打開後出現 DatePicker（`.date`）。
    - 「To」開關，打開後同樣出現 DatePicker。
  - 最下面一個「Clear Filters」，沒有篩選時 disabled。
  - 改動**立刻生效**，不需要按「套用」。
- **只用篩選、不打字**也可以搜，例如「某人＋2023 年」或「台北」。這時用 metadata search，結果新的在前。
- **有打字時**：照現在的方式搜（文字搜尋三個欄位加上 smart search），每個請求都帶上同樣的篩選。
- 沒打字也沒篩選時，維持現在的空白頁「Search Your Library」。
- **iOS**：篩選狀態放在 `SearchResults` 裡。iPhone 的 Search tab 和 iPad 的 Search 頁共用同一份程式碼，也就是 `SearchResults`。
- **Mac**：`SearchPage` 用的也是 `SearchResults`，所以同一份程式碼兩邊都能用。

## 程式改動

### `Core/ImmichAPI.swift`

1. 新增 `struct SearchFilter: Hashable, Sendable`：

   ```swift
   /// What a search is narrowed to, besides its text: people (all of them in the photo), a place, a date range.
   struct SearchFilter: Hashable, Sendable {
       var people: [String] = []   // ids, in the order chosen
       var country: String?
       var state: String?
       var city: String?
       var from: Date?             // a day, as picked
       var to: Date?               // a day, as picked: through its end
       var isActive: Bool { ... }
       /// The request fields, for /search/metadata and /search/smart.
       func fields(calendar: Calendar = .current) -> [String: Any] { ... }
   }
   ```

   `fields()` 的規則：
   - `people` 不是空的才放 `personIds`。
   - 國家、州、城市有值才放。
   - `takenAfter` 是 `from` 那天在 `calendar` 時區的 0 點。
   - `takenBefore` 是 `to` **隔天**的 0 點（不含）。
   - 時間都用 `ISO8601DateFormatter`，`timeZone = calendar.timeZone`。
   - 使用者分別選開始和結束日，但結束日比開始日早時，把兩個對調再送出，不要報錯。

2. `search(_ query: String, filter: SearchFilter = .init())`：
   - `query` 是空的而 `filter.isActive`：只跑 metadata search（只帶 `filter.fields()`），分頁方式和現在 `textSearch` 每個欄位的迴圈一樣（最多 10 頁，每頁 1000）。結果新的在前。
   - `query` 不是空的：照現在的流程。`textSearch` 和 `smartSearch` 的 body 都併入 `filter.fields()`。
   - **重用**：把「分頁抓完一個 metadata body」抽成一個 private helper（例如 `metadataPages(_ body: [String: Any]) async throws -> [Asset]`）。`textSearch` 三個欄位和只用篩選的搜尋都用它，不要寫兩份分頁迴圈。保留原本的 `// ponytail: 10,000 …` 註解。

3. `func places(_ type: String, country: String? = nil, state: String? = nil) async throws -> [String]`：
   - 打 `GET search/suggestions`，回傳排序過的字串陣列（`localizedStandardCompare`），並去掉空字串。

### `Shared/Search.swift`

- `SearchResults` 加上：
  - `@State private var filter = SearchFilter()`
  - `@State private var filtersShown = false`
- task id 改成同時包含 query、filter 和 `library.edits`。`SearchFilter` 是 Hashable，可以用 `[AnyHashable]`，或寫一個小的 Hashable struct。
- `search()`：
  - 守衛條件改成 `!query.isEmpty || filter.isActive`。
  - 兩者都沒有時，維持現在清空結果的行為。
  - 呼叫 `api.search(query, filter: filter)`。
- overlay 的條件：
  - 「Search Your Library」只在 `query.isEmpty && !filter.isActive` 時顯示。
  - `ContentUnavailableView.search(text: query)` 只在 `query` 不是空的時候用。
  - 只用篩選、結果是空的：顯示 `ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("Try other filters."))`。
- 工具列：
  - 加 `.toolbar { ToolbarItem(placement: .primaryAction) { Button { filtersShown = true } label: { Label("Search Filters", systemImage: "slider.horizontal.3") } … .popover(isPresented: $filtersShown) { SearchFilterForm(filter: $filter) } } }`。
  - 先確認 iOS 的 `TimelineBrowser`（`iOS/PhoneTimeline.swift`）已經有 Select 和 ⋯ 兩個 `.primaryAction`。新按鈕要出現在 ⋯ 的左邊，必要時用 `ToolbarSpacer` 或調整 placement，讓它看起來和其他頁一致。
  - Mac 的工具列另外已有 `.searchable` 欄位，按鈕放在 ⋯ 旁邊即可。
- 新增 `struct SearchFilterForm: View`（同一個檔案）：
  - `Form` 搭配 `.formStyle(.grouped)`。Mac 的 popover 設 `.frame(width: 340)`，最小高度要夠，讓三個區塊都看得到。iOS 不設寬度。
  - 頭像用現有的 `Thumb(id: person.id, store: library.faces)` 加上 `.clipShape(Circle())`，可以參考 `InfoPanel.swift` 或 `CollectionsPage.swift` 的寫法。
  - 地點選項：
    - `.task(id: filter.country)` 載入州，`.task(id: [filter.country, filter.state])` 載入城市，國家清單在出現時載入一次。
    - 載入失敗時，該 Picker 只剩 "Any"，不要跳 alert。
  - 日期：
    - 用 `Binding` 把 `filter.from` 包成「Toggle 開關加日期」，打開時預設今天，To 同理。
    - 每個 DatePicker 的範圍不限。
  - 在 `SearchFilterForm` 頂端加一行 `// ponytail:`：人物用 Menu 列出所有有名字的人，人很多時很長；需要時再改成可搜尋的清單。

### 字串與翻譯

這階段會新增介面字串，例如 "Search Filters"、"People"（可能已經有）、"Add Person"、"Photos with all of them."、"Place"、"Country"、"State"、"City"、"Any"、"Date"、"From"、"To"、"Clear Filters"（可能已經有）、"No Results"、"Try other filters."。

做法：
1. 兩個平台都建置（`-derivedDataPath build`）。
2. `xcrun xcstringstool sync ImmichViewer/Resources/Localizable.xcstrings --stringsdata …`，只帶 arm64 的 `.stringsdata`，兩個平台的都要，用 `find build -path '*arm64*' -name '*.stringsdata'` 找。
3. 刪掉 stale 的項目，前提是程式碼裡真的不再用到它。
4. 替新的 key 補上 zh-Hant（台灣用語）和 zh-Hans（大陸用語），沿用 `docs/localization.md` 的詞彙表，並和既有翻譯一致：
   - State 用「州／省」，zh-Hant 寫「州／省」，zh-Hans 寫「州／省」。
   - From／To 用「開始」／「結束」，zh-Hans 寫「开始」／「结束」，或依介面語境挑更自然的說法。
5. 保持 xcstrings 現有的格式（2 空格縮排、`" : "` 分隔、key 的順序），讓 diff 盡量小。

### `Tests/main.swift`

加一段 `SearchFilter.fields` 的檢查，用固定的 `Calendar`（gregorian，`timeZone = TimeZone(identifier: "Asia/Taipei")!`）：
- 空的篩選 → `isActive == false`，`fields()` 是空的。
- `people ["a","b"]`、`country "Taiwan"` → `personIds == ["a","b"]`、`country == "Taiwan"`，而且沒有 `state`。
- `from 2023-01-01`、`to 2023-12-31` → `takenAfter == "2022-12-31T16:00:00Z"`、`takenBefore == "2023-12-31T16:00:00Z"`。也就是台北時間 2023-01-01 0 點，以及 2024-01-01 0 點。如果 formatter 輸出 `+08:00` 的寫法，就依輸出調整比對，但時間點必須相同。
- `from` 比 `to` 晚 → 兩者對調。

### README（英文）

- Mac 的 Search 那一條（Editing 段落裡的 "Search, at the top of the sidebar: …"）後面加：Search Filters（工具列的按鈕）可以把結果限定在某些人（要同時出現）、一個地點（國家、州或省、城市，選項來自伺服器）和一段日期，而且不打字也能只用篩選搜尋。
- iPhone and iPad 的 Search 那一條加一句：同樣的 Search Filters 在工具列上。
- 「Not in this version」刪掉 "Search filters (people, places, dates)"，句子保持通順。

## 不做

- 相機、鏡頭、評分、檔案類型等其他篩選：要的時候再加。
- 記住上次的篩選：每次打開搜尋頁都從空的開始，和其他頁的篩選一樣。

## 驗證（另一個 Sonnet 子代理）

1. `swiftc ImmichViewer/Core/TimelineModel.swift ImmichViewer/Core/ThumbnailStore.swift ImmichViewer/Core/ImmichAPI.swift ImmichViewer/Core/ServerEvents.swift Tests/main.swift -o /tmp/immichviewer-check && /tmp/immichviewer-check`
2. 兩個平台都要建置成功（`-derivedDataPath build`），改到的檔案不能有新的警告。最後的 macOS Debug 版必須在 `build/Build/Products/Debug/ImmichViewer.app`。
3. 字串目錄：每個非空的 key 都有三種語言，格式符號一致，沒有 stale 的項目，zh-Hans 沒有繁體字或台灣用語，舊的翻譯沒有被改動。
4. 不帶 API key 的伺服器檢查：
   - `curl -s -X POST localhost:2283/api/search/metadata -H 'content-type: application/json' -d '{"personIds":[],"takenAfter":"2023-01-01T00:00:00+08:00"}'` 應該回 401（不是 400），表示 body 的格式被接受，只是沒有驗證身分。
   - 再送一個欄位型別錯誤的 body，確認會回 400，以此對照。
   - 不要讀 keychain 裡的 key。
5. 對照本文件逐項檢查 diff：
   - 守衛和空狀態的條件。
   - task id 包含 filter。
   - 分頁 helper 只有一份。
   - 換國家時有清掉州和城市。
   - 日期換算、日期對調。
   - popover 在 iOS 和 Mac 上都會出現（讀程式碼即可）。
   - 工具列按鈕的位置。
