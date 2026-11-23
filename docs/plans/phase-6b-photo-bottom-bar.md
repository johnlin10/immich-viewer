# 階段 6b：iOS 單張照片的底部工具列

使用者希望 iOS 單張照片檢視的底部有一排常用功能，就像 Photos 那樣。這一階段只改 iPhone 和 iPad，Mac 不動，因為 Mac 有自己的工具列和右鍵選單。不調版本號。

## 長相（照 Photos）

一條 `safeAreaBar(edge: .bottom)`，左中右三組：

| 位置 | 一般 | 垃圾桶（`context == .trash`） |
|---|---|---|
| 左，單顆圓形玻璃 | 分享 `square.and.arrow.up`，執行 `.download`（iOS 上就是 Share…） | 還原 `arrow.uturn.backward`，執行 `.restore` |
| 中，膠囊玻璃，一組按鈕 | 喜好 `heart`／`heart.fill`（已加入時填滿）、資訊 `info.circle`（切換 `showInfo`）、裁切 `crop`（只在 `asset.canCrop` 時顯示） | 資訊 `info.circle` |
| 右，單顆圓形玻璃 | 刪除 `trash`，執行 `.trash`，沿用現有的確認提示 | 永久刪除 `trash`，執行 `.trash`，在垃圾桶裡就是 Delete Permanently… 的確認 |

- 一律走 `editor.perform(…, on: [asset], context:, library:, undo:, place:)`，跟 ⋯ 選單一樣。不另寫任何動作。
- 圓形按鈕用現有的 `circleGlass()`。中間那組用 `HStack`，每顆 44×44，外面包一個 `.glassEffect(.regular.interactive(), in: .capsule)`。
- 每顆按鈕都要有 `Label` 文字，作為 VoiceOver 的名稱，畫面上只顯示圖示。
  - 文字沿用現有字串：Share…、Add to Favorites 或 Remove from Favorites、Info、Crop…、Delete…、Restore、Delete Permanently…。
  - 如果真的需要不帶「…」的版本，再新增字串，並補上 zh-Hant 和 zh-Hans。
- 跟頂部的列一起淡入淡出：`.opacity(chromeHidden ? 0 : 1)` 加上 `.allowsHitTesting(!chromeHidden)`。
- 影片控制列和人臉列（現有的 `overlay(alignment: .bottom)`）要排在工具列**上方**，不能被擋住。
  - 把 `safeAreaBar(edge: .bottom)` 掛在那個 overlay 之後，讓 overlay 吃到安全區域。
  - 如果吃不到，就把工具列搬進同一個 VStack 的最底下。
  - 用模擬器確認影片和有人臉的照片都排得對。
- 照片本身仍然滿版，照片頁 `ignoresSafeArea`。工具列浮在照片上。
- ⋯ 選單不改，保留完整選單。Photos 也是兩邊都有。

## 不做

- 底部縮圖捲軸，就是使用者截圖裡 Photos 的那條。這件事比較大：要另外排版、和換頁同步、處理捲動。先問使用者要不要，這階段不做。

## README

在第 83 行「Tap a photo to open it…」那條加一句：底部有分享、喜好、資訊、裁切和刪除，像 Photos；在垃圾桶裡則是還原和永久刪除。

## 驗證（另一個 Sonnet）

用已經開機的 iOS 27 模擬器：iPhone 17 Pro，以及 iPad Pro 11-inch (M5)。連 scratchpad 的假伺服器 2303，**不能連真伺服器**。逐項確認：

- 靜態照片：五顆按鈕都在。
  - 喜好：圖示會切換，回到網格後愛心標記也一致。
  - 資訊：iPhone 開 sheet，iPad 開側欄。
  - 裁切：開 CropSheet。
  - 刪除：跳出確認。
  - 分享：開分享面板。
- Live Photo 和影片：不顯示裁切。影片控制列在工具列上方。
- 點照片：工具列跟著上方的列一起隱藏和顯示。
- 垃圾桶裡：顯示還原、資訊、永久刪除。
