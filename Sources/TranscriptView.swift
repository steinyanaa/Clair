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
                    emptyState.padding(.top, 96)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ClassHeader(session: controller.session)
                        ForEach(lines) { line in
                            TranscriptRow(line: line, showFrench: controller.showFrench, fontSize: controller.fontSize,
                                          markUncertain: controller.markUncertain,
                                          isPending: controller.isPending(line.id), highlighted: highlighted == line.id,
                                          editable: controller.session.deletedAt == nil,
                                          retranslate: { controller.retranslate(line.id) })
                                .equatable()
                                .id(line.id)
                        }
                        Color.clear.frame(height: 1).id(bottomID)
                    }
                    .frame(maxWidth: Layout.readingWidth)
                    .padding(.horizontal, Spacing.xxl).padding(.vertical, Spacing.m)
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
        ContentUnavailableView {
            Label("听课，从这里开始", systemImage: "waveform")
        } description: {
            Text("在下方选择麦克风或系统声音，然后开始听课。\n法语原文和中文译文会逐句出现，也可以把音频文件拖到这里。")
        } actions: {
            Button("导入音频…") { WindowCommand.importAudio.send() }
                .disabled(controller.locked || controller.session.deletedAt != nil)
        }
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
        HStack(alignment: .firstTextBaseline, spacing: Spacing.l) {
            Text(TranscriptRules.timecode(line.start))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .frame(width: Layout.timecodeWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.s) {
                if showFrench {
                    Text(Self.marked(line.french, uncertain: markUncertain ? TranscriptRules.markedWords(line) : []))
                        .font(.system(size: max(13, fontSize - 4)))
                        .foregroundStyle(.secondary).lineSpacing(3)
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
        .padding(.vertical, Spacing.l).padding(.horizontal, Spacing.s)
        .background {
            if highlighted { RoundedRectangle(cornerRadius: Radius.small).fill(Color.accentColor.opacity(0.12)) }
        }
        .overlay(alignment: .bottom) { Divider().padding(.leading, Layout.timecodeWidth + Spacing.l + Spacing.s) }
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
            Text(line.chinese).font(.system(size: fontSize)).lineSpacing(5).help(sourceHelp)
            if isFallback || isPending {
                HStack(spacing: Spacing.xs) {
                    if isPending { ProgressView().controlSize(.mini); Text(isFallback ? "正在用 Gemma 改进译文…" : "正在重新翻译…") }
                    else { Image(systemName: "arrow.triangle.2.circlepath"); Text(line.backend) }
                }
                .font(.caption).foregroundStyle(isPending ? Color.secondary : Color.orange)
            }
        } else if isPending || !line.isFinal {
            HStack(spacing: Spacing.xs) { ProgressView().controlSize(.mini); Text(line.isFinal ? "正在翻译…" : "正在识别…") }
                .font(.caption).foregroundStyle(.secondary)
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

/// Floating capture controls. Glass belongs to the controls only; the status text
/// sits on the scroll edge effect so captions stay readable underneath.
struct TransportBar: View {
    @Bindable var controller: ClassController
    let runtime: ModelRuntime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.m) {
            status
            Spacer(minLength: Spacing.s)
            controls
        }
        .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.m)
        .animation(Motion.state(reduced: reduceMotion), value: controller.captureState)
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.s) {
                switch controller.captureState {
                case .recording:
                    Circle().fill(.red).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(TranscriptRules.timecode(controller.displayDuration)).font(.body.monospacedDigit().weight(.semibold))
                    LevelMeter(controller: controller)
                case .importing, .paused:
                    Text(TranscriptRules.timecode(controller.displayDuration)).font(.body.monospacedDigit().weight(.semibold))
                    Text(controller.status).foregroundStyle(.secondary).lineLimit(1)
                default:
                    Text(controller.status).lineLimit(1)
                }
            }
            .font(.callout)
            HStack(spacing: Spacing.xs) {
                Circle().fill(runtime.ready ? Color.green : Color.orange).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(detailText).lineLimit(1)
                Image(systemName: "lock.shield").padding(.leading, Spacing.xs).help("语音和课堂内容只在这台 Mac 上处理")
                    .accessibilityLabel("本机处理")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var detailText: String {
        if controller.pendingCount > 0, !controller.isRecording, controller.upgradableCount > 0 {
            return "正在用 Gemma 改进 \(controller.upgradableCount) 句备用译文"
        }
        if controller.pendingCount > 0 { return "\(controller.pendingCount) 段待翻译 · " + controller.translationMode }
        return runtime.ready ? controller.translationMode : runtime.status
    }

    private var controls: some View {
        GlassEffectContainer(spacing: Spacing.s) {
            HStack(spacing: Spacing.s) {
                switch controller.captureState {
                case .idle, .starting:
                    sourcePicker
                    Button { Task { await controller.start() } } label: {
                        if controller.isStarting {
                            HStack(spacing: Spacing.s) { ProgressView().controlSize(.small); Text("准备中…") }
                        } else {
                            Label("开始听课", systemImage: "record.circle")
                        }
                    }
                    .buttonStyle(.glassProminent)
                    .disabled(!controller.canToggleCapture)
                    .help("开始听课 ⌘R")
                case .recording, .paused, .stopping:
                    Button { Task { await controller.stop() } } label: { Label("结束", systemImage: "stop.fill") }
                        .buttonStyle(.glass).disabled(controller.isStopping).help("结束并保存 ⌘.")
                    Button { Task { await controller.toggleCapture() } } label: {
                        Label(controller.isPaused ? "继续" : "暂停", systemImage: controller.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.glassProminent).disabled(!controller.canToggleCapture)
                    .help(controller.isPaused ? "继续听课 ⌘R" : "暂停 ⌘R")
                case .importing:
                    Button { Task { await controller.stop() } } label: { Label("停止转写", systemImage: "stop.fill") }
                        .buttonStyle(.glass).help("停止导入，保留已转写的内容")
                }
            }
            .controlSize(.large)
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

/// Five-bar input meter. Reads only `level`, so it is the only view that updates
/// with each audio buffer; values change too often to animate.
struct LevelMeter: View {
    let controller: ClassController
    var body: some View {
        let level = CGFloat(controller.level)
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                let threshold = CGFloat(index) / 5
                Capsule()
                    .fill(level > threshold ? Color.accentColor : Color.secondary.opacity(0.3))
                    .frame(width: 3, height: 5 + CGFloat(index) * 2.5)
            }
        }
        .frame(height: 16)
        .accessibilityLabel("输入音量")
        .accessibilityValue(level > 0.05 ? "有声音" : "安静")
    }
}

/// Title block at the top of the transcript; scrolls away with the captions.
struct ClassHeader: View {
    let session: ClassSession
    private var meta: String {
        [session.created.formatted(.dateTime.year().month().day().hour().minute()), session.source,
         TranscriptRules.timecode(session.duration), "\(session.lines.count) 句"].joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(session.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            Text(meta).font(.callout).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.s).padding(.top, Spacing.s).padding(.bottom, Spacing.m)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}
