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
    @State private var pickerHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            toolbarButtons.padding(8)
            if let error = model.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(4)
            }
            if let image = model.image {
                DrawingSurface(image: image, drawing: $model.drawing, crop: $model.crop, cropping: cropping, canvas: canvas, lineWidth: model.lineWidth, pickerHeight: $pickerHeight)
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomBar.padding(.bottom, pickerHeight).background(.regularMaterial)
        }
        .overlay(alignment: .top) {
            if showCopied {
                Text("Copied on Mac").fixedSize(horizontal: false, vertical: true)
                    .padding().background(.regularMaterial, in: Capsule()).padding()
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
                        .frame(width: 32, height: 44)
                        .background(model.lineWidth == width ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                }
                .accessibilityLabel("Line width \(index + 1)")
                .accessibilityAddTraits(model.lineWidth == width ? .isSelected : [])
            }
            Spacer(minLength: 4)
            Button { Task { await model.copy() } } label: {
                HStack {
                    if model.sending {
                        ProgressView()
                    } else {
                        Image(systemName: "doc.on.doc")
                    }
                    Text("Copy to Mac")
                }
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .shadow(radius: 3, y: 2)
            .disabled(model.image == nil || model.busy)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
