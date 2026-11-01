import SwiftUI

struct SettingsView: View {
    @Bindable var model: EditorModel
    let browser: MacBrowser
    @Binding var changed: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac") {
                    if let mac = model.pairing {
                        LabeledContent(mac.macName, value: browser.macs.contains(where: { $0.name == mac.macName }) ? "Available" : "Unavailable")
                        Button("Pair with another Mac") { pairing = true }
                        Button("Forget this Mac", role: .destructive) {
                            model.forgetMac()
                            if model.pairing == nil {
                                changed = true; pairing = true
                            }
                        }
                    } else {
                        Text("Pair a Mac to capture its screen")
                        Button("Pair with a Mac") { pairing = true }
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section("Screen") {
                    Picker("Screen", selection: $model.selectedDisplay) {
                        Text("Auto (screen under cursor)").tag(UInt32?.none)
                        ForEach(model.displays, id: \.id) { display in
                            Text("\(display.name) - \(display.width) x \(display.height)\(display.isMain ? " - Main" : "")")
                                .tag(Optional(display.id))
                        }
                    }
                    .pickerStyle(.inline)
                    .onChange(of: model.selectedDisplay) { changed = true }
                }
            }
            .navigationTitle("Settings")
            .toolbar { Button("Done") { dismiss() } }
            .navigationDestination(isPresented: $pairing) {
                PairView(browser: browser) { pair in
                    model.setPairing(pair, browser: browser)
                    changed = true
                    pairing = false
                }
            }
        }
        .task {
            if model.pairing == nil {
                pairing = true
            }
        }
    }
}
