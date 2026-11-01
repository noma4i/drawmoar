import SwiftUI

struct PairView: View {
    let browser: MacBrowser
    let paired: (Pairing) -> Void
    @State private var selected: Mac?
    @State private var pin = ""
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Macs on your network") {
                    if browser.macs.isEmpty {
                        Text("Looking for Macs...")
                    }
                    ForEach(browser.macs) { mac in
                        Button {
                            selected = mac
                        } label: {
                            HStack {
                                Text(mac.name)
                                Spacer()
                                if selected == mac {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
                Section("Pairing PIN") {
                    TextField("6-digit PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .onChange(of: pin) { pin = String(pin.filter(\.isNumber).prefix(6)) }
                    Button("Pair") { Task { await pair() } }
                        .disabled(selected == nil || pin.count != 6 || busy)
                    if busy {
                        ProgressView()
                    }
                }
                if let error = error ?? browser.error {
                    Text(error).foregroundStyle(.red)
                }
            }
            .navigationTitle("Connect to Mac")
        }
    }

    private func pair() async {
        guard let selected else { return }
        busy = true
        defer { busy = false }
        do {
            let pairing = try await MacClient.pair(mac: selected, pin: pin)
            try PairingStore.save(pairing)
            paired(pairing)
        } catch { self.error = error.localizedDescription }
    }
}
