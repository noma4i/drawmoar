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
        .alert("\(model.voice.engine.title) is not installed", isPresented: $model.showVoiceSettings) {
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
        NavigationStack {
            VStack(spacing: 0) {
                toolRow.background(.regularMaterial)
                canvasArea
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { editorToolbar }
        }
    }

    @ViewBuilder private var canvasArea: some View {
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

    private func startCrop() {
        if let image = model.image?.cgImage {
            let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            cropDraft = model.crop ?? full.insetBy(dx: full.width * 0.08, dy: full.height * 0.08)
            cropping = true
        }
    }

    private func startWindowSelection() {
        model.resetWindowSelection()
        cropDraft = nil
        selectingWindow = true
    }

    private var selecting: Bool {
        cropping || selectingWindow
    }

    private var divider: some View {
        Rectangle().fill(Color.secondary.opacity(0.4))
            .frame(width: 1, height: Self.groupGap)
            .frame(width: Self.groupGap, height: Self.slot)
            .accessibilityHidden(true)
    }

    private static let slot: CGFloat = 44
    private static let groupGap: CGFloat = 16
    private static let itemSpacing: CGFloat = 8
    private static let inset: CGFloat = 8

    private func barButton(_ title: String, _ symbol: String, titled: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            BarAxis { vertical in
                Label(title, systemImage: symbol)
                    .labelStyle(AdaptiveLabelStyle(showsTitle: titled && !vertical))
            }
        }
        .tint(tint)
        .accessibilityLabel(title)
    }

    @ToolbarContentBuilder private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            barButton("Settings", "gearshape") { flow.showSettings = true }
        }
        ToolbarItem(placement: .topBarLeading) {
            barButton("History", "sidebar.left") { showHistory.toggle() }
        }
        .visibility(.low)
        ToolbarItem(placement: .principal) {
            modePicker
        }
        .visibility(.high)
        if selecting {
            ToolbarItem(placement: .cancellationAction) {
                barButton("Cancel", "xmark.circle") { cropping = false; selectingWindow = false; cropDraft = nil }
            }
            .visibility(.high)
            ToolbarItem(placement: .confirmationAction) {
                barButton("Done", "checkmark.circle") {
                    if let cropDraft {
                        model.applyCrop(cropDraft)
                    }
                    cropping = false
                    selectingWindow = false
                }
            }
            .visibility(.high)
        } else {
            if model.mode == .note {
                ToolbarItem(placement: .topBarTrailing) {
                    micButton
                }
                .visibility(.high)
            }
            if model.replayAvailable {
                ToolbarItem(placement: .topBarTrailing) {
                    barButton("Replay", "play.circle", titled: true) { Task { replay = await model.replaySourceForCurrent() } }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                barButton("Crop", "crop", titled: true) { startCrop() }
                    .disabled(model.image == nil)
            }
            .visibility(.low)
            ToolbarItem(placement: .topBarTrailing) {
                barButton("Window", "macwindow", titled: true) { startWindowSelection() }
                    .disabled(model.image == nil || model.windows.isEmpty)
            }
            .visibility(.low)
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                barButton("Undo", "arrow.uturn.backward") { model.undo() }
                    .disabled(!model.canUndo)
            }
            .visibility(.high)
            if model.canRedo {
                ToolbarItem(placement: .topBarTrailing) {
                    barButton("Redo", "arrow.uturn.forward") { model.redo() }
                }
                .visibility(.high)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                barButton("New", "plus.viewfinder", titled: true) { Task { await model.newCapture() } }
            }
            .visibility(.high)
        }
    }

    private var micButton: some View {
        ZStack {
            if model.transcribing {
                ProgressView()
                    .accessibilityLabel(model.voice.loading ? "Loading model" : "Transcribing")
            } else {
                barButton(model.recording ? "Stop recording" : "Record voice", model.recording ? "stop.circle.fill" : "mic", tint: model.recording ? .red : nil) {
                    Task { await model.toggleRecording() }
                }
                .disabled(model.startingRecording)
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
        .animation(.easeOut(duration: 0.15), value: model.recording)
        .animation(.easeOut(duration: 0.15), value: model.transcribing)
        .animation(.easeOut(duration: 0.15), value: model.voice.loading)
    }

    private var modePicker: some View {
        let locked = model.recording || model.startingRecording || model.transcribing
        return BarAxis { vertical in
            Picker("Drawing mode", selection: $model.mode) {
                ForEach([(EditorMode.draw, "scribble.variable", "Draw"), (.note, "waveform", "Note")], id: \.0) { mode, symbol, title in
                    Label(title, systemImage: symbol)
                        .labelStyle(AdaptiveLabelStyle(showsTitle: !vertical, titleOnly: true))
                        .tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: vertical ? 2 * Self.slot : 140)
        }
        .disabled(locked)
    }

    private var toolRow: some View {
        let row = HStack(spacing: 0) {
            toolGroup {
                ForEach(DrawTool.allCases, id: \.self) { tool in
                    Button { model.setTool(tool) } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(model.tool == tool ? Color.accentColor : Color.secondary)
                            .frame(width: Self.slot, height: Self.slot)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                }
            }
            divider
            toolGroup {
                ForEach(InkColor.allCases, id: \.self) { ink in
                    Button { model.setInkColor(ink) } label: {
                        Circle().fill(Color(ink.color))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.primary, lineWidth: model.inkColor == ink ? 3 : 0))
                            .frame(width: Self.slot, height: Self.slot)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Color \(ink.rawValue)")
                    .accessibilityAddTraits(model.inkColor == ink ? .isSelected : [])
                }
                .disabled(model.tool == .eraser)
            }
            divider
            toolGroup {
                ForEach(Array(EditorModel.lineWidths.enumerated()), id: \.element) { index, width in
                    Button { model.setLineWidth(width) } label: {
                        Circle().fill(model.lineWidth == width ? Color.accentColor : Color.secondary)
                            .frame(width: CGFloat(6 + index * 4), height: CGFloat(6 + index * 4))
                            .frame(width: Self.slot, height: Self.slot)
                            .background(model.lineWidth == width ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Line width \(index + 1)")
                    .accessibilityAddTraits(model.lineWidth == width ? .isSelected : [])
                }
                .disabled(model.tool == .eraser)
            }
        }
        .buttonStyle(.plain)
        return HStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                row.frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) { row }
            }
            statusCapsule.padding(.horizontal, Self.inset)
        }
        .padding(.vertical, 4)
    }

    private func toolGroup(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: Self.itemSpacing, content: content)
    }

    private var statusCapsule: some View {
        HStack(spacing: 4) {
            if model.sending {
                ProgressView().controlSize(.mini)
                Text("Sending…")
            } else if model.delivered {
                Text("On Mac ✓")
            } else if let error = model.sendError {
                Text(error).foregroundStyle(.red)
            } else {
                Text("Not sent")
            }
        }
        .font(.caption2)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .padding(.horizontal, 6)
        .frame(maxWidth: 72, minHeight: 22, maxHeight: 22)
        .background(Color.secondary.opacity(0.15), in: Capsule())
        .fixedSize(horizontal: false, vertical: true)
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

struct AdaptiveLabelStyle: LabelStyle {
    let showsTitle: Bool
    var titleOnly = false

    func makeBody(configuration: Configuration) -> some View {
        if titleOnly {
            if showsTitle {
                configuration.title
            } else {
                configuration.icon
            }
        } else if showsTitle {
            HStack(spacing: 6) { configuration.icon; configuration.title }
        } else {
            configuration.icon
        }
    }
}

struct BarAxis<Content: View>: View {
    @ViewBuilder let content: (Bool) -> Content

    var body: some View {
        if #available(iOS 27.1, *) {
            VerticalBarReader(content: content)
        } else {
            content(false)
        }
    }
}

@available(iOS 27.1, *)
private struct VerticalBarReader<Content: View>: View {
    @Environment(\.toolbarVerticalEdge) private var edge
    let content: (Bool) -> Content

    var body: some View {
        content(edge != nil)
    }
}

enum BarVisibility {
    case high, low
}

extension ToolbarContent {
    @ToolbarContentBuilder func visibility(_ level: BarVisibility) -> some ToolbarContent {
        if #available(iOS 27.0, *) {
            visibilityPriority(level == .high ? .high : .low)
        } else {
            self
        }
    }
}
