import PencilKit
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    let browser: MacBrowser
    @Bindable var flow: PairingFlow
    let paired: (Pairing) async -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var cropping = false
    @State private var cropDraft: CGRect?
    @State private var showHistory = false
    @State private var canvas = PKCanvasView()
    @State private var settingsChanged = false

    var body: some View {
        HStack(spacing: 0) {
            if sizeClass == .regular, showHistory {
                historyList.frame(width: 280)
                Divider()
            }
            editor
        }
        .sensoryFeedback(.success, trigger: model.copied)
        .task {
            UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
            if model.pairing == nil {
                flow.showSettings = true
            } else if !flow.busy {
                await model.activate()
            }
        }
        .sheet(isPresented: $flow.showSettings, onDismiss: {
            if settingsChanged {
                settingsChanged = false
                if !flow.busy {
                    Task { await model.activate() }
                }
            }
        }) {
            SettingsView(model: model, browser: browser, flow: flow, paired: paired, changed: $settingsChanged)
        }
        .sheet(isPresented: Binding(get: { showHistory && sizeClass != .regular }, set: { showHistory = $0 })) {
            NavigationStack { historyList.navigationTitle("History").toolbar { Button("Done") { showHistory = false } } }
        }
        .onChange(of: scenePhase) {
            UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
            if scenePhase == .active, !flow.busy {
                Task { await model.activate() }
            }
        }
        .onChange(of: browser.macs) {
            if model.image == nil, !flow.busy {
                Task { await model.activate() }
            }
        }
    }

    private var historyList: some View {
        List {
            ForEach(model.history) { entry in
                Button {
                    showHistory = false
                    cropping = false
                    Task { await model.select(entry) }
                } label: {
                    HStack {
                        if let data = try? ImageRenderer.png(image: entry.image, drawing: entry.drawing, crop: entry.crop),
                           let thumbnail = UIImage(data: data)
                        {
                            Image(uiImage: thumbnail).resizable().scaledToFit().frame(width: 80, height: 60)
                        }
                        Text(entry.date, style: .time)
                    }
                }
                .swipeActions { Button("Delete", role: .destructive) { model.deleteHistory(entry) } }
            }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            toolbarButtons.padding(8)
            bottomBar.background(.regularMaterial)
            if let error = model.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(4)
            }
            if let image = model.image {
                DrawingSurface(image: image, drawing: $model.drawing, crop: $cropDraft, appliedCrop: model.crop, cropping: cropping, canvas: canvas, lineWidth: model.lineWidth)
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
    }

    private var toolbarButtons: some View {
        HStack(spacing: 8) {
            Button("Settings", systemImage: "gearshape") { flow.showSettings = true }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Settings")
            Spacer(minLength: 0)
            if cropping {
                Button("Cancel") { cropping = false; cropDraft = nil }
                Button("Done") {
                    if let cropDraft {
                        model.applyCrop(cropDraft)
                    }
                    cropping = false
                }
            } else {
                Button("History", systemImage: "sidebar.left") { showHistory.toggle() }
                    .labelStyle(.iconOnly)
                Button("Crop") {
                    if let image = model.image?.cgImage {
                        cropDraft = model.crop ?? CGRect(x: 0, y: 0, width: image.width, height: image.height)
                        cropping = true
                    }
                }
                .disabled(model.image == nil)
                divider
                Button("Undo") {
                    if !model.undoCrop() {
                        canvas.undoManager?.undo()
                    }
                }
                divider
                Button("New") { Task { await model.newCapture() } }
            }
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
