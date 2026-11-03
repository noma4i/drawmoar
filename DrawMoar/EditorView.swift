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
    @State private var selectingWindow = false
    @State private var cropDraft: CGRect?
    @State private var showHistory = false
    @State private var canvas = PKCanvasView()
    @State private var settingsChanged = false
    @State private var replay: ReplaySource?

    var body: some View {
        HStack(spacing: 0) {
            if sizeClass == .regular, showHistory {
                historyList.frame(width: 280)
                Divider()
            }
            editor
        }
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
        .fullScreenCover(item: $replay) { ReplayView(source: $0) }
        .alert("Parakeet Ultra is not installed", isPresented: $model.showVoiceSettings) {
            Button("Settings") { flow.showSettings = true }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Download it in Settings > Voice.") }
        .onChange(of: scenePhase) {
            UIApplication.shared.isIdleTimerDisabled = scenePhase == .active
            if scenePhase == .background {
                Task { await model.flushHistory() }
            }
            if scenePhase == .active {
                browser.restart()
                Task {
                    await model.pruneHistoryAfterSave()
                    if !flow.busy {
                        await model.activate()
                    }
                }
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
                    selectingWindow = false
                    Task { await model.select(entry) }
                } label: {
                    HStack {
                        if let thumbnail = entry.thumbnail {
                            Image(uiImage: thumbnail).resizable().scaledToFit().frame(width: 80, height: 60)
                        }
                        Text(entry.date, style: .time)
                        if entry.hasTimeline {
                            Image(systemName: "waveform").accessibilityLabel("Voice note")
                        }
                    }
                }
                .swipeActions { Button("Delete", role: .destructive) { Task { await model.deleteHistory(entry) } } }
                .swipeActions(edge: .leading) {
                    if entry.hasTimeline {
                        Button("Replay", systemImage: "play.circle") { openReplay(entry) }.tint(.accentColor)
                    }
                }
                .contextMenu {
                    if entry.hasTimeline {
                        Button("Replay", systemImage: "play.circle") { openReplay(entry) }
                    }
                }
            }
        }
    }

    @ViewBuilder private func transcriptOverlay(image: UIImage) -> some View {
        if model.mode == .note, !model.sessionPhrases.isEmpty {
            GeometryReader { proxy in
                let visible = model.crop ?? CGRect(x: 0, y: 0, width: image.cgImage?.width ?? 1, height: image.cgImage?.height ?? 1)
                let fitted = visible.height * min(proxy.size.width / max(visible.width, 1), proxy.size.height / max(visible.height, 1))
                let free = (proxy.size.height - fitted) / 2
                TranscriptOverlay(phrases: model.sessionPhrases, height: free >= 40 ? min(free - 4, 88) : 52) {
                    if model.replayAvailable {
                        Task { replay = await model.replaySourceForCurrent() }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
        }
    }

    private func openReplay(_ entry: HistoryEntry) {
        showHistory = false
        Task { replay = await model.replaySource(for: entry) }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            toolbarButtons.padding(8)
            VStack(spacing: 0) { bottomBar; statusRow }.background(.regularMaterial)
            if let error = model.error {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true).padding(4)
            }
            if let image = model.image {
                DrawingSurface(image: image, drawing: $model.drawing, crop: $cropDraft, appliedCrop: model.crop, cropping: cropping, selectingWindow: selectingWindow, windows: model.windows, selectWindow: { point, confirm in
                    cropDraft = model.selectWindow(at: point, confirm: confirm)
                    if confirm, cropDraft != nil {
                        selectingWindow = false
                    }
                }, canvas: canvas, tool: EditorModel.pkTool(model.tool, color: model.inkColor, width: model.lineWidth, scale: EditorModel.canvasScale(for: CGSize(width: image.cgImage?.width ?? 1, height: image.cgImage?.height ?? 1))), setUsingTool: model.setUsingTool)
                    .overlay(alignment: .bottom) { transcriptOverlay(image: image) }
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
            Button("History", systemImage: "sidebar.left") { showHistory.toggle() }
                .labelStyle(.iconOnly)
            Button("Replay", systemImage: "play.circle") { Task { replay = await model.replaySourceForCurrent() } }
                .labelStyle(.iconOnly)
                .frame(width: 26, height: 32)
                .opacity(model.replayAvailable ? 1 : 0)
                .disabled(!model.replayAvailable)
                .accessibilityHidden(!model.replayAvailable)
            Picker("Drawing mode", selection: $model.mode) {
                Text("Draw").tag(EditorMode.draw)
                Text("Note").tag(EditorMode.note)
            }
            .pickerStyle(.segmented)
            .frame(width: 108)
            .accessibilityLabel("Drawing mode")
            .disabled(model.recording || model.startingRecording || model.transcribing)
            ZStack {
                if model.transcribing {
                    ProgressView()
                        .accessibilityLabel(model.voice.loading ? "Loading model" : "Transcribing")
                } else {
                    Button(model.recording ? "Stop recording" : "Record voice", systemImage: model.recording ? "stop.circle" : "mic") { Task { await model.toggleRecording() } }
                        .labelStyle(.iconOnly)
                        .disabled(model.startingRecording)
                        .foregroundStyle(model.recording ? Color.red : Color.primary)
                        .overlay(alignment: .topTrailing) {
                            if model.voice.loading {
                                ProgressView()
                                    .controlSize(.mini)
                                    .accessibilityHidden(true)
                                    .transition(.opacity)
                            }
                        }
                        .accessibilityValue(model.voice.loading ? "Preparing voice model" : "")
                }
            }
            .frame(width: 30, height: 32)
            .opacity(model.mode == .note ? 1 : 0)
            .disabled(model.mode != .note)
            .accessibilityHidden(model.mode != .note)
            .animation(.easeOut(duration: 0.15), value: model.recording)
            .animation(.easeOut(duration: 0.15), value: model.transcribing)
            .animation(.easeOut(duration: 0.15), value: model.voice.loading)
            .animation(.easeOut(duration: 0.15), value: model.mode)
            Spacer(minLength: 16)
            if cropping || selectingWindow {
                Button("Cancel") { cropping = false; selectingWindow = false; cropDraft = nil }
                Button("Done") {
                    if let cropDraft {
                        model.applyCrop(cropDraft)
                    }
                    cropping = false
                    selectingWindow = false
                }
            } else {
                Button("Crop") {
                    if let image = model.image?.cgImage {
                        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                        cropDraft = model.crop ?? full.insetBy(dx: full.width * 0.08, dy: full.height * 0.08)
                        cropping = true
                    }
                }
                .disabled(model.image == nil)
                Button("Window", systemImage: "macwindow") {
                    model.resetWindowSelection()
                    cropDraft = nil
                    selectingWindow = true
                }
                .labelStyle(.iconOnly)
                .accessibilityLabel("Window")
                .disabled(model.image == nil || model.windows.isEmpty)
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
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(DrawTool.allCases, id: \.self) { tool in
                    Button { model.setTool(tool) } label: {
                        Image(systemName: tool.symbol)
                            .font(.title3)
                            .foregroundStyle(model.tool == tool ? Color.accentColor : Color.secondary)
                            .frame(width: 44, height: 44)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                    }
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                }
                ForEach(InkColor.allCases, id: \.self) { ink in
                    Button { model.setInkColor(ink) } label: {
                        Circle().fill(Color(ink.color))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.primary, lineWidth: model.inkColor == ink ? 3 : 0))
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Color \(ink.rawValue)")
                    .accessibilityAddTraits(model.inkColor == ink ? .isSelected : [])
                }
                .disabled(model.tool == .eraser)
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
                .disabled(model.tool == .eraser)
            }
            .padding(.horizontal, 8)
        }
        .padding(.vertical, 4)
    }

    private var statusRow: some View {
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
        .frame(minHeight: 20)
        .padding(.horizontal, 8)
    }
}

private extension DrawTool {
    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .marker: "highlighter"
        case .eraser: "eraser"
        }
    }

    var title: String {
        switch self {
        case .pen: "Pen"
        case .marker: "Marker"
        case .eraser: "Eraser"
        }
    }
}
