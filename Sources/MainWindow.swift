import SwiftUI
import AppKit
import Translation

enum DetailPane: String { case transcript, assistant }

struct NameEdit: Identifiable {
    enum Kind {
        case newProject, renameProject, renameClass
        var title: String {
            switch self { case .newProject: "新项目文件夹"; case .renameProject: "重命名项目"; case .renameClass: "重命名课堂" }
        }
        var symbol: String { self == .renameClass ? "pencil" : "folder" }
        var confirm: String { self == .newProject ? "创建" : "保存" }
    }
    let id = UUID()
    let kind: Kind
    var target: UUID?
    var text: String
}

struct ClassWindow: View {
    @Bindable var controller: ClassController
    let runtime: ModelRuntime
    @SceneStorage("libraryFolder") private var folder = "all"
    @SceneStorage("detailPane") private var pane = DetailPane.transcript
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage("followsLatest") private var followsLatest = true
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var nameEdit: NameEdit?
    @State private var projectToDelete: ClassProject?
    @State private var showPalette = false
    @State private var paletteCommand: WindowCommand?
    @State private var showTextTest = false
    @State private var jumpToLine: String?
    @State private var dropTargeted = false
    /// Multi-selection in the class list. A single selected class simply opens.
    @State private var batchSelection: Set<UUID> = []
    @State private var purgeRequest: Set<UUID>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openSettings) private var openSettings

    private var records: [ClassSession] { controller.records(in: folder, matching: query) }
    /// Selected classes still listed; fewer than two means there is no batch.
    private var batch: [ClassSession] {
        guard batchSelection.count > 1 else { return [] }
        let picked = records.filter { batchSelection.contains($0.id) }
        return picked.count > 1 ? picked : []
    }
    /// What class commands act on: the batch, otherwise the open class once saved.
    private var targetIDs: Set<UUID> {
        let batch = batch
        if !batch.isEmpty { return Set(batch.map(\.id)) }
        return controller.history.contains { $0.id == controller.session.id } ? [controller.session.id] : []
    }
    private var targetsDeleted: Bool {
        let ids = targetIDs
        return !ids.isEmpty && controller.history.filter { ids.contains($0.id) }.allSatisfy { $0.deletedAt != nil }
    }

    var body: some View {
        NavigationSplitView {
            LibrarySidebar(controller: controller, folder: $folder,
                           renameProject: { nameEdit = NameEdit(kind: .renameProject, target: $0.id, text: $0.name) },
                           deleteProject: { projectToDelete = $0 },
                           newProject: { perform(.newProject) },
                           newClass: { perform(.newClass) },
                           emptyTrash: { perform(.emptyTrash) })
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } content: {
            ClassList(controller: controller, records: records, folder: folder, query: query, batchSelection: $batchSelection,
                      rename: { nameEdit = NameEdit(kind: .renameClass, target: $0.id, text: $0.title) },
                      move: { ids, project in controller.moveRecords(ids, to: project) },
                      trash: trash, restore: restore, purge: requestPurge,
                      deleteKey: { targetsDeleted ? requestPurge(targetIDs) : trash(targetIDs) })
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 380)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(controller.folderTitle(folder))
        .navigationSubtitle(query.isEmpty ? "\(records.count) 堂课" : "\(records.count) 个结果")
        .searchable(text: $query, placement: .sidebar, prompt: "搜索课堂与转录")
        .searchFocused($searchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .clairCommand)) { note in
            if let command = note.object as? WindowCommand { perform(command) }
        }
        .onChange(of: appearance) { _, value in AppearancePreference(rawValue: value)?.apply() }
        .onChange(of: folder) { _, _ in batchSelection = [] }
        .focusedSceneValue(\.classTargets, ClassTargets(count: targetIDs.count, deleted: targetsDeleted,
                                                         canEmptyTrash: controller.deletedCount > 0))
        .task { await applyLaunchArguments() }
        .translationTask(controller.backupConfiguration) { session in
            do { try await session.prepareTranslation(); controller.backupPrepared(session) }
            catch { controller.error = "备用翻译准备失败：\(error.localizedDescription)" }
        }
        .sheet(item: $nameEdit) { edit in
            NameDialog(edit: edit) { name in
                switch edit.kind {
                case .newProject: if let id = controller.createProject(name) { folder = id.uuidString }
                case .renameProject: if let id = edit.target { controller.renameProject(id, name: name) }
                case .renameClass: if let id = edit.target { controller.editRecord(id, title: name) }
                }
                nameEdit = nil
            }
        }
        // A palette choice runs after the sheet closes, so it can open another sheet.
        .sheet(isPresented: $showPalette, onDismiss: {
            if let command = paletteCommand { paletteCommand = nil; perform(command) }
        }) { CommandPalette(controller: controller) { paletteCommand = $0; showPalette = false } }
        .sheet(isPresented: $showTextTest) { TranslateTextSheet { controller.addText($0) } }
        .confirmationDialog(projectToDelete.map { "删除项目「\($0.name)」？" } ?? "",
                            isPresented: Binding(get: { projectToDelete != nil }, set: { if !$0 { projectToDelete = nil } }),
                            titleVisibility: .visible, presenting: projectToDelete) { project in
            Button("删除项目", role: .destructive) {
                controller.deleteProject(project.id)
                if folder == project.id.uuidString { folder = "unfiled" }
            }
            Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { project in
            let count = controller.history.filter { $0.projectID == project.id }.count
            Text(count == 0 ? "只删除这个项目文件夹。" : "项目中的 \(count) 堂课会移到「未分类」，课堂记录不会被删除。")
        }
        .confirmationDialog(purgeTitle,
                            isPresented: Binding(get: { purgeRequest != nil }, set: { if !$0 { purgeRequest = nil } }),
                            titleVisibility: .visible, presenting: purgeRequest) { ids in
            Button("彻底删除", role: .destructive) { controller.purge(ids); batchSelection.subtract(ids) }
            Button("取消", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { _ in
            Text("转录、译文和课堂助手内容会从这台 Mac 上永久删除，无法恢复。")
        }
    }

    private var purgeTitle: String {
        guard let ids = purgeRequest else { return "" }
        if ids.count == 1, let record = controller.history.first(where: { ids.contains($0.id) }) { return "彻底删除「\(record.title)」？" }
        return "彻底删除 \(ids.count) 堂课？"
    }

    // Batch actions. Only classes already in Recently Deleted can be purged, and
    // purging always goes through the confirmation above.
    private func trash(_ ids: Set<UUID>) {
        guard !controller.locked, !ids.isEmpty else { return }
        controller.setDeleted(ids, true); batchSelection = []
    }
    private func restore(_ ids: Set<UUID>) {
        guard !controller.locked, !ids.isEmpty else { return }
        controller.setDeleted(ids, false); batchSelection = []
    }
    private func requestPurge(_ ids: Set<UUID>) {
        guard !controller.locked else { return }
        let deleted = Set(controller.history.filter { ids.contains($0.id) && $0.deletedAt != nil }.map(\.id))
        if !deleted.isEmpty { purgeRequest = deleted }
    }

    private var detail: some View {
        Group {
            let batch = batch
            if !batch.isEmpty {
                BatchSelectionView(records: batch, projects: controller.projects, locked: controller.locked,
                                   move: { controller.moveRecords(Set(batch.map(\.id)), to: $0) },
                                   trash: { trash(Set(batch.map(\.id))) },
                                   restore: { restore(Set(batch.map(\.id))) },
                                   purge: { requestPurge(Set(batch.map(\.id))) },
                                   clear: { batchSelection = [] })
            } else {
                switch pane {
                case .assistant:
                    StudyPanel(controller: controller, runtime: runtime) { showSource($0) }
                case .transcript:
                    TranscriptPane(controller: controller, runtime: runtime, jumpToLine: $jumpToLine, followsLatest: followsLatest)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.canvas)
        .safeAreaBar(edge: .top) { banners }
        .toolbar { toolbar }
        .dropDestination(for: URL.self) { urls, _ in importDropped(urls) } isTargeted: { dropTargeted = $0 && !controller.locked }
        .overlay { if dropTargeted { dropHighlight } }
    }

    private var banners: some View {
        VStack(spacing: Spacing.s) {
            if controller.session.deletedAt != nil {
                Banner(symbol: "trash", message: "这堂课在「最近删除」中，恢复后可以继续听课和整理。") {
                    Button("恢复") { controller.editRecord(controller.session.id, deleted: false) }.disabled(controller.locked)
                    Button("彻底删除…", role: .destructive) { requestPurge([controller.session.id]) }.disabled(controller.locked)
                }
            }
            if let error = controller.error {
                Banner(symbol: "exclamationmark.triangle.fill", message: error, tint: .orange) {
                    Button { controller.error = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("关闭提示").accessibilityLabel("关闭提示")
                }
                .transition(Motion.edge(.top, reduced: reduceMotion))
            }
        }
        .padding(.horizontal, Spacing.l)
        .padding(.top, controller.error != nil || controller.session.deletedAt != nil ? Spacing.s : 0)
        .animation(Motion.enter(reduced: reduceMotion), value: controller.error)
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: Radius.medium + 4)
            .strokeBorder(Palette.clay, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            .background(Palette.claySoft.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.medium + 4))
            .overlay {
                Label("松开以导入音频", systemImage: "waveform.badge.plus")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Palette.ink)
                    .padding(.horizontal, Spacing.xl).padding(.vertical, Spacing.m)
                    .surfaceCard(cornerRadius: Radius.medium)
            }
            .padding(Spacing.m)
            .allowsHitTesting(false)
    }

    // Plain text tabs and two borderless icons: the toolbar stays quiet so the page leads.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            PaneTabs(selection: $pane).help("转录 ⌘1 · 课堂助手 ⌘2")
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) {
            HStack(spacing: Spacing.xxs) {
                Menu {
                    Button("导入音频…") { perform(.importAudio) }.disabled(controller.locked)
                    Divider()
                    Button("导出双语文本…") { controller.export(srt: false) }.disabled(controller.session.lines.isEmpty)
                    Button("导出字幕 SRT…") { controller.export(srt: true) }.disabled(controller.session.lines.isEmpty)
                    Button("导出课堂笔记…") { controller.exportStudy() }
                        .disabled(!(controller.session.studyMessages ?? []).contains { $0.state == "complete" })
                } label: { ToolbarIcon(symbol: "square.and.arrow.up", title: "导入与导出") }
                .help("导入音频或导出课堂")
                Menu { classMenu } label: { ToolbarIcon(symbol: "ellipsis", title: "课堂操作") }
                    .help("课堂操作")
            }
            .menuStyle(.button).menuIndicator(.hidden)
            .buttonStyle(QuietButtonStyle(size: 30))
        }
        .sharedBackgroundVisibility(.hidden)
    }

    @ViewBuilder private var classMenu: some View {
        let targets = targetIDs
        let editable = !controller.locked && !targets.isEmpty && !targetsDeleted
        Button("重命名课堂…") { perform(.renameClass) }.disabled(!editable || !batch.isEmpty)
        Menu(targets.count > 1 ? "将 \(targets.count) 堂课移到项目" : "移到项目") {
            Button("未分类") { controller.moveRecords(targets, to: nil) }
            ForEach(controller.projects) { project in
                Button(project.name) { controller.moveRecords(targets, to: project.id) }
            }
        }.disabled(!editable)
        Divider()
        Toggle("显示法语原文", isOn: $controller.showFrench)
        Toggle("自动跟随最新字幕", isOn: $followsLatest)
        Divider()
        Button("试译法语文字…") { perform(.translateText) }.disabled(controller.session.deletedAt != nil)
        Button("重试未完成译文") { controller.retryFailed() }.disabled(controller.untranslatedCount == 0 || controller.session.deletedAt != nil)
        Divider()
        if targetsDeleted {
            Button("恢复") { perform(.restoreSelection) }.disabled(controller.locked)
            Button("彻底删除…", role: .destructive) { perform(.purgeSelection) }.disabled(controller.locked)
        } else {
            Button(targets.count > 1 ? "将 \(targets.count) 堂课移到最近删除" : "移到最近删除", role: .destructive) { perform(.trashSelection) }
                .disabled(!editable)
        }
    }

    /// UI-check hooks: `-ClairClassUITestPane assistant`, `-ClairClassUITestPalette YES`,
    /// `-ClairClassUITestSettings YES`, `-ClairClassUITestOpen <class id>`. Launch arguments only; nothing is stored.
    private func applyLaunchArguments() async {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let value = arguments["ClairClassUITestPane"] as? String, let target = DetailPane(rawValue: value) { pane = target }
        if arguments["ClairClassUITestPalette"] != nil { showPalette = true }
        if arguments["ClairClassUITestSettings"] != nil { openSettings() }
        if let value = arguments["ClairClassUITestFolder"] as? String { folder = value }
        if let value = arguments["ClairClassUITestOpen"] as? String, let id = UUID(uuidString: value) { perform(.open(id)) }
        if arguments["ClairClassUITestSelectAll"] != nil {
            // After the folder change above has cleared any selection.
            try? await Task.sleep(for: .milliseconds(300))
            batchSelection = Set(records.map(\.id))
        }
    }

    private func showSource(_ timestamp: String) {
        jumpToLine = controller.session.lines.first(where: { TranscriptRules.timecode($0.start) == timestamp })?.id
        pane = .transcript
    }

    private func importDropped(_ urls: [URL]) -> Bool {
        guard !controller.locked, let url = urls.first(where: ClassController.isAudioFile) else {
            if !urls.isEmpty, !controller.locked { controller.error = "只能导入音频文件，例如 m4a、mp3、wav 或 aiff。" }
            return false
        }
        pane = .transcript
        Task { await controller.importAudioFile(url) }
        return true
    }

    private func perform(_ command: WindowCommand) {
        switch command {
        case .newClass:
            guard !controller.locked else { return }
            controller.newSession(); controller.session.projectID = UUID(uuidString: folder)
            if folder == "trash" { folder = "all" }
            pane = .transcript
        case .newProject: nameEdit = NameEdit(kind: .newProject, text: "")
        case .renameClass:
            guard !controller.session.lines.isEmpty, !controller.locked else { return }
            nameEdit = NameEdit(kind: .renameClass, target: controller.session.id, text: controller.session.title)
        case .importAudio: pane = .transcript; Task { await controller.importAudio() }
        case .palette: showPalette = true
        case .translateText: pane = .transcript; showTextTest = true
        case .findClasses: searchFocused = true
        case .showTranscript: pane = .transcript
        case .showAssistant: pane = .assistant
        case .toggleCapture: Task { await controller.toggleCapture() }
        case .exportText: controller.export(srt: false)
        case .exportSubtitles: controller.export(srt: true)
        case .openSettings: openSettings()
        case .trashSelection: trash(targetIDs)
        case .restoreSelection: restore(targetIDs)
        case .purgeSelection: requestPurge(targetIDs)
        case .emptyTrash: requestPurge(Set(controller.history.filter { $0.deletedAt != nil }.map(\.id)))
        case .study(let action): pane = .assistant; controller.runStudy(action)
        case .open(let id):
            guard let item = controller.history.first(where: { $0.id == id }) else { return }
            // Make sure the list shows the class being opened.
            if item.deletedAt != nil { folder = "trash" }
            else if folder == "trash" || (folder != "all" && folder != (item.projectID?.uuidString ?? "unfiled")) { folder = "all" }
            batchSelection = []
            controller.select(item)
        }
    }
}

struct LibrarySidebar: View {
    let controller: ClassController
    @Binding var folder: String
    let renameProject: (ClassProject) -> Void
    let deleteProject: (ClassProject) -> Void
    let newProject: () -> Void
    let newClass: () -> Void
    let emptyTrash: () -> Void
    @State private var dropTarget: String?

    var body: some View {
        let live = controller.history.filter { $0.deletedAt == nil }
        let byProject = Dictionary(grouping: live.compactMap(\.projectID), by: { $0 }).mapValues(\.count)
        // No List selection: rows draw their own warm selection instead of the system accent.
        List {
            NewClassRow(locked: controller.locked, action: newClass)
            Section("资料库") {
                row("所有课堂", "tray.full", live.count, "all")
                row("未分类", "tray", live.filter { $0.projectID == nil }.count, "unfiled")
                    .classDrop("unfiled", target: $dropTarget, enabled: !controller.locked) { ids in
                        for id in ids { controller.editRecord(id, move: true, deleted: false) }
                    }
            }
            Section("项目") {
                ForEach(controller.projects) { project in
                    row(project.name, "folder", byProject[project.id] ?? 0, project.id.uuidString)
                        .contextMenu {
                            Button("重命名项目…") { renameProject(project) }
                            Divider()
                            Button("删除项目…", role: .destructive) { deleteProject(project) }.disabled(controller.locked)
                        }
                        .classDrop(project.id.uuidString, target: $dropTarget, enabled: !controller.locked) { ids in
                            for id in ids { controller.editRecord(id, project: project.id, move: true, deleted: false) }
                        }
                }
                SidebarRow(title: "新项目文件夹…", symbol: "plus", count: 0, selected: false, muted: true, action: newProject)
            }
            Section {
                row("最近删除", "trash", controller.history.count - live.count, "trash")
                    .classDrop("trash", target: $dropTarget, enabled: !controller.locked) { ids in
                        controller.setDeleted(Set(ids), true)
                    }
                    .contextMenu {
                        Button("清空最近删除…", role: .destructive, action: emptyTrash)
                            .disabled(controller.locked || controller.history.count == live.count)
                    }
            }
        }
        .listStyle(.sidebar)
    }

    private func row(_ title: String, _ symbol: String, _ count: Int, _ tag: String) -> some View {
        SidebarRow(title: title, symbol: symbol, count: count, selected: folder == tag) { folder = tag }
    }
}

/// Folder row with its own selection wash; the count sits where a badge would.
struct SidebarRow: View {
    let title: String
    let symbol: String
    let count: Int
    let selected: Bool
    var muted = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Palette.ink2).frame(width: 20)
                Text(title).font(.system(size: 13, weight: selected ? .medium : .regular))
                    .foregroundStyle(muted ? Palette.ink2 : Palette.ink).lineLimit(1)
                Spacer(minLength: Spacing.s)
                if count > 0 { Text("\(count)").font(.system(size: 11.5)).monospacedDigit().foregroundStyle(Palette.ink3) }
            }
            .padding(.horizontal, Spacing.s).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Palette.selectionFocused : hovering ? Palette.wash.opacity(0.7) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .sidebarRowBleed()
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

private extension View {
    /// Lets a row's wash reach the sidebar's edges, so icons line up with the search field.
    func sidebarRowBleed() -> some View { padding(.horizontal, -(Spacing.s - 1)) }

    /// Accepts classes dragged from the list, with a visible target highlight.
    func classDrop(_ id: String, target: Binding<String?>, enabled: Bool, perform: @escaping ([UUID]) -> Void) -> some View {
        dropDestination(for: String.self) { values, _ in
            // A multi-class drag carries one ID per line.
            let ids = values.flatMap { $0.split(whereSeparator: \.isNewline) }.compactMap { UUID(uuidString: String($0)) }
            guard enabled, !ids.isEmpty else { return false }
            perform(ids); return true
        } isTargeted: { inside in
            if inside { target.wrappedValue = id } else if target.wrappedValue == id { target.wrappedValue = nil }
        }
        .background {
            if target.wrappedValue == id {
                RoundedRectangle(cornerRadius: 6).fill(Palette.claySoft).padding(-Spacing.xs)
            }
        }
    }
}

struct ClassList: View {
    let controller: ClassController
    let records: [ClassSession]
    let folder: String
    let query: String
    @Binding var batchSelection: Set<UUID>
    let rename: (ClassSession) -> Void
    let move: (Set<UUID>, UUID?) -> Void
    let trash: (Set<UUID>) -> Void
    let restore: (Set<UUID>) -> Void
    let purge: (Set<UUID>) -> Void
    let deleteKey: () -> Void
    @FocusState private var listFocused: Bool
    /// Where a ⇧-click range starts.
    @State private var anchor: UUID?

    var body: some View {
        if records.isEmpty { emptyState.frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas) } else { list(records) }
    }

    @ViewBuilder private var emptyState: some View {
        if !query.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if folder == "trash" {
            ContentUnavailableView("最近删除为空", systemImage: "trash", description: Text("移到这里的课堂可以随时恢复。"))
        } else {
            ContentUnavailableView {
                Label("还没有课堂", systemImage: "waveform")
            } description: {
                Text("开始听课，或导入一段法语音频。")
            } actions: {
                Button("导入音频…") { WindowCommand.importAudio.send() }.disabled(controller.locked)
            }
        }
    }

    /// Classes the list shows as selected: the batch, otherwise the open class.
    private var selectedIDs: Set<UUID> { batchSelection.count > 1 ? batchSelection : [controller.session.id] }

    // Drawn by hand rather than as a List so selection uses the warm neutral wash
    // instead of the system accent. Click opens; ⌘-click and ⇧-click build a batch;
    // arrow keys move and Delete acts on the selection, as in a native list.
    private func list(_ records: [ClassSession]) -> some View {
        let projectNames = Dictionary(uniqueKeysWithValues: controller.projects.map { ($0.id, $0.name) })
        let liveID = controller.isRecording || controller.isPaused ? controller.session.id : nil
        let selected = selectedIDs
        return ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: Spacing.xxs) {
                    ForEach(records) { record in
                        ClassRow(record: record, isLive: record.id == liveID,
                                 projectName: folder == "all" ? record.projectID.flatMap { projectNames[$0] } : nil)
                            .modifier(ClassRowChrome(selected: selected.contains(record.id), focused: listFocused))
                            .id(record.id)
                            .onTapGesture { click(record, in: records) }
                            .draggable(dragPayload(record))
                            .contextMenu { menu(selected.contains(record.id) ? selected : [record.id]) }
                            .accessibilityAddTraits(selected.contains(record.id) ? [.isButton, .isSelected] : .isButton)
                            .accessibilityAction { click(record, in: records) }
                    }
                }
                .padding(.horizontal, Spacing.s + Spacing.xxs).padding(.vertical, Spacing.xs)
            }
            .background(Palette.canvas)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.downArrow) { step(1, in: records, reader: reader); return .handled }
            .onKeyPress(.upArrow) { step(-1, in: records, reader: reader); return .handled }
            .onDeleteCommand(perform: deleteKey)
            .onCommand(#selector(NSResponder.selectAll(_:))) { if !controller.locked { apply(Set(records.map(\.id)), in: records) } }
        }
    }

    private func click(_ record: ClassSession, in records: [ClassSession]) {
        guard !controller.locked else { return }
        listFocused = true
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            var picked = selectedIDs
            if picked.contains(record.id) { picked.remove(record.id) } else { picked.insert(record.id) }
            apply(picked, in: records); anchor = record.id
        } else if flags.contains(.shift), let start = records.firstIndex(where: { $0.id == (anchor ?? controller.session.id) }),
                  let end = records.firstIndex(where: { $0.id == record.id }) {
            apply(Set(records[min(start, end)...max(start, end)].map(\.id)), in: records)
        } else {
            apply([record.id], in: records); anchor = record.id
        }
    }

    /// Two or more classes form a batch; a single one simply opens.
    private func apply(_ picked: Set<UUID>, in records: [ClassSession]) {
        if picked.count > 1 { batchSelection = picked; return }
        batchSelection = []
        if let id = picked.first, let item = records.first(where: { $0.id == id }) { controller.select(item) }
    }

    private func step(_ offset: Int, in records: [ClassSession], reader: ScrollViewProxy) {
        guard !controller.locked, !records.isEmpty else { return }
        let current = records.firstIndex { $0.id == (batchSelection.count > 1 ? anchor : controller.session.id) }
        let index = current.map { min(max($0 + offset, 0), records.count - 1) } ?? (offset > 0 ? 0 : records.count - 1)
        apply([records[index].id], in: records); anchor = records[index].id
        reader.scrollTo(records[index].id)
    }

    /// Dragging a row inside the batch carries the whole batch, one ID per line.
    private func dragPayload(_ record: ClassSession) -> String {
        batchSelection.count > 1 && batchSelection.contains(record.id)
            ? batchSelection.map(\.uuidString).joined(separator: "\n") : record.id.uuidString
    }

    @ViewBuilder private func menu(_ ids: Set<UUID>) -> some View {
        let picked = controller.history.filter { ids.contains($0.id) }
        let suffix = picked.count > 1 ? " \(picked.count) 堂课" : ""
        if picked.isEmpty {
            EmptyView()
        } else if picked.allSatisfy({ $0.deletedAt != nil }) {
            Button("恢复" + suffix) { restore(ids) }.disabled(controller.locked)
            Divider()
            Button("彻底删除" + suffix + "…", role: .destructive) { purge(ids) }.disabled(controller.locked)
        } else {
            if picked.count == 1, let record = picked.first {
                Button("重命名…") { rename(record) }.disabled(controller.locked)
            }
            Menu("移到项目") {
                Button("未分类") { move(ids, nil) }
                ForEach(controller.projects) { project in Button(project.name) { move(ids, project.id) } }
            }.disabled(controller.locked)
            Divider()
            Button("移到最近删除" + suffix, role: .destructive) { trash(ids) }.disabled(controller.locked)
        }
    }
}

struct ClassRow: View {
    let record: ClassSession
    let isLive: Bool
    let projectName: String?

    private var preview: String {
        guard let last = record.lines.last else { return "" }
        return last.chinese.isEmpty ? last.french : last.chinese
    }
    private var dateText: String {
        Calendar.current.isDateInToday(record.created)
            ? record.created.formatted(.dateTime.hour().minute())
            : record.created.formatted(.dateTime.month().day())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs + Spacing.xxs) {
                if isLive {
                    Circle().fill(Palette.clay).frame(width: 7, height: 7)
                        .background(Circle().fill(Palette.claySoft).frame(width: 13, height: 13))
                        .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                        .accessibilityLabel("正在听课")
                }
                Text(record.title).font(.rowTitle).foregroundStyle(Palette.ink).lineLimit(1)
                Spacer(minLength: Spacing.s)
                Text(dateText).font(.rowMeta).monospacedDigit().foregroundStyle(Palette.ink3)
            }
            if !preview.isEmpty {
                Text(preview).font(.rowPreview).foregroundStyle(Palette.ink2).lineSpacing(2).lineLimit(2)
            }
            HStack(spacing: Spacing.xs) {
                Image(systemName: AudioSource.symbol(forRecordSource: record.source)).accessibilityLabel(record.source)
                Text(TranscriptRules.timecode(record.duration)).monospacedDigit()
                if let projectName {
                    Image(systemName: "folder").padding(.leading, Spacing.xs).accessibilityHidden(true)
                    Text(projectName).lineLimit(1)
                }
            }
            .font(.rowMeta).foregroundStyle(Palette.ink3)
            .padding(.top, Spacing.xxs)
        }
        .padding(.vertical, Spacing.s)
        .padding(.horizontal, Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

extension ClassController {
    func folderTitle(_ folder: String) -> String {
        switch folder {
        case "all": "所有课堂"
        case "unfiled": "未分类"
        case "trash": "最近删除"
        default: projects.first(where: { $0.id.uuidString == folder })?.name ?? "所有课堂"
        }
    }
    /// Classes shown in the list column for a sidebar folder and search text.
    func records(in folder: String, matching query: String) -> [ClassSession] {
        history.filter { record in
            let inFolder = folder == "trash" ? record.deletedAt != nil : record.deletedAt == nil &&
                (folder == "all" || folder == "unfiled" && record.projectID == nil || record.projectID?.uuidString == folder)
            return inFolder && (query.isEmpty || record.title.localizedCaseInsensitiveContains(query) ||
                record.lines.contains { $0.french.localizedCaseInsensitiveContains(query) || $0.chinese.localizedCaseInsensitiveContains(query) })
        }
    }
}

/// Detail shown while several classes are selected.
struct BatchSelectionView: View {
    let records: [ClassSession]
    let projects: [ClassProject]
    let locked: Bool
    let move: (UUID?) -> Void
    let trash: () -> Void
    let restore: () -> Void
    let purge: () -> Void
    let clear: () -> Void

    private var inTrash: Bool { records.allSatisfy { $0.deletedAt != nil } }
    private var summary: String {
        let seconds = records.reduce(0) { $0 + $1.duration }
        let length = Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated, maximumUnitCount: 2))
        let titles = records.prefix(3).map { "「\($0.title)」" }.joined(separator: "、") + (records.count > 3 ? " 等" : "")
        return titles + "\n共 " + length + " · \(records.reduce(0) { $0 + $1.lines.count }) 句"
    }

    var body: some View {
        ContentUnavailableView {
            Label("已选择 \(records.count) 堂课", systemImage: inTrash ? "trash" : "square.stack")
        } description: {
            Text(summary + (inTrash ? "\n彻底删除后无法恢复。" : ""))
        } actions: {
            VStack(spacing: Spacing.m) {
            HStack(spacing: Spacing.s) {
                if inTrash {
                    Button("恢复", action: restore)
                    Button("彻底删除…", role: .destructive, action: purge)
                } else {
                    Menu("移到项目") {
                        Button("未分类") { move(nil) }
                        ForEach(projects) { project in Button(project.name) { move(project.id) } }
                    }
                    .fixedSize()
                    Button("移到最近删除", role: .destructive, action: trash)
                }
            }
            .fixedSize()
            .disabled(locked)
            Button("取消选择", action: clear).buttonStyle(.link)
            }
        }
    }
}

/// Rounded wash behind a class row for hover and selection.
private struct ClassRowChrome: ViewModifier {
    let selected: Bool
    let focused: Bool
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Spacing.s)
            .background {
                RoundedRectangle(cornerRadius: Radius.medium)
                    .fill(selected ? (focused ? Palette.selectionFocused : Palette.selection) : hovering ? Palette.wash.opacity(0.6) : .clear)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.medium))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// First sidebar row: the one clay "new" mark, like a notebook's blank page.
struct NewClassRow: View {
    let locked: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Palette.clay, in: Circle())
                    .scaleEffect(hovering ? 1.06 : 1)
                Text("新课堂").font(.system(size: 13.5, weight: .medium)).foregroundStyle(Palette.ink)
                Spacer()
                Text("⌘N").font(.system(size: 11)).foregroundStyle(Palette.ink3)
            }
            .padding(.horizontal, Spacing.s).frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sidebarRowBleed()
        .disabled(locked)
        .opacity(locked ? 0.5 : 1)
        .onHover { hovering = $0 && !locked }
        .animation(.spring(response: 0.25, dampingFraction: 0.6), value: hovering)
        .help("新课堂 ⌘N")
        .padding(.bottom, Spacing.s)
    }
}

/// Transcript / assistant switch drawn as text; a clay bar slides to the chosen pane.
struct PaneTabs: View {
    @Binding var selection: DetailPane
    @Namespace private var underline
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Spacing.xxl) {
            tab("转录", .transcript)
            tab("课堂助手", .assistant)
        }
        .padding(.horizontal, Spacing.s)
        .frame(height: 30)
        .accessibilityElement(children: .contain)
    }

    private func tab(_ title: String, _ pane: DetailPane) -> some View {
        let selected = selection == pane
        return Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82)) { selection = pane }
        } label: {
            Text(title)
                .font(.system(size: 13.5, weight: selected ? .medium : .regular))
                .foregroundStyle(selected ? Palette.ink : Palette.ink3)
                .padding(.vertical, Spacing.s)
                .overlay(alignment: .bottom) {
                    if selected {
                        Capsule().fill(Palette.clay).frame(height: 2)
                            .matchedGeometryEffect(id: "underline", in: underline)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Toolbar menu label: a single symbol with an accessible name, no indicator.
struct ToolbarIcon: View {
    let symbol: String
    let title: String
    var body: some View {
        Image(systemName: symbol).font(.system(size: 14)).frame(width: 30, height: 30).accessibilityLabel(title)
    }
}

struct ClassTargets: Equatable {
    var count: Int
    var deleted: Bool
    var canEmptyTrash: Bool
}

extension FocusedValues {
    @Entry var classTargets: ClassTargets?
}
