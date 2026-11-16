import AppKit
import SwiftUI

/// The Settings window (⌘,).
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("一般", systemImage: "gearshape") { GeneralSettings() }
            Tab("影片", systemImage: "play.rectangle") { VideoSettings() }
            Tab("儲存空間", systemImage: "internaldrive") { StorageSettings() }
            Tab("連線", systemImage: "network") { ConnectionForm().padding(20) }
        }
        .frame(width: 460)
    }
}

/// "system", "light" or "dark", for the whole app.
func applyAppearance(_ value: String) {
    NSApp.appearance = switch value {
    case "light": NSAppearance(named: .aqua)
    case "dark": NSAppearance(named: .darkAqua)
    default: nil
    }
}

private struct GeneralSettings: View {
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("gridSpacing") private var spacing = 1.0
    @AppStorage("cornerRadius") private var radius = 0.0
    @AppStorage("videoBadge") private var badge = true
    @AppStorage("newestFirst") private var newestFirst = true
    @AppStorage("fitWholePhoto") private var fit = false

    var body: some View {
        Form {
            Picker("外觀", selection: $appearance) {
                Text("跟隨系統").tag("system")
                Text("淺色").tag("light")
                Text("深色").tag("dark")
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { applyAppearance(appearance) }

            SwiftUI.Section("照片網格") {
                Picker("排序", selection: $newestFirst) {
                    Text("最新的在上").tag(true)
                    Text("最舊的在上").tag(false)
                }
                LabeledContent("間距") {
                    Slider(value: $spacing, in: 0...8, step: 1) { EmptyView() } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("8") }
                }
                LabeledContent("圓角") {
                    Slider(value: $radius, in: 0...12, step: 1) { EmptyView() } minimumValueLabel: { Text("0") } maximumValueLabel: { Text("12") }
                }
                Toggle("顯示完整比例", isOn: $fit)
                Toggle("標示影片（▶）", isOn: $badge)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct VideoSettings: View {
    @AppStorage("videoAutoplay") private var autoplay = true
    @AppStorage("videoMuted") private var muted = false
    @AppStorage("videoLoop") private var loop = false

    var body: some View {
        Form {
            Toggle("打開時自動播放", isOn: $autoplay)
            Toggle("開始時靜音", isOn: $muted)
            Toggle("重複播放", isOn: $loop)
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct StorageSettings: View {
    @Environment(Library.self) private var library
    @State private var thumbs: Int?
    @State private var faces: Int?
    @State private var confirming = false

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("縮圖", value: size(thumbs))
                LabeledContent("人物頭像", value: size(faces))
            } footer: {
                Text("縮圖存在這台 Mac 上，捲動時不必向伺服器要。清除後，照片會在下次顯示時重新下載；重新整理（⌘R）會一次全部補回。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("在 Finder 中顯示") { NSWorkspace.shared.activateFileViewerSelecting([library.thumbs.dir]) }
                Spacer()
                Button("清除快取…", role: .destructive) { confirming = true }
                    .disabled(library.syncing)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .task { await measure() }
        .confirmationDialog("清除所有快取的縮圖？", isPresented: $confirming) {
            Button("清除", role: .destructive) {
                library.thumbs.clear()
                library.faces.clear()
                Task { await measure() }
            }
        } message: {
            Text("伺服器上的照片不受影響。")
        }
    }

    private func size(_ bytes: Int?) -> String { bytes.map { $0.formatted(.byteCount(style: .file)) } ?? "計算中…" }

    private func measure() async {
        let stores = (library.thumbs, library.faces)
        (thumbs, faces) = await Task.detached { (stores.0.diskSize(), stores.1.diskSize()) }.value
    }
}

/// Server address and API key.
struct ConnectionForm: View {
    @Environment(Library.self) private var library
    @State private var server = ""
    @State private var key = ""

    var body: some View {
        Form {
            TextField("伺服器網址", text: $server)
            SecureField("API 金鑰", text: $key)
            Text("在 Immich 網頁的「帳號設定 > API 金鑰」建立新金鑰，權限勾選 asset.read、asset.view、person.read 和 album.read。想拷貝或拖出原始檔，再加 asset.download（沒有就用大預覽圖）。金鑰存在鑰匙圈裡。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("連線") { library.connect(server: server, key: key) }
                .keyboardShortcut(.defaultAction)
                .disabled(key.isEmpty || URL(string: server) == nil)
        }
        .onAppear { server = library.serverURL }
    }
}
