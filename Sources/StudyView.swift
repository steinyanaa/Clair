import SwiftUI
import AppKit

struct StudyPanel: View {
    @Bindable var controller: ClassController
    let runtime: ModelRuntime
    let showSource: (String) -> Void
    @State private var question = ""
    @FocusState private var composerFocused: Bool
    private var messages: [StudyMessage] { controller.session.studyMessages ?? [] }
    private var hasTranscript: Bool { !controller.session.lines.isEmpty && controller.session.deletedAt == nil }
    private var available: Bool { hasTranscript && !controller.assistantBusy }
    private var canSend: Bool { available && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var scrollToken: String { "\(messages.count)|\(messages.last?.state ?? "")" }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                if messages.isEmpty {
                    emptyState.padding(.top, 80)
                } else {
                    LazyVStack(alignment: .leading, spacing: Spacing.xxl) {
                        ForEach(messages) { message in
                            StudyMessageView(message: message, status: controller.studyStatus, busy: controller.assistantBusy,
                                             citations: message.state == "complete" ? StudyContext.citations(message.text, session: controller.session) : [],
                                             showSource: showSource,
                                             retry: { controller.runStudy(StudyAction(rawValue: message.action ?? "") ?? .question, question: message.request ?? "") })
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("study-bottom")
                    }
                    .frame(maxWidth: Layout.readingWidth)
                    .padding(Spacing.xxl)
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: scrollToken) { _, _ in reader.scrollTo("study-bottom", anchor: .bottom) }
            .onAppear { reader.scrollTo("study-bottom", anchor: .bottom) }
            .safeAreaBar(edge: .bottom) { composer }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("把课堂变成笔记", systemImage: "sparkles")
        } description: {
            Text(hasTranscript
                 ? "整理主题、生成纪要、提取术语，或直接提问。\n回答依据当前转录，并标出可以跳回原文的时间点。"
                 : "先开始听课，或打开一堂已有课堂，再使用课堂助手。")
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                GlassEffectContainer(spacing: Spacing.xs) {
                    HStack(spacing: Spacing.s) {
                        ForEach([StudyAction.organize, .minutes, .terms]) { action in
                            Button { controller.runStudy(action) } label: { Label(action.rawValue, systemImage: action.symbol) }
                                .buttonStyle(.glass).disabled(!available)
                        }
                    }
                }
                Spacer(minLength: Spacing.s)
                if controller.assistantBusy {
                    ProgressView().controlSize(.small)
                    Text(controller.studyStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("停止") { controller.cancelStudy(); controller.save() }.controlSize(.small)
                } else {
                    Text(runtime.assistantReady ? "Gemma 本地 · 依据课堂转录" : "课堂助手模型可在设置中下载")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button { controller.exportStudy() } label: { Label("导出课堂笔记", systemImage: "square.and.arrow.up") }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .disabled(!messages.contains { $0.state == "complete" })
                    .help("导出课堂笔记（Markdown）")
            }
            HStack(alignment: .bottom, spacing: Spacing.s) {
                TextField(hasTranscript ? "问问这堂课，例如：这两个概念有什么区别？" : "需要先有课堂转录", text: $question, axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.plain).focused($composerFocused)
                    .padding(.horizontal, Spacing.m + Spacing.xxs).padding(.vertical, Spacing.s + Spacing.xxs)
                    .glassEffect(.regular, in: .rect(cornerRadius: Radius.bubble))
                    .disabled(!hasTranscript)
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.body.weight(.semibold)).frame(width: 18, height: 18)
                }
                .buttonStyle(.glassProminent).buttonBorderShape(.circle).controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command).disabled(!canSend)
                .help("发送问题 ⌘↩").accessibilityLabel("发送问题")
            }
        }
        .frame(maxWidth: Layout.readingWidth)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.m)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        guard canSend else { return }
        let value = question; question = ""
        controller.runStudy(.question, question: value)
    }
}

struct StudyMessageView: View {
    let message: StudyMessage
    let status: String
    let busy: Bool
    let citations: [String]
    let showSource: (String) -> Void
    let retry: () -> Void

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 60)
                Text(message.text).textSelection(.enabled)
                    .padding(.horizontal, Spacing.m + Spacing.xxs).padding(.vertical, Spacing.s + Spacing.xxs)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.bubble))
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s) {
                    Image(systemName: "sparkles").foregroundStyle(.tint).accessibilityHidden(true)
                    Text(message.action ?? "课堂助手").font(.callout.weight(.semibold))
                    Spacer()
                    if let count = message.sourceCount { Text("基于 \(count) 段转录").font(.caption).foregroundStyle(.tertiary) }
                }
                switch message.state {
                case "pending":
                    HStack(spacing: Spacing.s) { ProgressView().controlSize(.small); Text(status).foregroundStyle(.secondary) }
                        .padding(.vertical, Spacing.s)
                case "failed":
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        if message.request != nil { Button("重试", action: retry).disabled(busy) }
                    }
                    .font(.callout)
                default:
                    MarkdownReading(text: message.text)
                    if !citations.isEmpty {
                        ScrollView(.horizontal) {
                            HStack(spacing: Spacing.s) {
                                ForEach(citations, id: \.self) { time in
                                    Button { showSource(time) } label: { Label(time, systemImage: "text.quote").monospacedDigit() }
                                        .buttonStyle(.bordered).controlSize(.small)
                                        .help("跳到 \(time) 的转录")
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                    }
                    CopyButton(text: { message.text }).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MarkdownReading: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            ForEach(Array(MarkdownBlock.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .font(.system(size: 15))
        .lineSpacing(4)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .title2.weight(.semibold) : level == 2 ? .title3.weight(.semibold) : .headline)
                .padding(.top, Spacing.xs)
        case .bullet(let text, let depth):
            listItem(marker: "•", text: text, depth: depth)
        case .numbered(let marker, let text, let depth):
            listItem(marker: marker, text: text, depth: depth)
        case .quote(let text):
            Text(Self.inline(text)).foregroundStyle(.secondary)
                .padding(.leading, Spacing.m)
                .overlay(alignment: .leading) { Capsule().fill(.quaternary).frame(width: 3) }
        case .table(let rows):
            MarkdownTable(rows: rows)
        case .rule:
            Divider().padding(.vertical, Spacing.xs)
        case .paragraph(let text):
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func listItem(marker: String, text: String, depth: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Text(marker).monospacedDigit().foregroundStyle(.secondary)
            Text(Self.inline(text)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.leading, CGFloat(depth) * Spacing.l)
    }

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

struct MarkdownTable: View {
    let rows: [[String]]
    var body: some View {
        let columns = rows.map(\.count).max() ?? 0
        Grid(alignment: .leading, horizontalSpacing: Spacing.l, verticalSpacing: Spacing.s) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(MarkdownReading.inline(column < row.count ? row[column] : ""))
                            .fontWeight(index == 0 ? .semibold : nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if index == 0 && rows.count > 1 { Divider().gridCellUnsizedAxes(.horizontal) }
            }
        }
        .padding(Spacing.m)
        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: Radius.small))
    }
}
