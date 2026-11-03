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
        GeometryReader { proxy in
            let layout = ToolbarLayout.resolve(width: proxy.size.width, height: proxy.size.height, horizontalSizeClass: sizeClass)
            let rowGroups = ToolbarPlan.rowGroups(availableWidth: proxy.size.width - 2 * ToolbarPlan.inset)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if layout == .topRow {
                        toolbarRow(groups: rowGroups)
                            .frame(maxWidth: .infinity)
                            .padding(ToolbarPlan.inset)
                    }
                    toolRow(layout: layout).background(.regularMaterial)
                    canvasArea
                }
                if layout == .trailingRail {
                    toolbarRail
                }
            }
            .animation(.easeOut(duration: 0.15), value: layout)
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

    private func divider(_ axis: Axis) -> some View {
        Rectangle().fill(Color.secondary.opacity(0.4))
            .frame(width: axis == .horizontal ? 1 : ToolbarPlan.groupGap, height: axis == .horizontal ? ToolbarPlan.groupGap : 1)
            .frame(width: axis == .horizontal ? ToolbarPlan.groupGap : ToolbarPlan.railWidth - 2 * ToolbarPlan.inset,
                   height: axis == .horizontal ? ToolbarPlan.slot : ToolbarPlan.groupGap)
            .accessibilityHidden(true)
    }

    private func stack(_ axis: Axis, spacing: CGFloat) -> AnyLayout {
        axis == .horizontal ? AnyLayout(HStackLayout(spacing: spacing)) : AnyLayout(VStackLayout(spacing: spacing))
    }

    private func toolbarRow(groups: [[ToolbarItem]]) -> some View {
        let visible = Set(groups.flatMap { $0 })
        let layout = stack(.horizontal, spacing: 0)
        return layout {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    divider(.horizontal)
                }
                groupView(group, axis: .horizontal, visible: visible)
            }
        }
        .fixedSize()
    }

    private var toolbarRail: some View {
        let groups = ToolbarPlan.railGroups
        let visible = Set(groups.flatMap { $0 })
        let content = VStack(spacing: 0) {
            ForEach(Array(groups.dropLast().enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    divider(.vertical)
                }
                groupView(group, axis: .vertical, visible: visible)
            }
            Spacer(minLength: ToolbarPlan.groupGap)
            divider(.vertical)
            if let last = groups.last {
                groupView(last, axis: .vertical, visible: visible)
            }
            statusCapsule.padding(.top, 8)
        }
        .padding(.vertical, ToolbarPlan.railVerticalInset)
        .frame(width: ToolbarPlan.railWidth)
        return ViewThatFits(in: .vertical) {
            content
            ScrollView(.vertical, showsIndicators: false) { content }
        }
        .frame(width: ToolbarPlan.railWidth)
        .background(.regularMaterial)
    }

    private func groupView(_ group: [ToolbarItem], axis: Axis, visible: Set<ToolbarItem>) -> some View {
        let layout = stack(axis, spacing: ToolbarPlan.itemSpacing)
        return layout {
            ForEach(group, id: \.self) { item in
                itemView(item, axis: axis, visible: visible)
            }
        }
    }

    private func iconSlot(_ symbol: String, label: String, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: ToolbarPlan.slot, height: ToolbarPlan.slot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func itemView(_ item: ToolbarItem, axis: Axis, visible: Set<ToolbarItem>) -> some View {
        switch item {
        case .settings:
            iconSlot("gearshape", label: "Settings") { flow.showSettings = true }
        case .history:
            iconSlot("sidebar.left", label: "History") { showHistory.toggle() }
        case .mode:
            modePill(axis: axis)
        case .mic:
            micSlot
        case .replay:
            iconSlot("play.circle", label: "Replay") { Task { replay = await model.replaySourceForCurrent() } }
                .opacity(model.replayAvailable ? 1 : 0)
                .disabled(!model.replayAvailable)
                .accessibilityHidden(!model.replayAvailable)
                .animation(.easeOut(duration: 0.15), value: model.replayAvailable)
        case .crop:
            iconSlot("crop", label: "Crop") { startCrop() }
                .disabled(model.image == nil || selecting)
        case .window:
            iconSlot("macwindow", label: "Window") { startWindowSelection() }
                .disabled(model.image == nil || model.windows.isEmpty || selecting)
        case .undo:
            if selecting {
                iconSlot("xmark.circle", label: "Cancel") { cropping = false; selectingWindow = false; cropDraft = nil }
            } else {
                iconSlot("arrow.uturn.backward", label: "Undo") { model.undo() }
                    .disabled(!model.canUndo)
            }
        case .redo:
            if selecting {
                iconSlot("checkmark.circle", label: "Done") {
                    if let cropDraft {
                        model.applyCrop(cropDraft)
                    }
                    cropping = false
                    selectingWindow = false
                }
            } else {
                iconSlot("arrow.uturn.forward", label: "Redo") { model.redo() }
                    .disabled(!model.canRedo)
                    .opacity(model.canRedo ? 1 : 0)
                    .accessibilityHidden(!model.canRedo)
                    .animation(.easeOut(duration: 0.15), value: model.canRedo)
            }
        case .new:
            iconSlot("plus.viewfinder", label: "New") { Task { await model.newCapture() } }
        case .more:
            Menu {
                if !visible.contains(.settings) {
                    Button("Settings", systemImage: "gearshape") { flow.showSettings = true }
                }
                if !visible.contains(.history) {
                    Button("History", systemImage: "sidebar.left") { showHistory.toggle() }
                }
                if !visible.contains(.crop) {
                    Button("Crop", systemImage: "crop") { startCrop() }.disabled(model.image == nil || selecting)
                    Button("Window", systemImage: "macwindow") { startWindowSelection() }
                        .disabled(model.image == nil || model.windows.isEmpty || selecting)
                }
                if !visible.contains(.new) {
                    Button("New", systemImage: "plus.viewfinder") { Task { await model.newCapture() } }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .frame(width: ToolbarPlan.slot, height: ToolbarPlan.slot)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("More")
        }
    }

    private var micSlot: some View {
        ZStack {
            if model.transcribing {
                ProgressView()
                    .accessibilityLabel(model.voice.loading ? "Loading model" : "Transcribing")
            } else {
                iconSlot(model.recording ? "stop.circle.fill" : "mic", label: model.recording ? "Stop recording" : "Record voice", tint: model.recording ? .red : .primary) {
                    Task { await model.toggleRecording() }
                }
                .disabled(model.startingRecording)
                .overlay(alignment: .topTrailing) {
                    if model.voice.loading {
                        ProgressView()
                            .controlSize(.mini)
                            .padding(6)
                            .accessibilityHidden(true)
                            .transition(.opacity)
                    }
                }
                .accessibilityValue(model.voice.loading ? "Preparing voice model" : "")
            }
        }
        .frame(width: ToolbarPlan.slot, height: ToolbarPlan.slot)
        .opacity(model.mode == .note ? 1 : 0)
        .disabled(model.mode != .note)
        .accessibilityHidden(model.mode != .note)
        .animation(.easeOut(duration: 0.15), value: model.recording)
        .animation(.easeOut(duration: 0.15), value: model.transcribing)
        .animation(.easeOut(duration: 0.15), value: model.voice.loading)
        .animation(.easeOut(duration: 0.15), value: model.mode)
    }

    private func modePill(axis: Axis) -> some View {
        let locked = model.recording || model.startingRecording || model.transcribing
        let segments: [(EditorMode, String, String)] = [(.draw, "scribble.variable", "Draw"), (.note, "waveform", "Note")]
        let layout = stack(axis, spacing: 0)
        return layout {
            ForEach(segments, id: \.0) { mode, symbol, label in
                Button { model.mode = mode } label: {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(model.mode == mode ? Color.accentColor : Color.secondary)
                        .frame(width: axis == .horizontal ? ToolbarPlan.slot : ToolbarPlan.pillThickness,
                               height: axis == .horizontal ? ToolbarPlan.pillThickness : ToolbarPlan.slot)
                        .background(model.mode == mode ? Color.accentColor.opacity(0.2) : .clear, in: Capsule())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label)
                .accessibilityAddTraits(model.mode == mode ? .isSelected : [])
            }
        }
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .frame(width: axis == .horizontal ? ToolbarPlan.pillLength : ToolbarPlan.slot,
               height: axis == .horizontal ? ToolbarPlan.slot : ToolbarPlan.pillLength)
        .disabled(locked)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Drawing mode")
    }

    private func toolRow(layout: ToolbarLayout) -> some View {
        let reserve: CGFloat = layout == .topRow ? ToolbarPlan.statusReserve : 0
        let row = HStack(spacing: 0) {
            toolGroup {
                ForEach(DrawTool.allCases, id: \.self) { tool in
                    Button { model.setTool(tool) } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(model.tool == tool ? Color.accentColor : Color.secondary)
                            .frame(width: ToolbarPlan.slot, height: ToolbarPlan.slot)
                            .background(model.tool == tool ? Color.accentColor.opacity(0.15) : .clear, in: Capsule())
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(tool.title)
                    .accessibilityAddTraits(model.tool == tool ? .isSelected : [])
                }
            }
            divider(.horizontal)
            toolGroup {
                ForEach(InkColor.allCases, id: \.self) { ink in
                    Button { model.setInkColor(ink) } label: {
                        Circle().fill(Color(ink.color))
                            .frame(width: 24, height: 24)
                            .overlay(Circle().stroke(Color.primary, lineWidth: model.inkColor == ink ? 3 : 0))
                            .frame(width: ToolbarPlan.slot, height: ToolbarPlan.slot)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Color \(ink.rawValue)")
                    .accessibilityAddTraits(model.inkColor == ink ? .isSelected : [])
                }
                .disabled(model.tool == .eraser)
            }
            divider(.horizontal)
            toolGroup {
                ForEach(Array(EditorModel.lineWidths.enumerated()), id: \.element) { index, width in
                    Button { model.setLineWidth(width) } label: {
                        Circle().fill(model.lineWidth == width ? Color.accentColor : Color.secondary)
                            .frame(width: CGFloat(6 + index * 4), height: CGFloat(6 + index * 4))
                            .frame(width: ToolbarPlan.slot, height: ToolbarPlan.slot)
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
        return ViewThatFits(in: .horizontal) {
            row.padding(.horizontal, reserve).frame(maxWidth: .infinity)
            ScrollView(.horizontal, showsIndicators: false) { row.padding(.leading, ToolbarPlan.inset).padding(.trailing, reserve) }
        }
        .overlay(alignment: .trailing) {
            if layout == .topRow {
                statusCapsule.padding(.trailing, ToolbarPlan.inset)
            }
        }
        .padding(.vertical, 4)
    }

    private func toolGroup(@ViewBuilder _ content: () -> some View) -> some View {
        HStack(spacing: ToolbarPlan.itemSpacing, content: content)
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
        .frame(maxWidth: ToolbarPlan.statusReserve - ToolbarPlan.inset, minHeight: 22, maxHeight: 22)
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

enum ToolbarLayout: Equatable {
    case topRow
    case trailingRail

    static func resolve(width: CGFloat, height: CGFloat, horizontalSizeClass: UserInterfaceSizeClass?) -> ToolbarLayout {
        width > height && horizontalSizeClass == .regular ? .trailingRail : .topRow
    }
}

enum ToolbarItem: Hashable {
    case settings, history, mode, mic, replay, crop, window, undo, redo, new, more
}

enum ToolbarPlan {
    static let slot: CGFloat = 44
    static let pillLength: CGFloat = 88
    static let pillThickness: CGFloat = 36
    static let itemSpacing: CGFloat = 8
    static let groupGap: CGFloat = 16
    static let inset: CGFloat = 8
    static let railWidth: CGFloat = 60
    static let railVerticalInset: CGFloat = 12
    static let statusReserve: CGFloat = 80

    static let railGroups: [[ToolbarItem]] = [
        [.settings, .history], [.mode, .mic, .replay], [.crop, .window], [.undo, .redo], [.new],
    ]

    static func length(of item: ToolbarItem) -> CGFloat {
        item == .mode ? pillLength : slot
    }

    static func length(of group: [ToolbarItem]) -> CGFloat {
        group.reduce(0) { $0 + length(of: $1) } + CGFloat(max(group.count - 1, 0)) * itemSpacing
    }

    static func length(of groups: [[ToolbarItem]]) -> CGFloat {
        groups.reduce(0) { $0 + length(of: $1) } + CGFloat(max(groups.count - 1, 0)) * groupGap
    }

    static func rowGroups(availableWidth: CGFloat) -> [[ToolbarItem]] {
        let full = railGroups
        if length(of: full) <= availableWidth {
            return full
        }
        let cropInMore: [[ToolbarItem]] = [full[0], full[1], [.more], full[3], full[4]]
        if length(of: cropInMore) <= availableWidth {
            return cropInMore
        }
        return [full[1], [.more], full[3]]
    }
}
