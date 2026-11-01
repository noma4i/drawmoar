import SwiftUI

@main struct CompanionApp: App {
    @State private var browser = MacBrowser()
    @State private var model: EditorModel?
    @State private var storeError: String?
    @State private var pairingError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let model {
                    EditorView(model: model, browser: browser)
                } else {
                    ProgressView()
                }
            }
            .task {
                guard model == nil else { return }
                do {
                    let pairing = try PairingStore.load()
                    let client = pairing.map { MacClient(pairing: $0, browser: browser) }
                    model = EditorModel(client: client, pairing: pairing)
                } catch { storeError = error.localizedDescription }
            }
            .onOpenURL { url in
                Task {
                    let flow = PairingFlow(browser: browser)
                    guard let pairing = await flow.pair(url: url) else {
                        pairingError = flow.error
                        return
                    }
                    if model == nil {
                        model = EditorModel(client: nil)
                    }
                    model?.setPairing(pairing, browser: browser)
                    await model?.refresh()
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
}
