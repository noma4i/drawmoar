import SwiftUI

@main struct CompanionApp: App {
    @State private var browser = MacBrowser()
    @State private var model: EditorModel?
    @State private var storeError: String?

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
                do {
                    let pairing = try PairingStore.load()
                    let client = pairing.map { MacClient(pairing: $0, browser: browser) }
                    model = EditorModel(client: client, pairing: pairing)
                } catch { storeError = error.localizedDescription }
            }
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
