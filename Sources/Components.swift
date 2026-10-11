import SwiftUI
import AppKit

struct NameDialog: View {
    let edit: NameEdit
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var focused: Bool
    init(edit: NameEdit, save: @escaping (String) -> Void) { self.edit = edit; self.save = save; _name = State(initialValue: edit.text) }
    private var clean: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Label(edit.kind.title, systemImage: edit.kind.symbol).font(.title2.weight(.semibold))
            TextField("名称", text: $name).textFieldStyle(.roundedBorder).focused($focused).onSubmit(commit)
            if edit.kind == .newProject {
                Text("把相关课堂放在同一个项目中，方便查找和复习。").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(edit.kind.confirm, action: commit).keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(clean.isEmpty)
            }
        }
        .padding(Spacing.xxl).frame(width: 420)
        .onAppear { focused = true }
    }
    private func commit() { if !clean.isEmpty { save(clean) } }
}

struct TranslateTextSheet: View {
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = "Bonjour. Aujourd’hui, nous allons étudier la différence entre la croissance économique et le développement durable."
    private var clean: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.l) {
            Label("试译法语文字", systemImage: "character.bubble").font(.title2.weight(.semibold))
            Text("译文会作为新的一句加入当前课堂。").font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body).scrollContentBackground(.hidden)
                .padding(Spacing.s)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.small))
                .overlay(RoundedRectangle(cornerRadius: Radius.small).strokeBorder(.separator))
                .frame(width: 480, height: 150)
            HStack {
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("翻译") { submit(clean); dismiss() }.keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).disabled(clean.isEmpty)
            }
        }
        .padding(Spacing.xxl)
    }
}

/// ⌘K palette. Arrow keys move through actions and classes from the search
/// field; Return or a double-click runs the selection. It opens without
/// animation beyond the system sheet because it is used many times a day.
struct CommandPalette: View {
    let controller: ClassController
    let choose: (WindowCommand) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        let symbol: String
        var shortcut: String?
        let command: WindowCommand
    }

    private func matches(_ text: String) -> Bool { query.isEmpty || text.localizedCaseInsensitiveContains(query) }
    private var actions: [Item] {
        let capture = controller.captureState == .recording ? "暂停" : controller.isPaused ? "继续听课" : controller.isImporting ? "停止转写" : "开始听课"
        return [
            Item(id: "capture", title: capture, symbol: "record.circle", shortcut: "⌘R", command: .toggleCapture),
            Item(id: "new", title: "新课堂", symbol: "square.and.pencil", shortcut: "⌘N", command: .newClass),
            Item(id: "project", title: "新项目文件夹", symbol: "folder.badge.plus", shortcut: "⇧⌘N", command: .newProject),
            Item(id: "import", title: "导入音频", symbol: "square.and.arrow.down", shortcut: "⌘O", command: .importAudio),
            Item(id: "transcript", title: "显示转录", symbol: "captions.bubble", shortcut: "⌘1", command: .showTranscript),
            Item(id: "assistant", title: "课堂问答", symbol: "bubble.left.and.bubble.right", shortcut: "⌘2", command: .showAssistant),
            Item(id: "organize", title: StudyAction.organize.rawValue, symbol: StudyAction.organize.symbol, command: .study(.organize)),
            Item(id: "minutes", title: StudyAction.minutes.rawValue, symbol: StudyAction.minutes.symbol, command: .study(.minutes)),
            Item(id: "terms", title: StudyAction.terms.rawValue, symbol: StudyAction.terms.symbol, command: .study(.terms)),
            Item(id: "export-text", title: "导出双语文本", symbol: "doc.plaintext", shortcut: "⇧⌘S", command: .exportText),
            Item(id: "export-srt", title: "导出字幕 SRT", symbol: "captions.bubble.fill", command: .exportSubtitles),
            Item(id: "translate", title: "试译法语文字", symbol: "character.bubble", command: .translateText),
            Item(id: "empty-trash", title: "清空最近删除", symbol: "trash.slash", command: .emptyTrash),
            Item(id: "settings", title: "设置", symbol: "gearshape", shortcut: "⌘,", command: .openSettings)
        ].filter { matches($0.title) }
    }
    private var classes: [Item] {
        controller.history.lazy.filter { $0.deletedAt == nil && self.matches($0.title) }.prefix(8).map {
            Item(id: $0.id.uuidString, title: $0.title, symbol: AudioSource.symbol(forRecordSource: $0.source),
                 shortcut: $0.created.formatted(.dateTime.month().day()), command: .open($0.id))
        }
    }
    private var items: [Item] { actions + classes }

    var body: some View {
        let actions = actions, classes = classes
        VStack(spacing: 0) {
            HStack(spacing: Spacing.m) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("搜索命令或课堂", text: $query)
                    .textFieldStyle(.plain).font(.title3).focused($focused)
                    .onSubmit(runSelection)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
            }
            .padding(Spacing.xl)
            Divider()
            if actions.isEmpty && classes.isEmpty {
                ContentUnavailableView.search(text: query).frame(maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    List(selection: $selection) {
                        if !actions.isEmpty { Section("操作") { ForEach(actions, content: row) } }
                        if !classes.isEmpty { Section("课堂") { ForEach(classes, content: row) } }
                    }
                    .listStyle(.inset)
                    .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { _ in runSelection() })
                    .onChange(of: selection) { _, id in if let id { reader.scrollTo(id) } }
                }
            }
            Divider()
            HStack(spacing: Spacing.m) {
                Text("↑↓ 选择 · ↩ 打开 · esc 关闭").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("打开", action: runSelection).keyboardShortcut(.defaultAction).disabled(selection == nil)
            }
            .padding(Spacing.m)
        }
        .frame(width: 600, height: 460)
        .onAppear { focused = true; selection = items.first?.id }
        .onChange(of: query) { _, _ in selection = items.first?.id }
    }

    private func row(_ item: Item) -> some View {
        HStack(spacing: Spacing.s) {
            Label(item.title, systemImage: item.symbol).lineLimit(1)
            Spacer()
            if let shortcut = item.shortcut { Text(shortcut).font(.callout).monospacedDigit().foregroundStyle(.secondary) }
        }
        .listRowSeparator(.hidden)
        .tag(item.id)
    }

    private func move(_ step: Int) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        let index = selection.flatMap { ids.firstIndex(of: $0) } ?? -step
        selection = ids[min(max(index + step, 0), ids.count - 1)]
    }

    private func runSelection() {
        guard let item = items.first(where: { $0.id == selection }) ?? items.first else { return }
        choose(item.command)
    }
}
