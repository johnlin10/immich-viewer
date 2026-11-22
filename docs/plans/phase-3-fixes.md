# 階段 3 修正：iPhone 和 iPad 上的搜尋篩選

使用者在真機上回報了三個問題：

1. **iPhone**：點搜尋按鈕進入搜尋後，鍵盤自動彈出，上方的操作按鈕（Search Filters、Select、⋯）被推出畫面按不到，往下滑也收不起鍵盤。
2. **人物選擇**：Menu 不適合人很多的情況，而且清單裡沒有頭像，只有選好之後才看得到。
3. **iPad**：按下 Search Filters 後，popover 好像要彈出來，最後卻懸在半空中變成一個圓形，裡面什麼選項都沒有。

## 修正

### 1. iPhone：搜尋時保留導覽列，可以收起鍵盤

- `iOS/PhoneApp.swift` 的 `searchTab`：在 `.searchable(...)` 後面加上 `.searchPresentationToolbarBehavior(.avoidHidingContent)`，讓搜尋欄啟用時導覽列（和上面的按鈕）不會被收起來。
- `iOS/PhoneGrid.swift`：在建立 UICollectionView 的地方設定 `keyboardDismissMode = .onDrag`，往下捲動結果時就會收起鍵盤。所有頁面都一樣，其他頁沒有鍵盤，所以沒有影響。
- 空狀態（還沒有結果時）沒有東西可以捲動。只要按鈕還看得到，這點就可以接受；鍵盤本身的「搜尋」鍵也會收起鍵盤。

### 2. 人物：可搜尋、看得到頭像的清單，兩個平台用同一份程式碼

`Shared/Search.swift` 的 `SearchFilterForm` 改寫 People 區塊，拿掉 Menu：

- 已選的人維持現在的樣子：頭像、名字，旁邊有 ✕。
- 接著放一個 `TextField("Search People", text: $personQuery)`。
- 下面列出可以加的人，每一列都有頭像（`Thumb(id:store: library.faces)` 搭配 `.clipShape(Circle())`，36 pt，和 `Editing.swift` 的 `PersonPicker` 在 iOS 上的樣式一樣）、名字和一個加號圖示。點一下就加入，並清空搜尋欄。
  - 候選人：**有名字**而且還沒被選的人，**保留 `library.people` 原本的順序**，也就是 Immich 的順序：最愛、有名字的、照片最多的排前面。這樣不打字時也會先看到最常出現的人。
  - 搜尋欄是空的：只顯示前 6 位。
  - 有輸入文字：顯示名字包含該文字的人（`localizedCaseInsensitiveContains`），最多 30 位。
  - 一個都沒有：顯示一行灰字 "No Matches"（目錄裡應該已經有這個字串）。
- footer 維持 "Photos with all of them."。
- 把 `// ponytail:` 註解改成：只列出前 6 位和最多 30 個符合的結果，名字搜尋就夠用。
- `addable` 不要再用名字排序。

### 3. iPad 和 iPhone：改用 sheet，不用 popover

- `SearchResults` 的工具列按鈕：
  - **iOS**：用 `.sheet(isPresented: $filtersShown)`，內容是 `NavigationStack { SearchFilterForm(filter: $filter).navigationTitle("Search Filters").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { filtersShown = false } } } }`，再加上 `.presentationDetents([.medium, .large])`。
    - iPad 的 popover 裡放 Form 沒有內在尺寸，在 iPadOS 26 的玻璃按鈕變形動畫裡會塌成一個圓。改成 sheet 就沒有這個問題，App 其他的表單也都是 sheet。
    - 字串 "Done" 目錄裡已經有了。
  - **Mac**：維持 popover。Mac 上沒有問題，`.frame(width: 340, height: 480)` 照舊。
  - 用 `#if os(iOS)` / `#else` 分開寫，不要另外抽象。
- `SearchFilterForm` 本身不知道自己是在 sheet 還是 popover 裡。

### 字串

- 新增 "Search People"。
- "No Matches" 如果還沒有就新增。
- 兩個平台都要建置（`-derivedDataPath build`），同步目錄後補上 zh-Hant 和 zh-Hans：
  - Search People：搜尋人物 / 搜索人物
- 作法同階段 3，保留檔案格式，只加新的 key。
- 程式碼已經不用的 key，例如 "Add Person"，就刪掉。

### README

- 如果 README 有寫 Search Filters 的形式（popover、Menu），就照實修改：Mac 上是浮動面板，iPhone 和 iPad 上是 sheet，人物可以用名字搜尋，並顯示頭像。

## 驗證

這次**一定要在模擬器上實際看過**，由主 session 負責，因為需要連上伺服器。子代理只要負責：

- swiftc 檢查
- 兩個平台都建置成功（最後建 macOS，讓 `build/Build/Products/Debug/ImmichViewer.app` 是最新的）
- 字串目錄檢查
- 對照本文件審 diff

## 追加：篩選中的按鈕要看得出來

模擬器上發現，iOS/macOS 26 起的玻璃工具列會蓋掉 `.symbolVariant(.fill)` 和 `.foregroundStyle(.tint)`，有沒有篩選看起來一樣。改成有篩選時套用 `.buttonStyle(.glassProminent)`（著色的玻璃按鈕），沒篩選時用預設樣式。兩種 style 型別不同，所以在 `ToolbarItem` 裡用 if/else 切換。
