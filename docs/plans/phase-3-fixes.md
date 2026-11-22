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
  - **iOS**：用 `.sheet(isPresented: $filtersShown)`，內容是 `NavigationStack { SearchFilterForm(filter: $filter).navigationTitle("Search Filters").navigationBarTitleDisplayMode(.inline).toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { filtersShown = false } } } }`，（原本加了 `.presentationDetents([.medium, .large])`，追加 2 把人物移到最後後拿掉了，sheet 直接全高打開，人物區塊才看得到）。
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

## 追加 2：人物要能看臉挑，不能只靠名字

使用者指出：忘了名字的時候要能從清單裡用臉找人；沒取名的人也看得出是誰，因為本來就是看臉認人。前面「只列 6 位、只列有名字的人」是錯的。App 裡 `Editing.swift` 的 `PersonPicker` 本來就是列出所有人（含 Unnamed），這裡要和它一致。

### `Shared/Search.swift` 的 `SearchFilterForm`

- 區塊順序改成 **Place → Date → People**。人物清單可能很長，放最後才不會把地點和日期擠到看不到。
- People 區塊：
  - 已選的人照舊放在最上面（28 pt 頭像、名字、✕）。沒名字的顯示 "Unnamed"（灰字）。
  - 接著 `TextField("Search People", text: $personQuery)`。
  - 下面列出**所有**還沒選的人，**包含沒名字的**，保留 `library.people` 的順序，**不設上限**。
    - 每列：36 pt 圓形頭像、名字（沒名字顯示 "Unnamed"，`.secondary`，跟 `PersonPicker` 一樣）、`plus.circle`。點一下加入並清空搜尋欄。
    - 有輸入文字時，只留名字包含該文字的人（`localizedCaseInsensitiveContains`），沒名字的自然不會符合。
    - 一個都沒有時照舊顯示 "No Matches"。
  - footer 照舊 "Photos with all of them."。
- 刪掉 `// ponytail:` 那行（已經沒有上限）。Form 在 iOS 和 macOS 都是 lazy 的 List，幾百列沒問題。
- 拿掉 Form 裡的「Clear Filters」區塊，改放到外層（見下面），免得被長長的人物清單推到最底下。

### `SearchResults` 的呈現方式

- **iOS sheet**：NavigationStack 的 toolbar 加 `ToolbarItem(placement: .cancellationAction) { Button("Clear Filters") { filter = SearchFilter() }.disabled(!filter.isActive) }`，Done 照舊。
- **Mac popover**：`VStack(spacing: 0) { SearchFilterForm(...); Divider(); HStack { Spacer(); Button("Clear Filters") {...}.disabled(!filter.isActive) }.padding(10) }`，大小照舊 340×480（把 `.frame` 移到外層 VStack，Form 自己不設 frame）。
- `SearchFilterForm` 仍然不知道自己在 sheet 還是 popover 裡。

### 字串

- 不需要新字串（"Unnamed"、"Clear Filters" 都已經有）。建置後同步目錄，確認沒有 stale 項目。

### README

- 如果 README 寫到人物只能用名字搜尋，改成：可以捲動看所有人的頭像挑選，也可以用名字搜尋。

## 追加 3：選人改成第二層頁面，用頭像網格

使用者提議：表單裡只放摘要，點進第二層再用完整的畫面挑人。這比把幾百列塞進表單好：表單保持簡短，第二層可以用頭像網格，一個畫面看得到更多張臉。

### 表單（`SearchFilterForm`）

- 區塊順序回到 **People → Place → Date**（表單已經很短，人物最常用，放最前面）。
- People 區塊：
  - 已選的人照舊（28 pt 頭像、名字或灰字 "Unnamed"、✕）。
  - 一列 `NavigationLink { PeopleChooser(people: $filter.people) } label: { Text("Choose People…") }`。
  - 拿掉表單裡的搜尋欄、可加入的人的清單和 "No Matches"，`personQuery` 和 `addable` 一起刪掉。
  - footer 照舊 "Photos with all of them."。
- Clear Filters 照舊在外層（iOS 導覽列左邊、Mac 面板底部）。

### 新的 `PeopleChooser`（同一個檔案，private 或 internal 都可）

- `@Binding var people: [String]`（`filter.people`，依選取順序）。`@State private var query = ""`。
- 內容：`ScrollView { LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 12)], spacing: 16) { … } .padding() }`。
  - 每格：`Thumb(id:store: library.faces)`，72 pt 圓形；下方名字 `.caption`、`.lineLimit(1)`，沒名字顯示 "Unnamed"（`.secondary`）。
  - 已選：頭像外加 3 pt tint 色圓框，右下角疊 `checkmark.circle.fill`（tint 色，白底圓）。
  - 點一下切換選取（已選就移除，沒選就 append）。整格 `.contentShape(.rect)`，`.buttonStyle(.plain)`。
  - 顯示**所有人**（含沒名字的），`library.people` 的順序；`query` 不空時只留名字包含它的人（`localizedCaseInsensitiveContains`）。
  - 沒有符合時：`ContentUnavailableView.search(text: query)`。
- 標題：`.navigationTitle("People")`。
- 搜尋：
  - **iOS**：`.searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search People")`，`.navigationBarTitleDisplayMode(.inline)`。返回用系統的返回鍵。
  - **macOS**：popover 沒有視窗工具列，NavigationStack 的返回鍵不會出現，所以自己放：`.safeAreaInset(edge: .top) { HStack { Button("Done") { dismiss() }; TextField("Search People", text: $query).textFieldStyle(.roundedBorder) }.padding(10) }`，`@Environment(\.dismiss)` 在 push 進來的頁面裡會 pop 回表單。`.navigationBarBackButtonHidden` 不需要（Mac 本來就沒有）。

### 呈現方式

- **iOS sheet**：本來就有 NavigationStack，不用改。
- **Mac popover**：把現在的 `VStack { Form; Divider; Clear Filters }` 包進 `NavigationStack { … }`，`.frame(width: 340, height: 480)` 放在 NavigationStack 外面，這樣 push 進來的 PeopleChooser 也是同樣大小。

### 字串

- 新增 "Choose People…"（結尾是 U+2026 省略號）：zh-Hant「選擇人物…」、zh-Hans「选择人物…」。
- 同步目錄後，代碼不再用到的 key（例如 "No Matches"，如果別處也沒用到）刪掉。

### README

- Mac 的 Search 那一條：people 的描述改成 "choose them by face from everyone, named or not, in a grid you can narrow by typing a name"（或同義、通順的寫法）。

### 模擬器上發現：iPad 的搜尋欄延遲啟用會弄壞 sheet 的 push

`iOS/PhoneApp.swift` 的 Search 頁有個 `.task`：等 300 ms 後設 `searchShown = true`，想讓 iPad 一進 Search 就打開搜尋欄。iPadOS 27 上這個請求在進頁面時被忽略，直到篩選 sheet 出現時才生效：搜尋欄在 sheet 底下被打開，接著第一次點擊會先把它收起來，而 sheet 裡的「Choose People…」push 就卡住（列反白、不換頁）。拿掉這個 task 之後問題消失；iPhone 的 Search 分頁本來就由系統自動打開搜尋欄，不受影響。`searchShown` 沒有其他用途，一起拿掉。README 的 iPad 說明照實改。

## 追加 4：Mac 上的選人頁樣式、選人後 popover 關掉、篩選按鈕兩層

使用者在 Mac 上回報三件事，原因和改法：

1. **選了第一個人 popover 就關了。** `ToolbarItem` 裡是 `if filter.isActive { filtersButton.buttonStyle(.glassProminent) } else { filtersButton }`：篩選一開，兩個分支互換，按鈕換了身分，掛在它上面的 `.popover` 跟著被拆掉。iOS 的 sheet 掛在 `SearchResults` 上，不受影響。
   - 改法：只有一個 `filtersButton`，不分支。樣式用一個 `PrimitiveButtonStyle`（例如 `private struct FilterButtonStyle { let on: Bool }`），分支寫在 style 的 `makeBody` 裡：`on` 時 `Button(configuration).buttonStyle(.glassProminent)`，否則 `Button(configuration).buttonStyle(.glass)`。分支在按鈕裡面，按鈕本身（和 popover）身分不變。
2. **篩選按鈕看起來有兩層。** 工具列本來就給按鈕一層共用的玻璃底，開著時 `.glassProminent` 又疊一層。
   - 改法：這個 `ToolbarItem` 加 `.sharedBackgroundVisibility(.hidden)`（Mac 的 PhotoViewer 已經這樣用），按鈕自己用上面的 `.glass` / `.glassProminent`，開和關都只有一層、大小一樣。iOS 一樣適用。
3. **選人頁的 Mac 樣式舊。** 現在是一般的 "Done" 按鈕加 `.roundedBorder` 文字框。改成跟 iPad 那頁同樣的樣子（`.safeAreaInset(edge: .top)` 裡）：
   - 第一行：左邊圓形玻璃返回鍵 `Button { dismiss() } label: { Image(systemName: "chevron.left") }.buttonStyle(.glass).buttonBorderShape(.circle)`，`.help("Back")`、`accessibilityLabel("Back")`；中間標題 `Text("People").font(.headline)`（置中，右邊放同寬的空白讓它真的置中，或用 ZStack）。
   - 第二行：膠囊搜尋欄：`HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search People", text: $query).textFieldStyle(.plain); if !query.isEmpty { 清除按鈕 xmark.circle.fill, .buttonStyle(.plain), .foregroundStyle(.secondary) } }`，`.padding(.horizontal, 10).padding(.vertical, 6).background(.quaternary, in: .capsule)`。
   - 外層 `.padding(10)`。不再用 "Done" 字樣（"Back" 如字串表沒有就新增，zh-Hant「返回」、zh-Hans「返回」）。

### 追加 4 的修正（審查時改的）

Sonnet 用 `PrimitiveButtonStyle` 包 `.glass` / `.glassProminent`，在 iPad 上開著時完全沒有底、關著時比旁邊按鈕小。改回原本的 if/else 樣式（`styledFiltersButton`，`@ViewBuilder`），但 `.help` 和 Mac 的 `.popover` 掛在這個分支**外面**，分支換邊時 popover 的身分不變、不會關掉。`ToolbarItem` 的 `.sharedBackgroundVisibility(filter.isActive ? .hidden : .automatic)`：只有開著時拿掉工具列那層底。`FilterButtonStyle` 刪掉。

## 追加 5：圖示、Mac 合併兩個篩選、iOS 按鈕分組

使用者要求：

1. **圖示**：搜尋篩選改用三條越來越短的橫線、沒有圓框：`line.3.horizontal.decrease`。標籤和 help 改成 "Filter"（字串表已有，「篩選」）。
2. **Mac：跟原本的篩選（⋯ 旁的 FilterMenu：照片、影片、原況照片、喜好項目）合併**。Search 頁只留一個篩選按鈕，打開的就是搜尋篩選 popover。iOS 也一樣合併（⋯ 裡的 Filter 子選單在 Search 頁拿掉），兩邊一致。
   - `SearchResults` 新增 `@State private var kinds = PhotoFilter()`；`private var shown: [Asset] { kinds.apply(assets ?? []) }`。傳給 `TimelineBrowser` 的 `assets` 改成 `shown`，副標題的數量也用 `shown.count`（`assets == nil` 時仍是 ""）。`.onChange(of: kinds) { loads += 1 }`，讓格子重新分組。
   - 空結果的 overlay：`assets?.isEmpty == true` 改成 `assets != nil && shown.isEmpty`。
   - 按鈕亮起的條件、`sharedBackgroundVisibility` 和 Clear Filters 的 disabled 都改用 `active`（`filter.isActive || kinds.isActive`）。Clear Filters 兩個都清：`filter = SearchFilter(); kinds = PhotoFilter()`（iOS sheet 和 Mac popover 兩處）。
   - `SearchFilterForm` 加 `@Binding var kinds: PhotoFilter`，Form 最上面加一節 `SwiftUI.Section("Show")`：`Toggle(isOn: $kinds.photos) { Label("Photos", systemImage: "photo") }`、videos（`video`）、live（"Live Photos"，`livephoto`）、favorites（"Favorites"，`heart`），跟原本選單的文字和圖示一樣。新增字串 "Show"：zh-Hant「顯示」、zh-Hans「显示」（手動插入，不要跑 sync）。
   - `TimelineBrowser`：`context == .search` 時不放自己的篩選。Mac（`Mac/ImmichViewerApp.swift` 約 324 行）那個 `ToolbarItem { FilterMenu … }` 包進 `if context != .search`；iOS（`iOS/PhoneTimeline.swift` 約 110 行）⋯ 選單裡的 Filter 子選單包進 `if context != .search`。搜尋時它自己的 `filter` 一直是空的，不用動別的。
3. **iOS/iPadOS 按鈕分組**：「選擇」跟「更多」（⋯）同一組，篩選自己一組。
   - `iOS/PhoneTimeline.swift`：拿掉 Select 和 ⋯ 之間的 `ToolbarSpacer(.fixed, placement: .primaryAction)`。
   - `Shared/Collections.swift` 的 Tags 頁（約 287 行，Select 後面、`ListOptions` 前面的 `ToolbarSpacer`）也拿掉，各頁一致。相簿頁（New Album 後面那個）不動。
   - `SearchResults` 的篩選 `ToolbarItem` 後面加 `#if os(iOS) ToolbarSpacer(.fixed, placement: .primaryAction) #endif`，把它跟 Select 隔開。
4. README：Search 那幾條如果提到 ⋯ 的 Filter 或篩選按鈕，照實改（例如 "On the Search page, Filter also holds Photos, Videos, Live Photos and Favorites"）；不要改 Version history。

### 追加 5 審查時改的

- `sharedBackgroundVisibility(.hidden)` 會讓 `.glassProminent` 在工具列裡完全沒有底（iPad 上只剩圖示）。拿掉它，改成篩選按鈕後面一律放 `ToolbarSpacer(.fixed)`（Mac 和 iOS 都放）：自己一組時，開著就是單獨一顆藍色玻璃，不會畫在別組的玻璃裡。
- Mac 的 popover 裡 NavigationStack 其實有自己的返回鍵和標題，追加 4 自己做的那排變成重複。拿掉，只留膠囊搜尋欄；"Back" 字串和 `dismiss` 也一起拿掉。

### 追加 5 更正：iOS 是「篩選 + ⋯」一組，「選擇」獨立

使用者的意思是篩選跟 ⋯ 一組、「選擇」自己一組；之前讀反了。改法：
- Library、Tags 頁 Select 和 ⋯ 之間的 `ToolbarSpacer` 加回來（跟原本一樣）。
- iOS 的篩選按鈕不再由 `SearchResults` 的 `.toolbar` 放（外層的項目會排在 Select 前面），改用環境值 `searchFilters: SearchFiltersButton?`（`on`、`open`）傳給 iOS 的 `TimelineBrowser`，由它放在 spacer 之後、⋯ 之前。sheet 仍在 `SearchResults`。
- 跟 ⋯ 同一組時不能用 `.glassProminent`（會在 ⋯ 那組的玻璃裡再疊一層），工具列項目也沒有 `.badge`：開著時在圖示右上角加一個 tint 色小圓點。
- Mac 不變：自己一組，開著用 `.glassProminent`。

### 「顯示」改成打勾的多選

照片、影片、原況照片、喜好項目不用開關（開關是設定，不是從清單挑）：每列是按鈕，選上時右側出現 tint 色 `checkmark`，可多選；footer「都不勾就全部顯示。」
