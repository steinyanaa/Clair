import SwiftUI
import AppKit
import Translation

extension Notification.Name { static let clairCommand = Notification.Name("ClairClass.command") }

/// Menu commands that change the main window's view state. The app has a single
/// main window, so commands reach it by notification.
enum WindowCommand: Equatable {
    case newClass, newProject, renameClass, importAudio, palette, translateText, findClasses
    case showTranscript, showAssistant, toggleCapture, exportText, exportSubtitles, openSettings
    case trashSelection, restoreSelection, purgeSelection, emptyTrash
    case study(StudyAction)
    case open(UUID)

    func send() { NotificationCenter.default.post(name: .clairCommand, object: self) }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "跟随系统"; case .light: "浅色"; case .dark: "深色" }
    }
    /// Applied app-wide so Settings, sheets and open/save panels match the main window.
    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

@main
struct ClairClassApp: App {
    @State private var controller = ClassController()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        Window("Clair", id: "main") {
            ClassWindow(controller: controller, runtime: controller.runtime)
                .frame(minWidth: 1000, minHeight: 640)
                .tint(Palette.clay)
                .containerBackground(Palette.canvas, for: .window)
                .task { delegate.controller = controller; await controller.initialize() }
        }
        .defaultSize(width: 1260, height: 800)
        .windowToolbarStyle(.unified)
        .commands { ClairCommands(controller: controller) }
        Settings { ClairSettings(controller: controller, runtime: controller.runtime).frame(width: 600, height: 640).tint(Palette.clay) }
    }
}

struct ClairCommands: Commands {
    let controller: ClassController
    @AppStorage("followsLatest") private var followsLatest = true
    @FocusedValue(\.classTargets) private var targets

    private var studyAvailable: Bool {
        !controller.session.lines.isEmpty && controller.session.deletedAt == nil && !controller.assistantBusy
    }
    private var captureTitle: String {
        switch controller.captureState {
        case .recording: "暂停"
        case .importing: "停止转写"
        case .paused: "继续听课"
        default: controller.startTitle
        }
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新课堂") { WindowCommand.newClass.send() }.keyboardShortcut("n").disabled(controller.locked)
            Button("新项目文件夹…") { WindowCommand.newProject.send() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("导入音频…") { WindowCommand.importAudio.send() }.keyboardShortcut("o").disabled(controller.locked)
        }
        CommandGroup(after: .saveItem) {
            Button("导出双语文本…") { controller.export(srt: false) }.keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(controller.session.lines.isEmpty)
            Button("导出字幕 SRT…") { controller.export(srt: true) }.disabled(controller.session.lines.isEmpty)
            Button("导出课堂笔记…") { controller.exportStudy() }
                .disabled(!(controller.session.studyMessages ?? []).contains { $0.state == "complete" })
        }
        CommandGroup(after: .textEditing) {
            Button("搜索课堂…") { WindowCommand.findClasses.send() }.keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandGroup(before: .toolbar) {
            Button("转录") { WindowCommand.showTranscript.send() }.keyboardShortcut("1")
            Button("课堂助手") { WindowCommand.showAssistant.send() }.keyboardShortcut("2")
            Divider()
            Toggle("显示法语原文", isOn: Bindable(controller).showFrench)
            Toggle("自动跟随最新字幕", isOn: $followsLatest)
            Divider()
            Button("放大字幕") { controller.stepFontSize(by: 1) }.keyboardShortcut("+")
                .disabled(controller.fontSize >= ClassController.fontSizes.last!)
            Button("缩小字幕") { controller.stepFontSize(by: -1) }.keyboardShortcut("-")
                .disabled(controller.fontSize <= ClassController.fontSizes.first!)
            Button("默认字号") { controller.fontSize = ClassController.defaultFontSize }.keyboardShortcut("0")
            Divider()
        }
        CommandMenu("课堂") {
            Button(captureTitle) { Task { await controller.toggleCapture() } }
                .keyboardShortcut("r").disabled(!controller.canToggleCapture)
            Button("结束听课") { Task { await controller.stop() } }.keyboardShortcut(".")
                .disabled(!(controller.isRecording || controller.isPaused) || controller.isStopping)
            Divider()
            Button("重命名课堂…") { WindowCommand.renameClass.send() }.disabled(controller.session.lines.isEmpty || controller.locked)
            let count = targets?.count ?? 0
            let suffix = count > 1 ? " \(count) 堂课" : ""
            if targets?.deleted == true {
                Button("恢复" + suffix) { WindowCommand.restoreSelection.send() }.disabled(controller.locked)
                Button("彻底删除" + suffix + "…") { WindowCommand.purgeSelection.send() }.disabled(controller.locked)
            } else {
                Button("移到最近删除" + suffix) { WindowCommand.trashSelection.send() }.disabled(controller.locked || count == 0)
            }
            Button("清空最近删除…") { WindowCommand.emptyTrash.send() }.disabled(controller.locked || targets?.canEmptyTrash != true)
            Divider()
            ForEach([StudyAction.organize, .minutes, .terms]) { action in
                Button(action.rawValue) { WindowCommand.study(action).send() }.disabled(!studyAvailable)
            }
            Divider()
            Button("试译法语文字…") { WindowCommand.translateText.send() }.disabled(controller.session.deletedAt != nil)
            Button("重试未完成译文") { controller.retryFailed() }
                .disabled(controller.untranslatedCount == 0 || controller.session.deletedAt != nil)
            Divider()
            Button("搜索命令…") { WindowCommand.palette.send() }.keyboardShortcut("k")
        }
        CommandGroup(replacing: .help) {
            Button("Clair 使用说明") {
                if let url = Bundle.main.url(forResource: "使用说明", withExtension: "txt") { NSWorkspace.shared.open(url) }
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: ClassController?
    private var quitting = false
    private var windowObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppearancePreference(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "")?.apply()
        // Closing the main window ends the class and quits: capture never runs without a window.
        windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow, window.identifier?.rawValue == "main" else { return }
                NSApplication.shared.terminate(nil)
            }
        }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        sender.windows.first(where: { $0.identifier?.rawValue == "main" })?.makeKeyAndOrderFront(nil)
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting, let controller else { return .terminateNow }
        quitting = true
        Task { @MainActor in
            if controller.isRecording || controller.isPaused { await controller.stop() }
            controller.shutdown(); sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
