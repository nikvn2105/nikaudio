import ReplayKit
import SwiftUI

struct ScreenProbeView: View {
    @State private var state: ScreenProbe.State = .waiting
    @State private var hasAppGroup = false
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Kiểm tra ReplayKit").font(AppFont.bold(30, relativeTo: .largeTitle))
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Bản này kiểm tra chữ ký và khả năng nhận khung hình. Không giữ hoặc gửi hình ảnh.")
                        .foregroundStyle(.secondary)
                    Label(hasAppGroup ? message : "App Group chưa được cấp sau khi ký.", systemImage: "checkmark.shield")
                    if hasAppGroup {
                        ProbeBroadcastPicker()
                            .frame(width: 48, height: 48)
                            .background(GlassTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                            .accessibilityLabel("Mở bộ chọn phát màn hình")
                        Text("Bấm nút phát, chọn NiKAudio và bắt đầu. Dừng trong Trung tâm điều khiển sau khi thấy kết quả.")
                            .foregroundStyle(.secondary)
                        Button("Xóa kết quả kiểm tra") {
                            ScreenProbe.storage?.removeObject(forKey: ScreenProbe.stateKey)
                            updateStatus()
                        }
                    }
                }
                .padding(20)
                .glassPanel(radius: 24)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(GlassBackdrop())
        .font(AppFont.regular(16, relativeTo: .body))
        .onAppear(perform: updateStatus)
        .onReceive(refresh) { _ in updateStatus() }
    }

    private var message: String {
        switch state {
        case .waiting: return "Sẵn sàng kiểm tra"
        case .started: return "Extension đã khởi động"
        case .video: return "Đã nhận khung hình từ ReplayKit"
        case .stopped: return "Đã dừng trước khi nhận khung hình"
        }
    }

    private func updateStatus() {
        let storage = ScreenProbe.storage
        hasAppGroup = storage != nil
        state = ScreenProbe.State(rawValue: storage?.string(forKey: ScreenProbe.stateKey) ?? "") ?? .waiting
    }
}

private struct ProbeBroadcastPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView()
        picker.preferredExtension = ScreenProbe.extensionBundle
        picker.showsMicrophoneButton = false
        return picker
    }

    func updateUIView(_ picker: RPSystemBroadcastPickerView, context: Context) {}
}
