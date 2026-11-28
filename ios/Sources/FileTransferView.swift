import SwiftUI
import UniformTypeIdentifiers

struct FileTransferView: View {
    @AppStorage("fileTransferPCAddress") private var address = ""
    @AppStorage("pairedPCService") private var preferredPC = ""
    @State private var chooseFile = false
    @State private var active: Task<Void, Never>?
    @State private var state = "Kết nối cùng Wi-Fi và ghép đôi với PC trước khi truyền tệp."
    @State private var progress: FileTransfer.Progress?
    @State private var received: URL?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Truyền tệp").font(AppFont.bold(34, relativeTo: .largeTitle))
                    .accessibilityAddTraits(.isHeader)
                VStack(alignment: .leading, spacing: 14) {
                    Text("Máy tính Windows").font(AppFont.bold(17, relativeTo: .headline))
                    TextField("Tự tìm PC hoặc nhập IPv4", text: $address)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .disabled(active != nil)
                    if !preferredPC.isEmpty {
                        Text(preferredPC).foregroundStyle(.secondary)
                    }
                    Button { chooseFile = true } label: { Label("Chọn tệp từ iPhone", systemImage: "arrow.up.doc") }
                        .buttonStyle(.borderedProminent)
                        .tint(GlassTheme.mint)
                        .foregroundStyle(Color.black)
                        .disabled(active != nil)
                    Button { begin(upload: nil) } label: { Label("Tải tệp đã chọn trên PC", systemImage: "arrow.down.doc") }
                        .buttonStyle(.bordered)
                        .tint(GlassTheme.mint)
                        .disabled(active != nil)
                    if let progress = progress, progress.total > 0 {
                        ProgressView(value: Double(progress.completed), total: Double(progress.total))
                        Text(String(format: "%.1f MiB/s", progress.bytesPerSecond / 1_048_576))
                            .monospacedDigit()
                    } else if active != nil {
                        ProgressView()
                    }
                    Text(state).foregroundStyle(.secondary)
                    if let received = received {
                        ShareLink(item: received) { Label("Chia sẻ tệp đã nhận", systemImage: "square.and.arrow.up") }
                    }
                    if let task = active {
                        Button("Dừng truyền", role: .cancel) { task.cancel() }
                    }
                }
                .padding(20)
                .glassPanel(radius: 24)
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .font(AppFont.regular(16, relativeTo: .body))
        .background(GlassBackdrop())
        .fileImporter(isPresented: $chooseFile, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let file): begin(upload: file)
            case .failure(let error): state = error.localizedDescription
            }
        }
    }

    private func begin(upload: URL?) {
        guard active == nil else { return }
        let host = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let key: Data
        do { key = try LANPairing.key() }
        catch {
            state = error.localizedDescription
            return
        }
        let preferred = preferredPC
        received = nil
        progress = nil
        state = "Đang chuẩn bị truyền tệp…"
        active = Task { @MainActor in
            let worker = Task.detached(priority: .userInitiated) {
                let update: @Sendable (FileTransfer.Progress) -> Void = { value in
                    Task { @MainActor in
                        guard active != nil else { return }
                        progress = value
                        state = "Đang truyền tệp…"
                    }
                }
                let pc = try await PairedPC.find(address: host, preferred: preferred, key: key)
                if let name = pc.name {
                    await MainActor.run { preferredPC = name }
                }
                if let upload = upload {
                    try await FileTransfer.upload(upload, endpoint: pc.endpoint, key: key, progress: update)
                    return Optional<URL>.none
                }
                return try await FileTransfer.download(endpoint: pc.endpoint, key: key, progress: update)
            }
            defer { active = nil }
            do {
                received = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                 onCancel: { worker.cancel() })
                state = received == nil ? "Đã gửi tệp sang Windows." : "Đã lưu tệp trên iPhone."
            } catch {
                state = Task.isCancelled
                    ? "Đã dừng. Chọn lại cùng tệp hoặc tải lại để tiếp tục."
                    : error.localizedDescription
            }
        }
    }
}
