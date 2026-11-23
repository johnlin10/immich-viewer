# 階段 6：裁切

這一階段的範圍是 README「Not in this version」中的 cropping。照波次規則，這階段不調 `MARKETING_VERSION`，也不寫 Version history。

## 伺服器怎麼做（Immich v3，`dtos/editing.dto.js`、`services/asset.service.js`、`repositories/media.repository.js`）

裁切跟旋轉走同一組端點：`GET / PUT / DELETE assets/{id}/edits`。
- `PUT` 的內容是 `{"edits": [{action, parameters}, …]}`，每個 action 最多出現一次。
- action 有三種：
  - `crop {x, y, width, height}`：都是整數，x、y 至少 0，寬高至少 1。
  - `rotate {angle}`：值為 0、90、180、270。
  - `mirror {axis}`：值為 `horizontal` 或 `vertical`。
- **crop 必須排在第一個**，否則回 400「Crop action must be the first edit action」。
  - 伺服器先切，再依序套用其餘的旋轉和鏡像。
- crop 的座標系是**原檔轉正後的像素**，也就是原檔套用 EXIF orientation 之後的方向。
  - 尺寸由 `getDimensions` 算出：`exifImageWidth × exifImageHeight`；當 `orientation` 是 5、6、7、8、-90、90 時，寬高互換。
  - 若 `x + width > 寬` 或 `y + height > 高`，回 400「out of bounds」。
- 伺服器會拒絕以下素材，並回錯誤訊息：影片、Live Photo、全景照、GIF、SVG。
- 每次 `PUT` 會整組取代既有的編輯，然後在背景重做縮圖。
  - 這跟旋轉的情況一樣，所以沿用旋轉現有的等候與刷新做法。
- `thumbnail?size=preview&edited=false` 會回傳**未編輯**的預覽，方向已轉正，但沒有切也沒有轉。
- `GET assets/{id}` 的 `exifInfo` 裡有 `exifImageWidth`、`exifImageHeight`，以及 `orientation`（字串，可能是 null）。

## 決定

- **入口**：在照片選單的 Rotate Right 後面加 **Crop…**（`systemImage: "crop"`）。
  - 只有選了一張、而且是靜態照片（不是影片、不是 Live Photo）時才顯示。
  - Mac 的右鍵選單和 ⋯ 選單、iOS 的長按選單和 ⋯ 選單都會出現。
- **畫面**：打開一個 sheet，`CropSheet`。
  - 顯示的照片已套用目前的旋轉，也就是使用者平常看到的方向。
  - 上面疊一個可調整的框：
    - 拖四個角可縮放。
    - 拖框內可移動。
    - 框外調暗。
    - 框內畫三等分格線，這是 Photos 的慣例，畫幾條線而已。
  - 按鈕有 Cancel、Reset（框回到整張）、Crop（存檔）。
  - 不做比例鎖定、不做自由角度旋轉。
- **儲存**：
  - 框等於整張時，就拿掉 crop。
  - 其餘編輯（rotate、mirror）原樣保留，crop 放在最前面。
  - 拿掉 crop 後如果什麼編輯都不剩，就送 `DELETE`。
  - 存檔後可以 Undo，Undo 會回到原本的 crop（或沒有 crop）。
- **鏡像**：已經用網頁版鏡像過的照片，sheet 只顯示一行說明，並停用 Crop 按鈕。
  - 文案：「This photo was mirrored in Immich’s web app, so it can’t be cropped here.」
  - 這是 `ponytail:`：要處理鏡像的換算，得照編輯順序組出完整的仿射轉換；等真的有人遇到再做。

## 程式

### `Core/TimelineModel.swift`（純數學，跟其他算式放一起，讓 `Tests/main.swift` 測得到）

```swift
/// A crop in the original's pixels, upright (EXIF orientation applied): what Immich's `crop` edit takes.
struct PixelCrop: Equatable, Sendable { var x, y, width, height: Int }

/// `rect`, 0…1 in the photo as shown (turned `angle` degrees clockwise), in the upright original's pixels
/// (`size`), rounded and kept inside it.
func pixelCrop(_ rect: CGRect, angle: Int, size: CGSize) -> PixelCrop
/// The other way: where `crop` sits, 0…1, in the photo as shown.
func shownRect(_ crop: PixelCrop, angle: Int, size: CGSize) -> CGRect
```

把顯示座標 (u, v) 換回原檔的正規化座標 (x, y)：

| 角度（順時針） | 換算 |
|---|---|
| 0 | x = u，y = v |
| 90 | x = v，y = 1 − u |
| 180 | x = 1 − u，y = 1 − v |
| 270 | x = 1 − v，y = u |

- 把矩形兩個對角點各自換算，再取 min/max。
- 乘上 `size` 後四捨五入，再夾在範圍內：x、y 至少 0，寬高至少 1，x + w 不超過寬，y + h 不超過高。
- `shownRect` 是反向換算。

### `Core/Library.swift`

- 把 `rotate` 裡的「讀 edits → 改 → PUT 或 DELETE」抽成私有輔助函式：

  ```swift
  /// Reads a photo's edits, lets `change` alter them (action/parameters dictionaries, in order), and saves them:
  /// PUT, or DELETE when none are left.
  private nonisolated static func changeEdits(_ api: ImmichAPI, _ id: String, _ change: (inout [[String: Any]]) -> Void) async throws
  ```

  - `rotate` 改用這個輔助函式，行為不變。
  - 「等 3 秒、清掉快取、`revision += 1`、`edits += 1`」那段也抽成 `private func refetchEdited(_ ids:)`，`rotate` 和 `crop` 共用。
- 新增：

  ```swift
  /// Crops a photo, keeping its other edits; nil takes the crop away. `was`: the crop before, for undo.
  func crop(_ id: String, to crop: PixelCrop?, was: PixelCrop?, undo: UndoManager?) async
  ```

  - 先移除既有的 crop。如果新的不是 nil，插在 index 0，參數為 `["x":, "y":, "width":, "height":]`。
  - 成功後 `register(undo, String(localized: "Crop")) { await $0.crop(id, to: was, was: crop, undo: undo) }`，然後 `refetchEdited([id])`。
- 新增 sheet 要用的讀取函式（寫在 Library 或 ImmichAPI 都行，挑跟現有程式風格一致的地方）：
  - 讀照片的 edits，回傳 `(crop: PixelCrop?, angle: Int, mirrored: Bool)`。
  - 讀原檔轉正後的尺寸：用 `AssetDetail.Exif`（加上 `var orientation: String?`）。
    - 寬高互換的規則照伺服器：`Int(orientation)` 屬於 [5, 6, 7, 8, -90, 90] 時互換。
    - 尺寸缺少時，sheet 顯示伺服器那句「dimensions are not available」的意思，並停用 Crop。
  - 未編輯的預覽：`thumbnail` 多一個參數 `edited: Bool = true`。
    - `edited` 為 false 時帶 `edited=false`，不要影響既有呼叫，也不要動 `forgetCached` 的 key。

### `Shared/Editing.swift`

- `PhotoAction` 加 `case crop`。
- `PhotoMenu` 加 `var canCrop = false`；為 true 時，在 Rotate Right 後面顯示 Crop…。
  - 每個建立 `PhotoMenu` 的地方都要傳值：當只有一張照片、`!isVideo`、`isLive != true` 時傳 true。
  - 用 grep 找齊 Mac 和 iOS 的所有呼叫點。
- `PhotoEditor.perform`：`.crop` 時設 `sheet = .crop(first)`。
- `EditSheet` 加 `case crop(Asset)`，`id` 是 `"crop" + asset.id`。
- `editSheet` 裡顯示 `CropSheet(asset:, library:, undo:)`。

### 新檔 `Shared/Crop.swift`：`CropSheet`

- 專案使用 file system synchronized groups，新檔不用改 pbxproj。
- 載入時一次拿齊三樣：edits、尺寸、未編輯預覽。預覽用 `library.api`。
  - 先顯示 `ProgressView`。
  - 失敗時顯示錯誤文字，並停用 Crop。
- 照片用 `.rotationEffect(.degrees(angle))` 轉正嗎？**不要**。
  - 直接把 `CGImage` 轉好再顯示，或在 `GeometryReader` 裡依顯示後的比例排版。
  - 重點是：框的座標要跟畫出來的照片在同一個座標系，框存成 0…1 的 `CGRect`。
  - 90 和 270 度時，顯示比例是寬高互換的。
- 初始框：有既有 crop 就用 `shownRect`，沒有就用 `CGRect(x: 0, y: 0, width: 1, height: 1)`。
- 拖曳：
  - 角用 `DragGesture`，夾住讓框留在 0…1 內，寬高至少為照片的 5%。
  - 框內拖曳時整個框平移，同樣夾在範圍內。
  - 把手畫成 L 形角線，要夠大，觸控上至少 44 pt 的命中範圍。
- 存檔：
  - 若框跟整張的差距不到 0.5%，視為 nil。
  - 否則用 `pixelCrop(rect, angle:, size:)` 換算。
  - 如果結果等於原本的 crop，就直接關掉。
  - 不然就 `Task { await library.crop(asset.id, to: new, was: old, undo: undo) }` 再關掉。
- 大小：Mac 用 `.frame(minWidth: 640, minHeight: 520)`；iOS 用 `NavigationStack`，toolbar 放 Cancel、Crop，Reset 放底部。
  - 照 `DateSheet` 等既有 sheet 的寫法，保持兩個平台的慣例。

### 字串

`Localizable.xcstrings` 要為新字串補上 zh-Hant 和 zh-Hans：
- 「Crop…」：裁切…
- 「Crop」：裁切
- 「Reset」：重置
- 「Cancel」若已存在就沿用。
- 鏡像說明和尺寸錯誤說明。

### README

- Editing 那段的右鍵清單，在 Rotate Left / Right 後加上 Crop…。
- 在 Rotate 那條下面加一條，說明 Crop… 的用法：
  - 拖角縮放、拖框移動，Reset 回到整張。
  - 伺服器保留原檔，裁切存成編輯，跟旋轉一起保留。
  - 只支援靜態照片，不支援 Live Photo 和影片。
  - 網頁版鏡像過的照片不能在這裡裁切。
- iOS 那段「Editing works like on the Mac」的清單加上 cropping。
- 「Not in this version」只剩 Map，不用動。

### 測試 `Tests/main.swift`

- `pixelCrop`：size 4000×3000。
  - angle 0，rect (0.25, 0.5, 0.5, 0.5) → (1000, 1500, 2000, 1500)。
  - angle 90，rect (0, 0, 0.5, 1) → 原檔下半，也就是 (0, 1500, 4000, 1500)。
  - angle 180、270 各一例。
  - 超出邊界的 rect 會被夾住。
- `shownRect(pixelCrop(r)) ≈ r`：四個角度都測，誤差小於 1/1000。

## 假伺服器（scratchpad `fake_immich.py`）

- `GET / PUT / DELETE assets/{id}/edits`：每張照片存在記憶體裡。
  - PUT 時檢查 crop 是否排第一、是否在範圍內，不符合就回 400，帶 `{"message": …}`。
  - 回傳格式照真的伺服器：`{assetId, edits: [{id, action, parameters}]}`。
- `GET assets/{id}`：`exifInfo` 加上 `exifImageWidth: 4000`、`exifImageHeight: 3000`、`orientation: "1"`。
- 預覽圖改成**四格不同顏色**，不再是單色，這樣看得出有沒有切到、有沒有轉。
  - `edited=true` 而且有 crop 或 rotate 時，照編輯畫出結果：先切，再轉。
  - 純 Python 就做得到：圖本來就是用像素陣列產生的。
- 這些改動只放 scratchpad，**不進 repo**。

## 驗證

- `xcodebuild` 跑 Mac 和 iOS，Mac 要建到 `build/`。
- `Tests/main.swift` 要通過。
- Mac App 連假伺服器：
  - 裁一張 → 縮圖跟大圖都變成裁過的樣子。
  - Undo → 回到原樣。
  - 先 Rotate Right 再 Crop → 框跟看到的方向一致，存檔後的結果正確。
  - 再次打開 Crop… → 框停在上次的位置。
  - 按 Reset 存檔 → 送出 DELETE，或只剩 rotate。
- iOS 用已開機的 iOS 27 模擬器（iPhone 17 Pro）連假伺服器，同樣流程跑一遍，並確認觸控拖角可用。
- 影片和 Live Photo 的選單裡不會出現 Crop…。
- **不能連使用者的真伺服器**，`localhost:2283` 和 `2284` 都不行。
