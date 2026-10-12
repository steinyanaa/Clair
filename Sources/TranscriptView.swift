import SwiftUI
import AppKit

struct TranscriptPane: View {
    let controller: ClassController
    let runtime: ModelRuntime
    @Binding var jumpToLine: String?
    let followsLatest: Bool
    /// Follows new captions until the reader scrolls up; reaching the end resumes it.
    @State private var following = true
    @State private var userScrolling = false
    @State private var highlighted: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let bottomID = "transcript-bottom"

    private var lines: [TranscriptLine] { controller.session.lines }
    /// Changes when a caption is added, revised or translated; cheap to compare.
    private var followToken: String {
        guard let last = lines.last else { return "" }
        return "\(lines.count)|\(last.id)|\(last.revision)|\(last.chinese.count)"
    }
    private var showsJumpButton: Bool { followsLatest && !following && controller.isRecording && !lines.isEmpty }

    var body: some View {
        ScrollViewReader { reader in
            ScrollView {
                if lines.isEmpty {
                    // Sits slightly above the optical centre of the visible area.
                    emptyState.containerRelativeFrame(.vertical, alignment: .center) { height, _ in height * 0.82 }
                } else {
                    LazyVStack(alignment: .leading, spacing: Spacing.xs) {
                        ClassHeader(controller: controller)
                        ForEach(lines) { line in
                            TranscriptRow(line: line, showFrench: controller.showFrench, fontSize: controller.fontSize,
                                          markUncertain: controller.markUncertain,
                                          isPending: controller.isPending(line.id), highlighted: highlighted == line.id,
                                          editable: controller.session.deletedAt == nil,
                                          retranslate: { controller.retranslate(line.id) })
                                .equatable()
                                .id(line.id)
                                .transition(Motion.arrival(reduced: reduceMotion))
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    // Only a sentence arriving during a live class animates; opening another
                    // class swaps the whole column at once (its own identity), never cross-fades.
                    .animation(controller.isRecording ? Motion.enter(reduced: reduceMotion) : nil, value: lines.count)
                    .id(controller.session.id)
                    .frame(maxWidth: Layout.readingWidth)
                    .padding(.horizontal, Spacing.xxxl).padding(.top, Spacing.xl).padding(.bottom, Spacing.xxl)
                    .frame(maxWidth: .infinity)
                }
            }
            .onScrollPhaseChange { _, phase in
                userScrolling = phase == .interacting || phase == .decelerating || phase == .tracking
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 72
            } action: { _, nearEnd in
                if nearEnd { following = true } else if userScrolling { following = false }
            }
            .onChange(of: followToken) { _, _ in
                // Live captions arrive several times a second: scroll without animation.
                if followsLatest, following, controller.isRecording { reader.scrollTo(bottomID, anchor: .bottom) }
            }
            .onChange(of: jumpToLine) { _, id in reveal(id, with: reader, animated: true) }
            .onAppear { reveal(jumpToLine, with: reader, animated: false) }
            .onChange(of: controller.session.id) { _, _ in following = true; highlighted = nil }
            .overlay(alignment: .bottom) {
                if showsJumpButton {
                    Button {
                        following = true
                        withAnimation(Motion.state(reduced: reduceMotion)) { reader.scrollTo(bottomID, anchor: .bottom) }
                    } label: { Label("最新字幕", systemImage: "arrow.down") }
                    .buttonStyle(.glass)
                    .padding(.bottom, Spacing.s)
                    .transition(Motion.edge(.bottom, reduced: reduceMotion))
                    .help("回到最新字幕并继续跟随")
                }
            }
            .animation(Motion.enter(reduced: reduceMotion), value: showsJumpButton)
            .safeAreaBar(edge: .bottom) { TransportBar(controller: controller, runtime: runtime) }
        }
    }

    /// Scrolls to a cited line and briefly tints it so the eye lands on it.
    private func reveal(_ id: String?, with reader: ScrollViewProxy, animated: Bool) {
        guard let id else { return }
        following = false
        if animated { withAnimation(Motion.state(reduced: reduceMotion)) { reader.scrollTo(id, anchor: .center) } }
        else { reader.scrollTo(id, anchor: .center) }
        highlighted = id
        jumpToLine = nil   // the same citation can be followed again
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard highlighted == id else { return }
            withAnimation(Motion.settle) { highlighted = nil }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.xxl) {
            VStack(spacing: Spacing.s) {
                Text("这节课讲什么？").font(.largeTitle.weight(.semibold))
                Text("选好学科，翻译会使用对应领域的术语，并结合上下文理解每一句。")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            PresetEditor(controller: controller)
            HStack(spacing: Spacing.xs) {
                Text("准备好后点下方「开始听课」，或")
                Button("导入音频…") { WindowCommand.importAudio.send() }.buttonStyle(.link)
                    .disabled(controller.locked || controller.session.deletedAt != nil)
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 640)
        .padding(.horizontal, Spacing.xxl)
        .frame(maxWidth: .infinity)
    }
}

struct TranscriptRow: View, Equatable {
    let line: TranscriptLine
    let showFrench: Bool
    let fontSize: Double
    let markUncertain: Bool
    let isPending: Bool
    let highlighted: Bool
    let editable: Bool
    let retranslate: () -> Void
    @State private var hovering = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.line == b.line && a.showFrench == b.showFrench && a.fontSize == b.fontSize && a.markUncertain == b.markUncertain &&
            a.isPending == b.isPending && a.highlighted == b.highlighted && a.editable == b.editable
    }

    private var doubtLabel: String { "这一句识别可能有误 · \(TranscriptRules.markedWords(line).count) 个词存疑" }
    /// Underlines uncertain words in reading order, so a repeated word is marked only where it was doubtful.
    static func marked(_ text: String, uncertain: [String]) -> AttributedString {
        var result = AttributedString(text)
        var cursor = result.startIndex
        for word in uncertain {
            guard let range = result[cursor...].range(of: word, options: .caseInsensitive) else { continue }
            result[range][AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute.self] = Text.LineStyle(pattern: .dot, color: .orange)
            result[range][AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.self] = .orange
            cursor = range.upperBound
        }
        return result
    }
    private var isFallback: Bool { line.backend == TranscriptRules.fallbackBackend }
    private var sourceHelp: String {
        guard !line.backend.isEmpty else { return "" }
        return line.backend + (line.latency.map { String(format: " · %.1f 秒", $0) } ?? "")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.m) {
            Text(TranscriptRules.timecode(line.start))
                .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: Layout.timecodeWidth, alignment: .trailing)
                .opacity(hovering || highlighted ? 1 : 0)
            VStack(alignment: .leading, spacing: Spacing.xs + Spacing.xxs) {
                if showFrench {
                    Text(Self.marked(line.french, uncertain: markUncertain ? TranscriptRules.markedWords(line) : []))
                        .font(.system(size: max(13, fontSize * 0.7)))
                        .foregroundStyle(line.isFinal ? .secondary : .tertiary).lineSpacing(3)
                }
                if markUncertain, TranscriptRules.isDoubtful(line) {
                    Label(doubtLabel, systemImage: "waveform.badge.exclamationmark")
                        .font(.caption).foregroundStyle(.orange)
                        .help("背景人声、回声、停顿或距离过远时识别容易出错，橙色虚线标出的是识别把握较低的词。这一句的原文和译文请对照原声核对。")
                }
                translation
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .textSelection(.enabled)
        .padding(.vertical, Spacing.m).padding(.trailing, Spacing.m)
        .background {
            RoundedRectangle(cornerRadius: Radius.medium)
                .fill(Color.accentColor.opacity(highlighted ? 0.12 : 0))
                .padding(.leading, Layout.timecodeWidth)
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("复制译文") { copy(line.chinese) }.disabled(line.chinese.isEmpty)
            Button("复制原文") { copy(line.french) }
            Button("复制双语") { copy(line.french + "\n" + line.chinese) }.disabled(line.chinese.isEmpty)
            Divider()
            Button("重新翻译这一句", action: retranslate).disabled(!editable || isPending || !line.isFinal)
        }
    }

    @ViewBuilder private var translation: some View {
        if !line.chinese.isEmpty {
            Text(line.chinese).font(.system(size: fontSize)).lineSpacing(6).help(sourceHelp)
            if isFallback || isPending {
                HStack(spacing: Spacing.xs) {
                    if isPending { ProgressView().controlSize(.mini); Text(isFallback ? "正在用 Gemma 改进译文…" : "正在重新翻译…") }
                    else { Image(systemName: "arrow.triangle.2.circlepath"); Text(line.backend) }
                }
                .font(.caption).foregroundStyle(isPending ? Color.secondary : Color.orange)
            }
        } else if isPending || !line.isFinal {
            TypingIndicator(label: line.isFinal ? "正在翻译" : "正在识别")
        } else {
            HStack(spacing: Spacing.s) {
                if let error = line.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Text("尚未翻译").foregroundStyle(.secondary)
                }
                if editable { Button(line.error == nil ? "翻译" : "重试", action: retranslate).buttonStyle(.link) }
            }
            .font(.caption)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// One floating glass capsule, centred over the captions. Status text appears
/// above it only when something needs attention.
struct TransportBar: View {
    @Bindable var controller: ClassController
    let runtime: ModelRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Spacing.s) {
            GlassEffectContainer(spacing: Spacing.s) {
                HStack(spacing: Spacing.s) { controls }
                    .controlSize(.large)
            }
            statusLine
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.m)
        .animation(Motion.state(reduced: reduceMotion), value: controller.captureState)
    }

    /// Always shows whether the translation model is ready, plus anything else
    /// worth knowing right now (preparing, paused, improving fallback lines).
    private var statusLine: some View {
        HStack(spacing: Spacing.xs + Spacing.xxs) {
            if runtime.busy {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(runtime.ready ? Color.green : Color.orange).frame(width: 6, height: 6)
            }
            Text(([modelText] + notices).joined(separator: " · ")).lineLimit(1)
        }
        .font(.caption).foregroundStyle(.secondary)
        .help(runtime.ready ? "翻译在本机运行，语音和课堂内容不会上传" : runtime.status)
        .accessibilityElement(children: .combine)
    }

    private var modelText: String {
        guard runtime.ready else { return runtime.status }
        let title = ModelOption.translation.first { $0.id == LocalModel.name }?.title ?? "Gemma"
        return title + " 已就绪"
    }

    private var notices: [String] {
        var notes: [String] = []
        if controller.captureState == .starting { notes.append(controller.status) }
        if controller.captureState == .paused { notes.append("已暂停") }
        if controller.pendingCount > 0, !controller.isRecording, controller.upgradableCount > 0 {
            notes.append("正在用 Gemma 改进 \(controller.upgradableCount) 句备用译文")
        } else if controller.pendingCount > 2, controller.isRecording {
            notes.append("\(controller.pendingCount) 句待翻译")
        }
        return notes
    }

    @ViewBuilder private var controls: some View {
        switch controller.captureState {
        case .idle, .starting:
            sourcePicker
            Button { Task { await controller.start() } } label: {
                if controller.isStarting {
                    HStack(spacing: Spacing.s) { ProgressView().controlSize(.small); Text("准备中") }
                } else {
                    Label("开始听课", systemImage: "record.circle")
                }
            }
            .buttonStyle(.glassProminent)
            .disabled(!controller.canToggleCapture)
            .help("开始听课 ⌘R")
        case .recording, .paused, .stopping:
            HStack(spacing: Spacing.s) {
                Circle().fill(controller.isPaused ? Color.secondary : Color.red).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(TranscriptRules.timecode(controller.displayDuration)).font(.body.monospacedDigit().weight(.medium))
                LiveWaveform(controller: controller, paused: controller.isPaused)
            }
            .padding(.horizontal, Spacing.l).frame(height: 36)
            .glassEffect()
            .accessibilityElement(children: .combine)
            Button { Task { await controller.toggleCapture() } } label: {
                Image(systemName: controller.isPaused ? "play.fill" : "pause.fill").frame(width: 18)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).disabled(!controller.canToggleCapture)
            .help(controller.isPaused ? "继续听课 ⌘R" : "暂停 ⌘R")
            .accessibilityLabel(controller.isPaused ? "继续" : "暂停")
            Button { Task { await controller.stop() } } label: { Image(systemName: "stop.fill").frame(width: 18) }
                .buttonStyle(.glass).buttonBorderShape(.circle).disabled(controller.isStopping)
                .help("结束并保存 ⌘.").accessibilityLabel("结束")
        case .importing:
            HStack(spacing: Spacing.s) {
                ProgressView().controlSize(.small)
                Text("正在转写音频 · " + TranscriptRules.timecode(controller.displayDuration)).monospacedDigit()
            }
            .padding(.horizontal, Spacing.l).frame(height: 36).glassEffect()
            Button { Task { await controller.stop() } } label: { Image(systemName: "stop.fill").frame(width: 18) }
                .buttonStyle(.glass).buttonBorderShape(.circle).help("停止导入，保留已转写的内容").accessibilityLabel("停止转写")
        }
    }

    private var sourcePicker: some View {
        Menu {
            Picker("音源", selection: $controller.source) {
                ForEach(AudioSource.allCases) { source in Label(source.rawValue, systemImage: source.symbol).tag(source) }
            }
            .pickerStyle(.inline)
        } label: {
            Label(controller.source.rawValue, systemImage: controller.source.symbol)
        }
        .buttonStyle(.glass)
        .fixedSize()
        .disabled(controller.locked || controller.session.deletedAt != nil)
        .help("音源：麦克风用于现场课堂，系统声音用于视频和网课")
    }
}

/// Rolling waveform of the recent input level. It reads only `level`, so it is the
/// only view redrawn per audio buffer; values change too often to animate.
struct LiveWaveform: View {
    let controller: ClassController
    var paused = false
    @State private var history = [CGFloat](repeating: 0, count: 28)

    var body: some View {
        Canvas { context, size in
            let bar: CGFloat = 2.5, gap = (size.width - bar * CGFloat(history.count)) / CGFloat(history.count - 1)
            for (index, value) in history.enumerated() {
                let height = max(bar, value * size.height)
                let rect = CGRect(x: CGFloat(index) * (bar + gap), y: (size.height - height) / 2, width: bar, height: height)
                let fade = 0.35 + 0.65 * CGFloat(index) / CGFloat(history.count - 1)
                context.fill(Path(roundedRect: rect, cornerRadius: bar / 2), with: .color(.accentColor.opacity(paused ? 0.25 : fade)))
            }
        }
        .frame(width: 96, height: 18)
        .onChange(of: controller.level) { _, value in
            history.removeFirst(); history.append(min(1, CGFloat(value) * 1.4))
        }
        .accessibilityLabel("输入音量")
        .accessibilityValue(controller.level > 0.05 ? "有声音" : "安静")
    }
}

/// Animated ellipsis while a sentence is being recognised or translated.
struct TypingIndicator: View {
    let label: String
    var body: some View {
        Image(systemName: "ellipsis")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.tertiary)
            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
            .accessibilityLabel(label)
            .help(label)
    }
}

/// Title block at the top of the transcript; scrolls away with the captions.
struct ClassHeader: View {
    let controller: ClassController
    private var session: ClassSession { controller.session }
    private var meta: String {
        [session.created.formatted(.dateTime.month().day().hour().minute()), session.source,
         TranscriptRules.timecode(session.duration), "\(session.lines.count) 句"].joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            Text(session.title).font(.largeTitle.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: Spacing.m) {
                PresetTag(controller: controller)
                Text(meta).font(.callout).monospacedDigit().foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, Layout.timecodeWidth + Spacing.m)
        .padding(.bottom, Spacing.xl)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}
