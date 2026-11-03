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
    @State private var toolRowWidth: CGFloat = 0
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
            .toolbar {
                leadingToolbar
                trailingToolbar
            }
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
                .overlay(alignment: .bottom) {
                    if selecting {
                        selectionPill.transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: selecting)
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

    fileprivate static let slot: CGFloat = 44
    fileprivate static let minSlot: CGFloat = 24
    fileprivate static let groupGap: CGFloat = 16
    fileprivate static let inset: CGFloat = 8
    fileprivate static let statusWidth: CGFloat = 72
    fileprivate static let pillSegmentWidth: CGFloat = 72
    fileprivate static let pillSegmentHeightVertical: CGFloat = 56
    fileprivate static let pillWidth: CGFloat = 2 * pillSegmentWidth + 6

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

    private var barState: EditorBarState {
        EditorBarState(mode: model.mode, recording: model.recording, startingRecording: model.startingRecording, transcribing: model.transcribing, voiceLoading: model.voice.loading, selecting: selecting, hasImage: model.image != nil, hasWindows: !model.windows.isEmpty, canUndo: model.canUndo, canRedo: model.canRedo, replayAvailable: model.replayAvailable)
    }

    @ToolbarContentBuilder private var leadingToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            barButton("Settings", "gearshape") { flow.showSettings = true }
        }
        ToolbarItem(placement: .topBarLeading) {
            barButton("History", "sidebar.left") { showHistory.toggle() }
        }
        .visibility(.low)
        ToolbarItem(placement: .principal) {
            if ToolRowLayout.layout(forWidth: toolRowWidth) == .oneRowWithPill {
                Color.clear.frame(width: 0, height: Self.slot)
            } else {
                modePicker
            }
        }
        .visibility(.high)
    }

    @ToolbarContentBuilder private var trailingToolbar: some ToolbarContent {
        let state = barState
        ToolbarItem(placement: .topBarTrailing) {
            micButton(state)
        }
        .visibility(.high)
        ToolbarItem(placement: .topBarTrailing) {
            barButton("Replay", "play.circle", titled: true) { Task { replay = await model.replaySourceForCurrent() } }
                .disabled(!EditorBarItem.replay.isEnabled(state))
        }
        ToolbarItem(placement: .topBarTrailing) {
            barButton("Crop", "crop", titled: true) { startCrop() }
                .disabled(!EditorBarItem.crop.isEnabled(state))
        }
        .visibility(.low)
        ToolbarItem(placement: .topBarTrailing) {
            barButton("Window", "macwindow", titled: true) { startWindowSelection() }
                .disabled(!EditorBarItem.window.isEnabled(state))
        }
        .visibility(.low)
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            barButton("Undo", "arrow.uturn.backward") { model.undo() }
                .disabled(!EditorBarItem.undo.isEnabled(state))
        }
        .visibility(.high)
        ToolbarItem(placement: .topBarTrailing) {
            barButton("Redo", "arrow.uturn.forward") { model.redo() }
                .disabled(!EditorBarItem.redo.isEnabled(state))
        }
        .visibility(.high)
        ToolbarSpacer(.fixed, placement: .topBarTrailing)
        ToolbarItem(placement: .topBarTrailing) {
            barButton("New", "plus.viewfinder", titled: true) { Task { await model.newCapture() } }
        }
        .visibility(.high)
    }

    private var selectionPill: some View {
        HStack(spacing: 8) {
            Button("Cancel", systemImage: "xmark.circle") { cropping = false; selectingWindow = false; cropDraft = nil }
            Button("Done", systemImage: "checkmark.circle") {
                if let cropDraft {
                    model.applyCrop(cropDraft)
                }
                cropping = false
                selectingWindow = false
            }
        }
        .buttonStyle(.bordered)
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, 12)
    }

    private func micButton(_ state: EditorBarState) -> some View {
        let busy = state.startingRecording || state.transcribing || state.voiceLoading
        return Button {
            Task { await model.toggleRecording() }
        } label: {
            Image(systemName: state.recording ? "stop.circle.fill" : "mic")
                .opacity(busy ? 0.35 : 1)
                .frame(width: Self.slot, height: Self.slot)
                .overlay(alignment: .topTrailing) {
                    if busy {
                        ProgressView().controlSize(.mini).frame(maxWidth: 16, maxHeight: 16).accessibilityHidden(true)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: busy)
                .animation(.easeOut(duration: 0.15), value: state.recording)
        }
        .tint(state.recording ? .red : nil)
        .disabled(!EditorBarItem.mic.isEnabled(state))
        .accessibilityLabel(state.recording ? "Stop recording" : "Record voice")
        .accessibilityHint(state.mode == .note ? "" : "Switch to Note to record")
        .accessibilityValue(state.transcribing ? "Transcribing" : busy ? "Preparing voice model" : "")
    }

    private var modePicker: some View {
        let locked = !EditorBarItem.mode.isEnabled(barState)
        return BarAxis { vertical in
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 0)) : AnyLayout(HStackLayout(spacing: 0))
            layout {
                modeSegment("Draw", .draw, vertical: vertical)
                modeSegment("Note", .note, vertical: vertical)
            }
            .padding(vertical ? EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0) : EdgeInsets(top: 0, leading: 3, bottom: 0, trailing: 3))
            .background(Color.secondary.opacity(0.15), in: Capsule())
            .fixedSize()
        }
        .disabled(locked)
        .opacity(locked ? 0.5 : 1)
        .animation(.easeOut(duration: 0.15), value: locked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drawing mode")
    }

    private func modeSegment(_ title: String, _ mode: EditorMode, vertical: Bool) -> some View {
        let selected = model.mode == mode
        return Button { model.mode = mode } label: {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .frame(width: vertical ? Self.slot : Self.pillSegmentWidth, height: vertical ? Self.pillSegmentHeightVertical : Self.slot)
                .background(selected ? Color.accentColor : .clear, in: Capsule())
                .contentShape(Capsule())
                .animation(.easeOut(duration: 0.15), value: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) mode")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var toolRow: some View {
        VStack(spacing: 0) {
            switch ToolRowLayout.layout(forWidth: toolRowWidth) {
            case .oneRow, .oneRowWithPill:
                HStack(spacing: 0) {
                    HStack(spacing: 0) {
                        if ToolRowLayout.layout(forWidth: toolRowWidth) == .oneRowWithPill {
                            modePicker
                            divider
                        }
                        toolsGroup
                        divider
                        colorsGroup
                        divider
                        widthsGroup
                    }
                    .frame(maxWidth: .infinity)
                    statusSlot
                }
                .frame(height: Self.slot)
            case .twoRows:
                HStack(spacing: 0) {
                    toolsGroup
                    divider
                    colorsGroup
                }
                .padding(.horizontal, Self.inset)
                .frame(maxWidth: .infinity)
                .frame(height: Self.slot)
                HStack(spacing: 0) {
                    widthsGroup
                    statusSlot
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.slot)
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { toolRowWidth = $0 }
    }

    private var statusSlot: some View {
        statusCapsule.padding(.horizontal, Self.inset)
    }

    private var toolsGroup: some View {
        toolGroup {
            ForEach(DrawTool.allCases, id: \.self) { tool in
                Button { model.setTool(tool) } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(model.tool == tool ? Color.accentColor : Color.secondary)
                        .frame(minWidth: Self.minSlot, maxWidth: Self.slot, minHeight: Self.slot, maxHeight: Self.slot)
                        .background(model.tool == tool ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(tool.title)
                .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
            }
        }
    }

    private var colorsGroup: some View {
        toolGroup {
            ForEach(InkColor.allCases, id: \.self) { ink in
                Button { model.setInkColor(ink) } label: {
                    Circle().fill(Color(ink.color))
                        .frame(width: 24, height: 24)
                        .overlay(Circle().stroke(Color.primary, lineWidth: model.inkColor == ink ? 3 : 0))
                        .frame(minWidth: Self.minSlot, maxWidth: Self.slot, minHeight: Self.slot, maxHeight: Self.slot)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Color \(ink.rawValue)")
                .accessibilityAddTraits(model.inkColor == ink ? .isSelected : [])
            }
            .disabled(model.tool == .eraser)
        }
    }

    private var widthsGroup: some View {
        toolGroup {
            ForEach(Array(EditorModel.lineWidths.enumerated()), id: \.element) { index, width in
                Button { model.setLineWidth(width) } label: {
                    Circle().fill(model.lineWidth == width ? Color.accentColor : Color.secondary)
                        .frame(width: CGFloat(6 + index * 4), height: CGFloat(6 + index * 4))
                        .frame(minWidth: Self.minSlot, maxWidth: Self.slot, minHeight: Self.slot, maxHeight: Self.slot)
                        .background(model.lineWidth == width ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Line width \(index + 1)")
                .accessibilityAddTraits(model.lineWidth == width ? .isSelected : [])
            }
            .disabled(model.tool == .eraser)
        }
    }

    private func toolGroup(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: 0, content: content)
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
        .frame(maxWidth: Self.statusWidth, minHeight: 22, maxHeight: 22)
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

enum ToolRowLayout {
    case oneRowWithPill, oneRow, twoRows

    static let oneRowWidth: CGFloat = 13 * EditorView.slot + 2 * EditorView.groupGap + EditorView.statusWidth + 2 * EditorView.inset
    static let oneRowWithPillWidth: CGFloat = oneRowWidth + EditorView.pillWidth + EditorView.groupGap

    static func layout(forWidth width: CGFloat) -> ToolRowLayout {
        if width >= oneRowWithPillWidth {
            return .oneRowWithPill
        }
        return width >= oneRowWidth ? .oneRow : .twoRows
    }
}

struct AdaptiveLabelStyle: LabelStyle {
    let showsTitle: Bool

    func makeBody(configuration: Configuration) -> some View {
        if showsTitle {
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

enum EditorBarItem: CaseIterable {
    case settings, history, mode, mic, replay, crop, window, undo, redo, new

    static func items(for _: EditorBarState) -> [EditorBarItem] {
        allCases
    }

    func isEnabled(_ state: EditorBarState) -> Bool {
        switch self {
        case .mic: state.mode == .note && !state.startingRecording && !state.transcribing
        case .replay: state.replayAvailable
        case .crop: state.hasImage && !state.selecting
        case .window: state.hasImage && state.hasWindows && !state.selecting
        case .undo: state.canUndo
        case .redo: state.canRedo
        case .mode: !(state.recording || state.startingRecording || state.transcribing)
        case .settings, .history, .new: true
        }
    }
}

struct EditorBarState {
    var mode: EditorMode = .draw
    var recording = false
    var startingRecording = false
    var transcribing = false
    var voiceLoading = false
    var selecting = false
    var hasImage = true
    var hasWindows = true
    var canUndo = false
    var canRedo = false
    var replayAvailable = false
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
