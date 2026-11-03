import SwiftUI

struct SettingsView: View {
    @Bindable var model: EditorModel
    let browser: MacBrowser
    let flow: PairingFlow
    let paired: (Pairing) async -> Void
    @Binding var changed: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var pairing = false
    @State private var confirmDelete = false

    private var voiceStatus: String {
        guard model.voice.installed else { return "Not downloaded" }
        if model.voice.loading {
            return "Preparing..."
        }
        return model.voice.engine == .apple ? "Installed" : ByteCountFormatter.string(fromByteCount: model.voice.size, countStyle: .file)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Voice") {
                    Picker("Engine", selection: Binding(get: { model.voice.engine }, set: { value in
                        model.voice.select(value)
                        Task { await model.voice.prepare() }
                    })) {
                        ForEach(VoiceEngine.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    if model.voice.engine == .apple {
                        Picker("Language", selection: Binding(get: { model.voice.language }, set: { value in
                            model.voice.setLanguage(value)
                            Task { await model.voice.prepare() }
                        })) {
                            ForEach(model.voice.appleLanguages, id: \.self) { Text(Locale.current.localizedString(forIdentifier: $0) ?? $0).tag($0) }
                        }
                    }
                    LabeledContent(model.voice.engine.title, value: voiceStatus)
                    if let progress = model.voice.progress {
                        let text = DownloadText(fraction: progress.fraction, phaseText: progress.phase, downloaded: model.voice.size, total: nil)
                        ProgressView(value: progress.fraction) {
                            Text("\(text.phase) - \(text.percent)")
                        } currentValueLabel: {
                            Text(model.voice.engine == .apple ? "" : text.bytes)
                        }
                        Button("Cancel") { model.voice.cancel() }
                    } else if model.voice.installed {
                        if model.voice.engine != .apple {
                            Button("Delete", role: .destructive) { model.voice.delete() }
                        }
                    } else {
                        Button("Download") { model.voice.download() }
                    }
                    if let error = model.voice.error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section("Storage") {
                    LabeledContent("Screenshots", value: "\(model.history.count) - \(ByteCountFormatter.string(fromByteCount: model.storageSize, countStyle: .file))")
                    Picker("Keep screenshots", selection: $model.retention) {
                        Text("Day").tag(Retention.day)
                        Text("Week").tag(Retention.week)
                        Text("Month").tag(Retention.month)
                        Text("Forever").tag(Retention.forever)
                    }
                    .onChange(of: model.retention) { Task { await model.pruneHistoryAfterSave() } }
                    Button("Delete all screenshots", role: .destructive) { confirmDelete = true }
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $model.appearance) {
                        Text("System").tag(Appearance.system)
                        Text("Light").tag(Appearance.light)
                        Text("Dark").tag(Appearance.dark)
                    }
                }
                Section("Mac") {
                    if let mac = model.pairing {
                        Text(mac.macName)
                        TextField("Remote address", text: Binding(get: { browser.remoteAddress(for: mac.macName) }, set: {
                            browser.setRemoteAddress($0, for: mac.macName)
                            changed = true
                        }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        if let route = browser.connectedRoute(for: mac.macName) {
                            Text("Connected via \(route)").font(.caption).foregroundStyle(.secondary)
                        }
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
                    .pickerStyle(.navigationLink)
                    .onChange(of: model.selectedDisplay) { changed = true }
                    if let error = model.displayError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Delete all screenshots?", isPresented: $confirmDelete) {
                Button("Delete all screenshots", role: .destructive) { Task { await model.deleteAllHistory() } }
            }
            .toolbar { Button("Done") { dismiss() } }
            .navigationDestination(isPresented: $pairing) {
                PairView(paired: paired, flow: flow)
            }
        }
        .task {
            await model.voice.refreshApple()
            model.updateStorageSize()
            await model.loadDisplays()
            if model.pairing == nil {
                pairing = true
            }
        }
    }
}
