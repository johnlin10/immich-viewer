# Localization plan

Status: steps 1 and 2 done (English source, `zh-Hant` and `zh-Hans` translations).

## Languages

| Priority | Language | Code | Role |
|---|---|---|---|
| 1 | English (US) | `en` | Development language, used when no other language matches |
| 2 | Traditional Chinese (Taiwan) | `zh-Hant` | Taiwan terms; matches today's text |
| 3 | Simplified Chinese | `zh-Hans` | Mainland terms, not a character conversion of `zh-Hant` |

The app follows macOS: the user's preferred languages, or the per-app language in System Settings > General > Language & Region > Applications. No language picker in the app.

## How

- One String Catalog, `ImmichViewer/Resources/Localizable.xcstrings`. Xcode fills it from the code when built in Xcode; translations live only there. A command-line build doesn't update it; after `xcodebuild`, run `xcrun xcstringstool sync ImmichViewer/Resources/Localizable.xcstrings --stringsdata <DerivedData>/…/Objects-normal/arm64/*.stringsdata`.
- Source strings in the code are English. `zh-Hant` and `zh-Hans` are translations in the catalog.
- Project: `developmentRegion` becomes `en`; `knownRegions` becomes `en`, `zh-Hant`, `zh-Hans`, `Base`. System menus (File, Edit, View, Window) then follow the same language.
- The app name stays "Immich Viewer" in every language. The menu bar name comes from `CFBundleName` in `ImmichViewer/Resources/InfoPlist.xcstrings` (the generated Info.plist would otherwise use the product name `ImmichViewer`); add each new language there too.

## Code changes

A survey of v0.1.0 found 74 Chinese strings in 8 files. Most are literals in `Text`, `Button`, `Toggle`, `Label`, `.help` and `.navigationTitle`, which SwiftUI already looks up in the catalog once they are English. These need more than a new literal:

1. **Strings passed around as `String`.** SwiftUI shows a `String` variable as-is, without a lookup. Change these to `LocalizedStringResource` (or `String(localized:)` where a `String` is needed):
   - `Grouping.label` (Days, Months, All)
   - `TimelineBrowser` `title` and `subtitle`, and the person and album titles passed into it
   - `Library.status` (sync progress, item count, sync errors)
   - `Empty` `title` on the People and Albums pages
2. **Counts.** Use catalog plural variants. English needs "one" and "other", Chinese only "other".
   - "%lld items", "%lld people", "%lld albums"
   - "%lld unnamed" in the info panel
   - "Downloading thumbnails %lld of %lld", "%lld failed"
3. **Punctuation inside strings.** Move it into the translations instead of the code:
   - The full-width `（⌘I）` in help tags becomes ` (⌘I)` in English.
   - The `：` in sync errors.
   - Places in the info panel (city, state, country) are joined with the `place.separator` string (", " in English, "，" in Chinese).
4. **Dates and numbers** already use `Date.FormatStyle` and `formatted()`, which follow the locale: section headers, date capsule, scrubber month, info panel, jump-to-date calendar (including the first day of the week). Keep the `.gmt` time zone; only the locale changes.
5. **Not translated:** error text from the Immich server (English), file names, camera and lens names, people and album names, and permission names such as `asset.read`.

## Glossary

Use the same word everywhere in a language. Taiwan and mainland terms differ, so `zh-Hans` must be written with mainland terms.

| English | zh-Hant (Taiwan) | zh-Hans |
|---|---|---|
| Library | 圖庫 | 图库 |
| People | 人物 | 人物 |
| Albums | 相簿 | 相册 |
| Photo | 照片 | 照片 |
| Video | 影片 | 视频 |
| Days / Months / All | 依日 / 依月 / 不分組 | 按日 / 按月 / 不分组 |
| Show Whole Photos | 顯示完整比例 | 显示完整比例 |
| Refresh | 重新整理 | 刷新 |
| Go to Date… | 跳到日期… | 跳到日期… |
| Info | 資訊 | 信息 |
| Thumbnail | 縮圖 | 缩略图 |
| Cache | 快取 | 缓存 |
| Server | 伺服器 | 服务器 |
| Server URL | 伺服器網址 | 服务器地址 |
| Start / Stop (server) | 啟動 / 停止 | 启动 / 停止 |
| Command | 指令 | 命令 |
| Local Network | 區域網路 | 本地网络 |
| API Key | API 金鑰 | API 密钥 |
| Settings | 設定 | 设置 |
| Copy | 拷貝 | 拷贝 |
| Original | 原始檔 | 原始文件 |
| File name | 檔名 | 文件名 |
| Open in browser | 在瀏覽器開啟 | 在浏览器中打开 |
| Favorites | 喜好項目 | 个人收藏 |
| Archive / Unarchive | 封存 / 取消封存 | 归档 / 取消归档 |
| Trash | 垃圾桶 | 废纸篓 |
| Description | 說明 | 说明 |
| Rating | 評分 | 评分 |
| Adjust Date and Time… | 調整日期與時間… | 调整日期与时间… |
| Set Location… | 設定位置… | 设置位置… |
| Album cover | 相簿封面 | 相册封面 |
| Tag | 標籤 | 标签 |
| Restore (from Trash) | 復原 | 恢复 |
| Delete Permanently | 永久刪除 | 永久删除 |
| Import… (upload) | 輸入… | 导入… |
| Download | 下載 | 下载 |
| Rotate Left / Right | 向左 / 向右旋轉 | 向左 / 向右旋转 |
| Merge (people) | 合併 | 合并 |

## Layout to check in each language

- Bottom bar: the grouping capsule sizes to its text; check that it stays centred and doesn't clip.
- Settings: labels next to sliders and switches, the long captions under Storage, Connection and Server.
- Info panel chips, the scrubber's month bubble, the date capsule.
- People and album captions (one line, truncated).
- Run once with Xcode's Double-Length pseudo-language to catch clipping.

## Testing

- Unit checks stay as they are; they don't touch text.
- Run the test build on the fake server in each language with `-AppleLanguages "(en-US)"`, `"(zh-Hant-TW)"` and `"(zh-Hans-CN)"`, and go through: sidebar, grid and bottom bar, View menu, ⋯ menu, single photo view and info panel, Go to Date, every Settings tab, the Clear Cache dialog, sync status and errors.
- Before a release, the catalog has no strings marked New or Stale in any language.

## Steps

1. **v0.2.0: English source (done).** Switch the development language to English, move the existing Chinese into `zh-Hant`, make the code changes above. The app looks the same in Traditional Chinese and is complete in English.
2. **Simplified Chinese (done).** Add `zh-Hans` using the glossary, then check layout.
3. **README:** remove the "planned" note and say the interface follows the macOS language.

From then on, every new UI string is written in English in the code, and its `zh-Hant` and `zh-Hans` translations go in the same commit.
