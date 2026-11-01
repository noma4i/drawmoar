import PencilKit
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    let browser: MacBrowser
    @Environment(\.scenePhase) private var scenePhase
    @State private var cropping = false
    @State private var showCopied = false
    @State private var canvas = PKCanvasView()
    @State private var showSettings = false
    @State private var settingsChanged = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                HStack {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    Button("Crop", systemImage: "crop") {
                        cropping.toggle()
                        if cropping, model.crop == nil, let image = model.image?.cgImage {
                            model.crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                        }
                    }
                    Button("Undo", systemImage: "arrow.uturn.backward") { canvas.undoManager?.undo() }
                    Button("New", systemImage: "plus") { cropping = false; Task { await model.newCapture() } }
                    Button("Copy to Mac", systemImage: "doc.on.doc") { Task { await model.copy() } }
                        .disabled(model.image == nil || model.busy)
                    Button("Settings", systemImage: "gearshape") { showSettings = true }
                        .labelStyle(.iconOnly)
                }.padding(8)
            }
            if let error = model.error {
                Text(error).foregroundStyle(.red).padding(4)
            }
            if let image = model.image {
                DrawingSurface(image: image, drawing: $model.drawing, crop: $model.crop, cropping: cropping, canvas: canvas)
            } else {
                Spacer()
                if model.busy {
                    ProgressView()
                } else {
                    Text("Waiting for a screenshot")
                }
                Spacer()
            }
        }
        .overlay(alignment: .bottom) {
            if showCopied {
                Text("Copied on Mac").padding().background(.regularMaterial, in: Capsule()).padding()
            }
        }
        .sensoryFeedback(.success, trigger: model.copied)
        .onChange(of: model.copied) {
            showCopied = true
            Task { try? await Task.sleep(for: .seconds(2)); showCopied = false }
        }
        .task {
            if model.pairing == nil {
                showSettings = true
            } else {
                await model.activate()
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            if settingsChanged {
                settingsChanged = false
                Task { await model.activate() }
            }
        }) {
            SettingsView(model: model, browser: browser, changed: $settingsChanged)
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                Task { await model.activate() }
            }
        }
        .onChange(of: browser.macs) {
            if model.image == nil {
                Task { await model.activate() }
            }
        }
    }
}
