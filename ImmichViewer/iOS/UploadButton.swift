#if os(iOS)
import SwiftUI

/// In the top bar while an upload runs: a ring filling with its progress; tap for the count and Cancel.
struct UploadButton: View {
    @Environment(Library.self) private var library
    @State private var shown = false

    var body: some View {
        if let progress = library.upload {
            Button { shown = true } label: {
                ProgressView(progress)
                    .progressViewStyle(Ring())
                    .frame(width: 22, height: 22)
            }
            .accessibilityLabel("Uploading")
            .accessibilityValue(progress.fractionCompleted.formatted(.percent.precision(.fractionLength(0))))
            .popover(isPresented: $shown) {
                VStack(spacing: 14) {
                    Text("Uploading \(library.uploadStep) of \(Int(progress.totalUnitCount))")
                        .font(.headline)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    ProgressView(progress).labelsHidden()
                    Button("Cancel", role: .cancel) { progress.cancel() }
                        .buttonStyle(.glass)
                }
                .padding(20)
                .frame(width: 260)
                .presentationCompactAdaptation(.popover) // a popover on iPhone too, not a sheet
            }
        }
    }
}

/// A circle that fills clockwise with the progress, an arrow in the middle.
private struct Ring: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.3), lineWidth: 2.5)
            Circle().trim(from: 0, to: configuration.fractionCompleted ?? 0)
                .stroke(.tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Image(systemName: "arrow.up").font(.caption.weight(.bold))
        }
    }
}
#endif
