import SwiftUI

struct ContentView: View {
    @StateObject private var receiver = AudioReceiver()
    @State private var showPairing = false
    @State private var showDiagnostics = false
    @State private var confirmKeyRenewal = false
    @State private var pairingKey = ""
    @State private var pairingError = ""

    private var status: (title: String, icon: String, tint: Color) {
        guard receiver.isRunning else { return ("Đã dừng", "waveform", .white) }
        switch receiver.mode {
        case .usb:
            return (receiver.pcIdle ? "PC đang im tiếng" : "Đang phát qua Lightning", "cable.connector", GlassTheme.mint)
        case .lan:
            return (receiver.pcIdle ? "PC đang im tiếng" : "Đang phát qua Wi-Fi", "wifi", GlassTheme.lilac)
        case .waiting:
            return ("Đang chờ PC", "waveform", .white)
        }
    }

    private var statusDetail: String? {
        if receiver.isRunning && receiver.pcIdle { return receiver.mode.rawValue }
        if receiver.statusMessage.hasPrefix("Lỗi") || receiver.statusMessage.hasPrefix("Đang chờ mở cổng") {
            return receiver.statusMessage
        }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("NiKAudio")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.vertical, 8)
                playbackCard
                qualityCard
                Button {
                    loadPairing()
                    showPairing = true
                } label: {
                    HStack(spacing: 12) {
                        Label("Ghép đôi Wi-Fi", systemImage: "link")
                            .font(.headline)
                        Spacer()
                        Image(systemName: "chevron.forward")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .padding(18)
                    .glassPanel(radius: 24)
                }
                .buttonStyle(.plain)
                diagnosticsCard
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .background(GlassBackdrop())
        .sheet(isPresented: $showPairing, onDismiss: { pairingKey = "" }) {
            pairingSheet
        }
    }

    private var playbackCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: status.icon)
                .font(.title3.weight(.semibold))
                .foregroundStyle(status.tint)
                .frame(width: 48, height: 48)
                .background(status.tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(status.title)
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let statusDetail = statusDetail {
                    Text(statusDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Label(receiver.outputRoute, systemImage: "headphones")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Đầu ra âm thanh: \(receiver.outputRoute)")
            }

            Button {
                receiver.toggle()
            } label: {
                Label(receiver.isRunning ? "Dừng nhận âm thanh" : "Bắt đầu nhận âm thanh",
                      systemImage: receiver.isRunning ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .padding(.horizontal, 12)
                    .foregroundStyle(Color.black)
                    .background(receiver.isRunning ? Color.white.opacity(0.90) : GlassTheme.mint,
                                in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 30)
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chất lượng phát")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    preset("Độ trễ thấp", symbol: "bolt", milliseconds: 12)
                    preset("Ổn định", symbol: "shield", milliseconds: 30)
                }
                VStack(spacing: 8) {
                    preset("Độ trễ thấp", symbol: "bolt", milliseconds: 12)
                    preset("Ổn định", symbol: "shield", milliseconds: 30)
                }
            }
        }
        .padding(18)
        .glassPanel(radius: 24)
    }

    private func preset(_ title: String, symbol: String, milliseconds: Double) -> some View {
        let selected = receiver.targetBufferMs == milliseconds
        return Button {
            receiver.targetBufferMs = milliseconds
        } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.horizontal, 10)
                .foregroundStyle(selected ? GlassTheme.mint : Color.white)
                .background(selected ? GlassTheme.mint.opacity(0.13) : Color.white.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(selected ? GlassTheme.mint.opacity(0.45) : Color.clear)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var diagnosticsCard: some View {
        DisclosureGroup(isExpanded: $showDiagnostics) {
            VStack(alignment: .leading, spacing: 12) {
                metric("IP Wi-Fi iPhone", receiver.localIP)
                metric("Cổng", "\(AudioReceiver.port)")
                metric("Bộ đệm hiện tại", milliseconds(receiver.bufferMs))
                metric("Mức đệm thực tế", milliseconds(receiver.effectiveTargetMs))
                metric("Tốc độ gói", "\(receiver.packetsPerSec) pkt/s")
                metric("Lần hụt đệm", "\(receiver.underruns)")
                metric("Gói thiếu lúc phát", "\(receiver.droppedPackets)")
                metric("Gói đến muộn", "\(receiver.latePackets)")
                metric("Khoảng cách gói khi chuyển", receiver.lastHandoffMs.map(milliseconds) ?? "–")
                Divider()
                metric("Mức đệm tùy chỉnh", "\(Int(receiver.targetBufferMs)) ms")
                Slider(value: $receiver.targetBufferMs, in: 10...60, step: 1)
                    .accessibilityLabel("Mức đệm tùy chỉnh")
                    .accessibilityValue("\(Int(receiver.targetBufferMs)) mili giây")
            }
            .padding(.top, 16)
        } label: {
            Label("Chẩn đoán", systemImage: "waveform.path")
                .font(.headline)
                .frame(minHeight: 28)
        }
        .tint(GlassTheme.mint)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassPanel(radius: 24)
    }

    private var pairingSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Chuyển khóa sang máy tính qua kênh riêng. Trên Windows, chép khóa vào clipboard rồi chọn **Pair using key from clipboard** trong khay NiKAudio.")
                        .foregroundStyle(.secondary)
                    if !pairingKey.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Khóa ghép đôi").font(.headline)
                            Text(pairingKey)
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassPanel(radius: 24)
                    }
                    if !pairingError.isEmpty {
                        Text(pairingError).foregroundStyle(.red)
                    }
                    Button("Tạo khóa mới", role: .destructive) { confirmKeyRenewal = true }
                        .frame(minHeight: 44)
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(GlassBackdrop())
            .navigationTitle("Ghép đôi Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { showPairing = false }
                        .tint(GlassTheme.mint)
                }
            }
            .confirmationDialog("Khóa cũ trên Windows sẽ mất hiệu lực.", isPresented: $confirmKeyRenewal,
                                titleVisibility: .visible) {
                Button("Tạo khóa mới", role: .destructive) { loadPairing(renew: true) }
            }
        }
    }

    private func loadPairing(renew: Bool = false) {
        do {
            pairingKey = try receiver.pairingCode(renew: renew)
            pairingError = ""
        } catch {
            pairingError = error.localizedDescription
        }
    }

    private func milliseconds(_ value: Double) -> String {
        String(format: "%.1f ms", value)
    }

    private func metric(_ title: String, _ value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Text(value).monospacedDigit().fixedSize()
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).foregroundStyle(.secondary)
                Text(value).monospacedDigit()
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }
}

private enum GlassTheme {
    static let mint = Color(red: 0.67, green: 0.94, blue: 0.88)
    static let lilac = Color(red: 0.76, green: 0.69, blue: 0.98)
}

private struct GlassBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                band(GlassTheme.mint, size: proxy.size, offset: -0.28, alignment: .topLeading)
                band(GlassTheme.lilac, size: proxy.size, offset: 0.24, alignment: .bottomTrailing)
            }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func band(_ color: Color, size: CGSize, offset: CGFloat, alignment: Alignment) -> some View {
        Capsule()
            .fill(
                LinearGradient(colors: [.clear, color.opacity(0.28), color.opacity(0.13), .clear],
                               startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: max(size.width * 1.9, 500), height: 142)
            .rotationEffect(.degrees(-29))
            .blur(radius: 55)
            .offset(x: size.width * offset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
    }
}

private struct GlassPanel: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        if reduceTransparency {
            content.background(Color(white: 0.12), in: shape)
                .overlay { shape.strokeBorder(Color.white.opacity(0.24)).allowsHitTesting(false) }
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                fallback(content, shape: shape)
            }
            #else
            fallback(content, shape: shape)
            #endif
        }
    }

    private func fallback(_ content: Content, shape: RoundedRectangle) -> some View {
        content
            .background(.thinMaterial, in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.25), .white.opacity(0.07)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .allowsHitTesting(false)
            }
    }
}

private extension View {
    func glassPanel(radius: CGFloat) -> some View {
        modifier(GlassPanel(radius: radius))
    }
}
