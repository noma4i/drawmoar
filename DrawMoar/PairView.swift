import AVFoundation
import CompanionKit
import SwiftUI
import VisionKit

@MainActor @Observable final class PairingFlow {
    var error: String?
    var busy = false
    var showSettings = false
    private let deviceId: () throws -> String
    private let connect: (PairingInvite, String) async throws -> Pairing
    private let save: (Pairing) throws -> Void

    init(deviceId: @escaping () throws -> String = PairingStore.deviceId, connect: @escaping (PairingInvite, String) async throws -> Pairing, save: @escaping (Pairing) throws -> Void = PairingStore.save) {
        self.deviceId = deviceId
        self.connect = connect
        self.save = save
    }

    static func invite(from url: URL) throws -> PairingInvite {
        guard let invite = PairingInvite(url: url) else { throw MacError.invalidInvite }
        return invite
    }

    @discardableResult func pair(url: URL, paired: (Pairing) async -> Void = { _ in }) async -> Pairing? {
        guard !busy else { return nil }
        busy = true
        error = nil
        defer { busy = false }
        do {
            let invite = try Self.invite(from: url)
            let pairing = try await connect(invite, deviceId())
            try save(pairing)
            showSettings = false
            await paired(pairing)
            return pairing
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }
}

extension PairingFlow {
    convenience init(browser: MacBrowser) {
        self.init { invite, id in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(10))
            while clock.now < deadline {
                if let mac = browser.macs.first(where: { $0.name == invite.macName }) {
                    return try await MacClient.pair(mac: mac, invite: invite, deviceId: id)
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw MacError.unavailable
        }
    }
}

struct PairView: View {
    let paired: (Pairing) async -> Void
    @Bindable var flow: PairingFlow
    @State private var link = ""
    @State private var scanning = false

    var body: some View {
        Form {
            Section {
                Text("On your Mac: ClipMoar -> Settings -> Companion -> Pair device")
                if DataScannerViewController.isSupported, AVCaptureDevice.default(for: .video) != nil {
                    Button {
                        Task {
                            if await AVCaptureDevice.requestAccess(for: .video), DataScannerViewController.isAvailable {
                                scanning = true
                            } else {
                                flow.error = "Camera unavailable. Allow camera access in Settings or paste the pairing link."
                            }
                        }
                    } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .disabled(flow.busy)
                }
                TextField("Paste pairing link", text: $link)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Pair") { submit(link) }
                    .disabled(link.isEmpty || flow.busy)
                if flow.busy {
                    ProgressView()
                }
                if let error = flow.error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Connect to Mac")
        .sheet(isPresented: $scanning) {
            QRScanner { value in
                scanning = false
                submit(value)
            }
            .ignoresSafeArea()
        }
    }

    private func submit(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            flow.error = MacError.invalidInvite.localizedDescription
            return
        }
        Task {
            await flow.pair(url: url, paired: paired)
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let scanned: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(scanned: scanned)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], recognizesMultipleItems: false)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_: DataScannerViewController, context _: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let scanned: (String) -> Void
        init(scanned: @escaping (String) -> Void) {
            self.scanned = scanned
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems _: [RecognizedItem]) {
            guard case let .barcode(barcode) = addedItems.first, let value = barcode.payloadStringValue else { return }
            dataScanner.stopScanning()
            scanned(value)
        }
    }
}
