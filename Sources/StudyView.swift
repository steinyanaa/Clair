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
                    emptyState.containerRelativeFrame(.vertical, alignment: .center) { height, _ in height * 0.8 }
                } else {
                    LazyVStack(alignment: .leading, spacing: Spacing.xxl + Spacing.xs) {
                        ForEach(messages) { message in
                            StudyMessageView(message: message, status: controller.studyStatus, busy: controller.assistantBusy,
                                             citations: message.state == "complete" ? StudyContext.citations(message.text, session: controller.session) : [],
                                             showSource: showSource,
                                             retry: { controller.runStudy(StudyAction(rawValue: message.action ?? "") ?? .question, question: message.request ?? "") })
                                .id(message.id)
                        }
                        Color.clear.frame(height: 1).id("study-bottom")
                    }
                    .frame(maxWidth: Layout.readingWidth - 60)
                    .padding(.horizontal, Spacing.xxxl + Spacing.s).padding(.vertical, Spacing.xxl)
                    .frame(maxWidth: .infinity)
                }
            }
            .onChange(of: scrollToken) { _, _ in reader.scrollTo("study-bottom", anchor: .bottom) }
            .onAppear { reader.scrollTo("study-bottom", anchor: .bottom) }
            .safeAreaBar(edge: .bottom) { composer }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.s + Spacing.xxs) {
            Image(systemName: "sparkle").font(.system(size: 24, weight: .medium)).foregroundStyle(Palette.clay)
                .padding(.bottom, Spacing.s).accessibilityHidden(true)
            Text("把课堂变成笔记").font(.display(28)).foregroundStyle(Palette.ink)
            Text(hasTranscript
                 ? "整理主题、生成纪要、提取术语，或直接提问。\n回答依据当前转录，并标出可以跳回原文的时间点。"
                 : "先开始听课，或打开一堂已有课堂，再使用课堂助手。")
                .font(.system(size: 14.5)).foregroundStyle(Palette.ink2).multilineTextAlignment(.center).lineSpacing(4)
        }
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            TextField(hasTranscript ? "问问这堂课，例如：这两个概念有什么区别？" : "需要先有课堂转录", text: $question, axis: .vertical)
                .lineLimit(1...5).textFieldStyle(.plain).font(.system(size: 14.5)).foregroundStyle(Palette.ink)
                .focused($composerFocused)
                .padding(.top, Spacing.xs)
                .disabled(!hasTranscript)
            HStack(spacing: Spacing.s - Spacing.xxs) {
                ForEach([StudyAction.organize, .minutes, .terms]) { action in
                    Button { controller.runStudy(action) } label: {
                        Label(action.rawValue, systemImage: action.symbol).labelStyle(ComposerLabelStyle())
                    }
                    .buttonStyle(GhostButtonStyle()).disabled(!available)
                }
                Spacer(minLength: Spacing.s)
                if controller.assistantBusy {
                    ProgressView().controlSize(.small)
                    Text(controller.studyStatus).font(.system(size: 11.5)).foregroundStyle(Palette.ink3).lineLimit(1)
                    Button("停止") { controller.cancelStudy(); controller.save() }.buttonStyle(GhostButtonStyle())
                } else {
                    Text(runtime.assistantReady ? "Gemma 本地 · 只依据这堂课的转录" : "课堂助手模型可在设置中下载")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.ink3).lineLimit(1)
                }
                Button { controller.exportStudy() } label: { Image(systemName: "square.and.arrow.up").font(.system(size: 13)) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!messages.contains { $0.state == "complete" })
                    .help("导出课堂笔记（Markdown）").accessibilityLabel("导出课堂笔记")
                Button(action: send) {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(ClayButtonStyle(kind: .icon))
                .keyboardShortcut(.return, modifiers: .command).disabled(!canSend)
                .help("发送问题 ⌘↩").accessibilityLabel("发送问题")
            }
        }
        .padding(.leading, Spacing.l).padding(.trailing, Spacing.s + Spacing.xxs).padding(.vertical, Spacing.m)
        .surfaceCard(cornerRadius: 20)
        .frame(maxWidth: Layout.readingWidth - 100)
        .padding(.horizontal, Spacing.xl).padding(.top, Spacing.s).padding(.bottom, Spacing.l)
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
                Text(message.text).font(.system(size: 14.5)).foregroundStyle(Palette.ink).lineSpacing(3).textSelection(.enabled)
                    .padding(.horizontal, Spacing.l - Spacing.xxs).padding(.vertical, Spacing.s + Spacing.xxs)
                    .background(Palette.bubble, in: RoundedRectangle(cornerRadius: Radius.bubble))
            }
        } else {
            VStack(alignment: .leading, spacing: Spacing.s) {
                HStack(spacing: Spacing.s - Spacing.xxs) {
                    Image(systemName: StudyAction(rawValue: message.action ?? "")?.symbol ?? "sparkle")
                        .font(.system(size: 11.5)).foregroundStyle(Palette.clay).accessibilityHidden(true)
                    Text(message.action ?? "课堂助手").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.ink2)
                    Spacer()
                    if let count = message.sourceCount { Text("基于 \(count) 段转录").font(.system(size: 11.5)).foregroundStyle(Palette.ink3) }
                }
                .padding(.bottom, Spacing.xxs)
                switch message.state {
                case "pending":
                    HStack(spacing: Spacing.s) { ProgressView().controlSize(.small); Text(status).foregroundStyle(Palette.ink2) }
                        .padding(.vertical, Spacing.s)
                case "failed":
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
                        Label(message.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        if message.request != nil { Button("重试", action: retry).buttonStyle(GhostButtonStyle()).disabled(busy) }
                    }
                    .font(.callout)
                default:
                    MarkdownReading(text: message.text)
                    ScrollView(.horizontal) {
                        HStack(spacing: Spacing.s - Spacing.xxs) {
                            ForEach(citations, id: \.self) { time in
                                Button { showSource(time) } label: {
                                    Label(time, systemImage: "text.quote").labelStyle(ComposerLabelStyle()).monospacedDigit()
                                        .font(.system(size: 11.5)).frame(minHeight: 24)
                                }
                                .buttonStyle(GhostButtonStyle())
                                .help("跳到 \(time) 的转录")
                            }
                            CopyButton(text: { message.text }).font(.system(size: 11.5)).padding(.leading, Spacing.xs)
                        }
                        .padding(.vertical, Spacing.xxs)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.top, Spacing.xs)
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
        .foregroundStyle(Palette.ink)
        .lineSpacing(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(Self.inline(text))
                .font(level == 1 ? .display(21) : level == 2 ? .display(17) : .system(size: 14.5, weight: .semibold))
                .padding(.top, level == 1 ? Spacing.xs : Spacing.s)
        case .bullet(let text, let depth):
            listItem(marker: "•", text: text, depth: depth)
        case .numbered(let marker, let text, let depth):
            listItem(marker: marker, text: text, depth: depth)
        case .quote(let text):
            Text(Self.inline(text)).foregroundStyle(Palette.ink2)
                .padding(.leading, Spacing.m)
                .overlay(alignment: .leading) { Capsule().fill(Palette.hairlineStrong).frame(width: 2) }
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
            Text(marker).monospacedDigit().foregroundStyle(Palette.ink3)
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
        Grid(alignment: .leading, horizontalSpacing: Spacing.l + Spacing.xs, verticalSpacing: Spacing.s + Spacing.xxs) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columns, id: \.self) { column in
                        Text(MarkdownReading.inline(column < row.count ? row[column] : ""))
                            .font(index == 0 ? .system(size: 12.5, weight: .semibold) : column == 0 ? .french(14.5) : .system(size: 14))
                            .foregroundStyle(index == 0 ? Palette.ink2 : Palette.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if index < rows.count - 1 {
                    Rectangle().fill(index == 0 ? Palette.hairlineStrong : Palette.hairline).frame(height: 0.5)
                        .gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .padding(.vertical, Spacing.xs)
    }
}

/// Icon and title close together, icon a step smaller, for compact controls.
struct ComposerLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Spacing.xs + Spacing.xxs) {
            configuration.icon.font(.system(size: 11))
            configuration.title
        }
    }
}
