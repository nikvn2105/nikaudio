import SwiftUI
import AVKit
import UIKit

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var receiver = AudioReceiver()
    @State private var showPairing = false
    @State private var showDiagnostics = false
    @State private var pendingBufferMs: Double?
    @State private var confirmKeyRenewal = false
    @State private var confirmUSBPairing = false
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
        if receiver.statusMessage.hasPrefix("Lỗi") || receiver.statusMessage.hasPrefix("Đang chờ mở cổng") {
            return receiver.statusMessage
        }
        if receiver.needsAudioRecovery { return "Phát âm thanh đang bị gián đoạn." }
        if receiver.isRunning && receiver.pcIdle { return receiver.mode.rawValue }
        return nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("NiKAudio")
                    .font(AppFont.bold(34, relativeTo: .largeTitle))
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
                            .font(AppFont.bold(17, relativeTo: .headline))
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
        .font(AppFont.regular(17, relativeTo: .body))
        .onChange(of: scenePhase) { phase in
            if phase == .active { receiver.recoverAudioIfNeeded() }
        }
        .sheet(isPresented: $showPairing, onDismiss: { pairingKey = ""; receiver.cancelUSBPairing() }) {
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
                    .font(AppFont.bold(22, relativeTo: .title2))
                    .accessibilityAddTraits(.isHeader)
                if let statusDetail = statusDetail {
                    Text(statusDetail)
                        .font(AppFont.regular(15, relativeTo: .subheadline))
                        .foregroundStyle(.secondary)
                }
                AudioOutputRow(route: receiver.outputRoute)
            }

            Button {
                receiver.toggle()
            } label: {
                Label(receiver.isRunning ? "Dừng nhận âm thanh" : "Bắt đầu nhận âm thanh",
                      systemImage: receiver.isRunning ? "stop.fill" : "play.fill")
                    .font(AppFont.bold(17, relativeTo: .headline))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .padding(.horizontal, 12)
                    .foregroundStyle(Color.black)
                    .background(receiver.isRunning ? Color.white.opacity(0.90) : GlassTheme.mint,
                                in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            if receiver.needsAudioRecovery {
                Button("Khôi phục âm thanh") { receiver.recoverAudio() }
                    .buttonStyle(.bordered)
                    .tint(GlassTheme.mint)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 30)
    }

    private var qualityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chất lượng phát")
                .font(AppFont.bold(17, relativeTo: .headline))
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
            metric("Mức đệm mục tiêu", "\(Int(pendingBufferMs ?? receiver.targetBufferMs)) ms")
                .accessibilityHidden(true)
            Slider(value: bufferSlider, in: AudioRingBuffer.targetRange, step: 1, onEditingChanged: { editing in
                if editing {
                    pendingBufferMs = receiver.targetBufferMs
                } else if let value = pendingBufferMs {
                    receiver.targetBufferMs = value
                    pendingBufferMs = nil
                }
            })
            .tint(GlassTheme.mint)
            .accessibilityLabel("Mức đệm mục tiêu")
            .accessibilityValue("\(Int(pendingBufferMs ?? receiver.targetBufferMs)) mili giây")
            Text("Nếu tiếng bị gãy, hãy tăng dần mức đệm. Mức cao hơn có thể làm âm thanh đến chậm hơn.")
                .font(AppFont.regular(13, relativeTo: .footnote))
                .foregroundStyle(.secondary)
            if receiver.isRunning && receiver.effectiveTargetMs > 0 {
                Text("Mức đệm đang áp dụng: \(milliseconds(receiver.effectiveTargetMs))")
                    .font(AppFont.regular(13, relativeTo: .footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .glassPanel(radius: 24)
    }

    private var bufferSlider: Binding<Double> {
        Binding(
            get: { pendingBufferMs ?? receiver.targetBufferMs },
            set: { value in
                if pendingBufferMs != nil {
                    pendingBufferMs = value
                } else {
                    receiver.targetBufferMs = value
                }
            }
        )
    }

    private func preset(_ title: String, symbol: String, milliseconds: Double) -> some View {
        let selected = receiver.targetBufferMs == milliseconds
        return Button {
            receiver.targetBufferMs = milliseconds
        } label: {
            Label(title, systemImage: symbol)
                .font(AppFont.bold(15, relativeTo: .subheadline))
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
            }
            .padding(.top, 16)
        } label: {
            Label("Chẩn đoán", systemImage: "waveform.path")
                .font(AppFont.bold(17, relativeTo: .headline))
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
                    Text("Dùng cáp USB hoặc chép khóa sang PC qua kênh riêng. Trên Windows, chọn **Ghép đôi từ clipboard** trong cửa sổ hoặc **Pair using key from clipboard** trong khay NiKAudio.")
                        .foregroundStyle(.secondary)
                    Button("Gửi khóa qua cáp") { confirmUSBPairing = true }
                        .buttonStyle(.borderedProminent)
                        .tint(GlassTheme.mint)
                        .foregroundStyle(.black)
                        .disabled(!receiver.isRunning)
                        .confirmationDialog("Chỉ gửi khóa khi iPhone đang cắm cáp vào PC của bạn.",
                                            isPresented: $confirmUSBPairing, titleVisibility: .visible) {
                            Button("Cho phép gửi một lần") { receiver.allowUSBPairing() }
                        }
                    if !receiver.isRunning {
                        Text("Bật nhận âm thanh để ghép đôi qua cáp.").foregroundStyle(.secondary)
                    }
                    if let message = receiver.usbPairingMessage {
                        Text(message).foregroundStyle(.secondary)
                    }
                    if !pairingKey.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Khóa ghép đôi").font(AppFont.bold(17, relativeTo: .headline))
                            Text(pairingKey)
                                .font(AppFont.regular(17, relativeTo: .body))
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
            .font(AppFont.regular(17, relativeTo: .body))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Ghép đôi Wi-Fi")
                        .font(AppFont.bold(17, relativeTo: .headline))
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Xong") { showPairing = false }
                        .font(AppFont.bold(17, relativeTo: .headline))
                        .tint(GlassTheme.mint)
                }
            }
            .confirmationDialog("Khóa cũ trên Windows sẽ mất hiệu lực.", isPresented: $confirmKeyRenewal,
                                titleVisibility: .visible) {
                Button("Tạo khóa mới", role: .destructive) {
                        receiver.cancelUSBPairing()
                        loadPairing(renew: true)
                    }
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
        .font(AppFont.regular(15, relativeTo: .subheadline))
        .accessibilityElement(children: .combine)
    }
}

private struct AudioOutputRow: View {
    let route: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "headphones")
                .foregroundStyle(GlassTheme.mint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Đầu ra âm thanh")
                    .font(AppFont.bold(13, relativeTo: .footnote))
                    .foregroundStyle(.secondary)
                Text(route)
                    .font(AppFont.regular(15, relativeTo: .subheadline))
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 4)
            SystemAudioRoutePicker()
                .frame(width: 48, height: 48)
                .background(GlassTheme.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityLabel("Chọn đầu ra âm thanh")
        }
        .padding(.leading, 13)
        .padding(.trailing, 5)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 17))
    }
}

private struct SystemAudioRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor(GlassTheme.mint)
        picker.activeTintColor = UIColor(GlassTheme.lilac)
        return picker
    }

    func updateUIView(_ picker: AVRoutePickerView, context: Context) {}
}

enum AppFont {
    static func regular(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("BeVietnamPro-Regular", size: size, relativeTo: style)
    }

    static func bold(_ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
        .custom("BeVietnamPro-Bold", size: size, relativeTo: style)
    }
}

enum GlassTheme {
    static let mint = Color(red: 0.67, green: 0.94, blue: 0.88)
    static let lilac = Color(red: 0.76, green: 0.69, blue: 0.98)
}

struct GlassBackdrop: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                band(GlassTheme.mint, width: proxy.size.width)
                    .position(x: proxy.size.width * 0.20, y: proxy.size.height * 0.18)
                band(GlassTheme.lilac, width: proxy.size.width)
                    .position(x: proxy.size.width * 0.80, y: proxy.size.height * 0.83)
            }
            .clipped()
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func band(_ color: Color, width: CGFloat) -> some View {
        Capsule()
            .fill(
                LinearGradient(colors: [.clear, color.opacity(0.28), color.opacity(0.13), .clear],
                               startPoint: .leading, endPoint: .trailing)
            )
            .frame(width: max(width * 1.9, 500), height: 142)
            .rotationEffect(.degrees(-29))
            .blur(radius: 55)
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

extension View {
    func glassPanel(radius: CGFloat) -> some View {
        modifier(GlassPanel(radius: radius))
    }
}
