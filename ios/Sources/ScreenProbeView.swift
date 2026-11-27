import CryptoKit
import ReplayKit
import SwiftUI

struct ScreenProbeView: View {
    @AppStorage("fileTransferPCAddress") private var address = ""
    @AppStorage("pairedPCService") private var preferredPC = ""
    @State private var prepared = false
    @State private var preparing = false
    @State private var pairingError: String?
    @State private var state: ScreenProbe.State = .waiting
    @State private var hasAppGroup = false
    private let refresh = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Chiếu màn hình").font(AppFont.bold(30, relativeTo: .largeTitle))
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 12) {
                    Text("H.264 tối đa 720p/30 fps qua Wi-Fi. Trên Windows, chọn Xem màn hình iPhone.")
                        .foregroundStyle(.secondary)
                    Label(hasAppGroup ? message : "App Group chưa được cấp sau khi ký.", systemImage: "checkmark.shield")
                    if hasAppGroup {
                        Button(preparing ? "Đang tìm PC…" : "Chuẩn bị PC nhận màn hình") { prepare() }
                            .buttonStyle(.borderedProminent)
                            .disabled(preparing)
                    }
                    if let pairingError { Text(pairingError).foregroundStyle(.orange) }
                    if hasAppGroup && prepared {
                        ProbeBroadcastPicker()
                            .frame(width: 48, height: 48)
                            .background(GlassTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                            .accessibilityLabel("Mở bộ chọn phát màn hình")
                        Text("Bấm nút phát và chọn NiKAudio. Dừng chia sẻ trong Trung tâm điều khiển.")
                            .foregroundStyle(.secondary)

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

    private func prepare() {
        preparing = true
        prepared = false
        pairingError = nil
        Task { @MainActor in
            defer { preparing = false }
            do {
                let key = try LANPairing.key()
                let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
                let pc = try await PairedPC.find(address: host, preferred: preferredPC, key: key)
                if let name = pc.name { preferredPC = name }
                let tag = HMAC<SHA256>.authenticationCode(for: Data("NiKAudio screen v1".utf8),
                                                         using: SymmetricKey(data: key))
                let config = ScreenProbe.Destination(address: host, service: pc.name, key: Data(tag))
                guard let storage = ScreenProbe.storage else {
                    throw FileTransferError.remote("Không tìm thấy App Group đã ký.")
                }
                storage.set(try JSONEncoder().encode(config), forKey: ScreenProbe.configKey)
                prepared = true
            } catch {
                pairingError = error.localizedDescription
            }
        }
    }

    private var message: String {
        switch state {
        case .waiting: return "Sẵn sàng chuẩn bị"
        case .started: return "Đang kết nối tới PC…"
        case .video: return "Đang gửi màn hình sang PC"
        case .reconnecting: return "Đang kết nối lại…"
        case .stopped: return "Đã dừng phát màn hình"
        case .failed: return "Không thể phát màn hình"
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
