import SwiftUI

@main struct CompanionApp: App {
    @State private var browser = MacBrowser()
    @State private var pairing: Pairing?
    @State private var storeError: String?

    var body: some Scene {
        WindowGroup {
            Group {
                if let pairing {
                    EditorRoot(pairing: pairing, browser: browser)
                } else {
                    PairView(browser: browser) { pairing = $0 }
                }
            }
            .task {
                do { pairing = try PairingStore.load() } catch { storeError = error.localizedDescription }
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

struct EditorRoot: View {
    @State private var model: EditorModel
    let browser: MacBrowser
    init(pairing: Pairing, browser: MacBrowser) {
        self.browser = browser
        _model = State(initialValue: EditorModel(client: MacClient(pairing: pairing, browser: browser)))
    }

    var body: some View {
        EditorView(model: model, browser: browser)
    }
}
