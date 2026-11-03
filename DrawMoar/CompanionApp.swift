import SwiftUI

@main struct CompanionApp: App {
    @State private var browser = MacBrowser()
    @State private var flow: PairingFlow
    @State private var model: EditorModel?
    @State private var storeError: String?
    @State private var pairingError: String?

    init() {
        let browser = MacBrowser()
        _browser = State(initialValue: browser)
        _flow = State(initialValue: PairingFlow(browser: browser))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    EditorView(model: model, browser: browser, flow: flow, paired: paired)
                } else {
                    ProgressView()
                }
            }
            .preferredColorScheme(model?.appearance.colorScheme)
            .task {
                guard model == nil else { return }
                do {
                    let pairing = try PairingStore.load()
                    let client = pairing.map { MacClient(pairing: $0, browser: browser) }
                    model = EditorModel(client: client, pairing: pairing)
                } catch { storeError = error.localizedDescription }
            }
            .task(id: model == nil) {
                await model?.voice.prepare()
            }
            .onOpenURL { url in
                Task {
                    if url.scheme == "drawmoar", url.host == "import" {
                        await model?.activate()
                        return
                    }
                    guard await flow.pair(url: url, paired: paired) != nil else {
                        pairingError = flow.error
                        return
                    }
                }
            }
            .alert("Pairing", isPresented: Binding(get: { pairingError != nil }, set: {
                if !$0 {
                    pairingError = nil
                }
            })) {
                Button("OK") { pairingError = nil }
            } message: { Text(pairingError ?? "") }
            .alert("Keychain error", isPresented: Binding(get: { storeError != nil }, set: {
                if !$0 {
                    storeError = nil
                }
            })) {
                Button("OK") { storeError = nil }
            } message: { Text(storeError ?? "") }
        }
    }

    private func paired(_ pairing: Pairing) async {
        if model == nil {
            model = EditorModel(client: nil)
        }
        model?.setPairing(pairing, browser: browser)
        if model?.imported == true {
            await model?.sendImportedAfterPairing()
        } else {
            await model?.newCapture()
        }
    }
}
