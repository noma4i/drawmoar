import PencilKit
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    let browser: MacBrowser
    @Environment(\.scenePhase) private var scenePhase
    @State private var cropping = false
    @State private var canvas = PKCanvasView()
    @State private var showSettings = false
    @State private var settingsChanged = false

    var body: some View {
        VStack(spacing: 0) {
            toolbarButtons.padding(8)
            bottomBar.background(.regularMaterial)
            if let error = model.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(4)
            }
            if let image = model.image {
                DrawingSurface(image: image, drawing: $model.drawing, crop: $model.crop, cropping: cropping, canvas: canvas, lineWidth: model.lineWidth)
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
        .sensoryFeedback(.success, trigger: model.copied)
        .task {
            UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
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
            UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
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

    private var toolbarButtons: some View {
        HStack(spacing: 8) {
            Button("Settings", systemImage: "gearshape") { showSettings = true }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Settings")
            Spacer(minLength: 0)
            Button("Refresh") { Task { await model.refresh() } }
            divider
            Button("Crop") {
                cropping.toggle()
                if cropping, model.crop == nil, let image = model.image?.cgImage {
                    model.crop = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                }
            }
            .fontWeight(cropping ? .bold : .regular)
            divider
            Button("Undo") { canvas.undoManager?.undo() }
            divider
            Button("New") { cropping = false; Task { await model.newCapture() } }
        }
        .font(.subheadline)
        .buttonStyle(.plain)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var divider: some View {
        Divider().frame(height: 16)
    }

    private var bottomBar: some View {
        HStack(spacing: 4) {
            ForEach(Array(EditorModel.lineWidths.enumerated()), id: \.element) { index, width in
                Button { model.setLineWidth(width) } label: {
                    Circle().fill(model.lineWidth == width ? Color.accentColor : Color.secondary)
                        .frame(width: CGFloat(6 + index * 4), height: CGFloat(6 + index * 4))
                        .frame(width: 44, height: 44)
                        .background(model.lineWidth == width ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                }
                .accessibilityLabel("Line width \(index + 1)")
                .accessibilityAddTraits(model.lineWidth == width ? .isSelected : [])
            }
            Spacer(minLength: 4)
            HStack {
                if model.sending {
                    ProgressView()
                    Text("Sending…")
                } else if model.delivered {
                    Text("On Mac ✓")
                } else {
                    Text("Not sent")
                    if let error = model.sendError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
