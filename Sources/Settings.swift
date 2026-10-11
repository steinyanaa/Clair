import SwiftUI
import AppKit

struct ClairSettings: View {
    @Bindable var controller: ClassController
    let runtime: ModelRuntime

    var body: some View {
        TabView {
            Tab("通用", systemImage: "gearshape") { GeneralSettings(controller: controller) }
            Tab("本地模型", systemImage: "cpu") { ModelSettings(controller: controller, runtime: runtime) }
        }
        .task { await runtime.refreshModels() }
    }
}

private struct GeneralSettings: View {
    @Bindable var controller: ClassController
    @AppStorage("appearance") private var appearance = AppearancePreference.system.rawValue
    @AppStorage("followsLatest") private var followsLatest = true

    var body: some View {
        Form {
            Section("显示") {
                Picker("外观", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("字幕字号", selection: $controller.fontSize) {
                    ForEach(ClassController.fontSizes, id: \.self) { Text("\(Int($0)) 点").tag($0) }
                }
                Toggle("显示法语原文", isOn: $controller.showFrench)
                Toggle(isOn: $controller.markUncertain) {
                    Text("标出识别存疑的词")
                    Text("用橙色虚线标出识别把握较低的实词，供对照原声核对。").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("自动跟随最新字幕", isOn: $followsLatest)
            }
            Section {
                Picker("默认音源", selection: $controller.source) {
                    ForEach(AudioSource.allCases) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                }
                .disabled(controller.locked || controller.isPaused)
            } header: { Text("听课") } footer: {
                Text("麦克风用于现场课堂；系统声音用于视频和网课。两种音源不同时混合。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("模型不可用时回退系统翻译", isOn: $controller.allowFallback)
                LabeledContent("系统备用翻译") {
                    if controller.backupReady {
                        Label("已准备", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("准备…") { controller.requestBackup() }
                    }
                }
            } header: { Text("翻译") } footer: {
                Text("Gemma 单次等待超过 5 秒或出错时使用本机系统翻译，这些译文会标注来源。").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("课堂记录") { Button("在 Finder 中打开") { open(controller.runtime.workspace.sessions) } }
                LabeledContent("模型文件") { Button("在 Finder 中打开") { open(controller.runtime.workspace.models) } }
            } header: { Text("文件") } footer: {
                Text("记录和模型保存在本机 Application Support/ClairClass 中。移到最近删除的课堂可在 App 内恢复。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func open(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}

private struct ModelSettings: View {
    let controller: ClassController
    let runtime: ModelRuntime
    @AppStorage("translationModel") private var translationModel = "translategemma:4b"
    @AppStorage("assistantModel") private var assistantModel = "gemma3:4b"
    @State private var modelToDelete: ModelOption?

    var body: some View {
        Form {
            Section {
                Picker("实时翻译", selection: $translationModel) { ForEach(ModelOption.translation) { Text($0.title).tag($0.id) } }
                    .disabled(controller.isRecording || runtime.downloadingModel != nil)
                ForEach(ModelOption.translation, content: modelRow)
            } header: { Text("翻译模型") } footer: {
                Text("24 GB 内存的 Mac 建议先用 4B。12B 尚未实测，可能超过实时翻译的 5 秒等待限制。").font(.caption).foregroundStyle(.secondary)
            }
            Section("课堂助手模型") {
                Picker("整理与问答", selection: $assistantModel) { ForEach(ModelOption.assistant) { Text($0.title).tag($0.id) } }
                    .disabled(controller.assistantBusy || runtime.downloadingModel != nil)
                ForEach(ModelOption.assistant, content: modelRow)
            }
            Section {
                LabeledContent("状态") {
                    HStack(spacing: Spacing.xs) {
                        Circle().fill(runtime.ready ? Color.green : Color.orange).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(runtime.status).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Button("检查并准备翻译服务") { Task { await runtime.prepare(); await runtime.refreshModels() } }.disabled(runtime.busy)
            } footer: {
                Label("仅在本机推理；模型只从官方 Ollama 仓库下载，并校验 SHA-256。", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: translationModel) { _, _ in Task { await runtime.prepare() } }
        .onChange(of: assistantModel) { _, _ in Task { await runtime.detectAssistant() } }
        .alert("删除本机模型？", isPresented: Binding(get: { modelToDelete != nil }, set: { if !$0 { modelToDelete = nil } }), presenting: modelToDelete) { model in
            Button("删除模型", role: .destructive) {
                Task {
                    do { try await runtime.removeModel(model.id) } catch { controller.error = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) {}
        } message: { model in Text("只删除 \(model.title) 的模型文件（\(model.size)），课堂记录保留，以后可以重新下载。") }
    }

    private func modelRow(_ model: ModelOption) -> some View {
        LabeledContent {
            if runtime.downloadingModel == model.id {
                HStack(spacing: Spacing.s) {
                    ProgressView(value: runtime.progress).frame(width: 90)
                    Text(runtime.progress.map { "\(Int($0 * 100))%" } ?? "准备中").font(.caption).monospacedDigit().frame(width: 44, alignment: .trailing)
                }
            } else if runtime.installedModels.contains(model.id) {
                HStack(spacing: Spacing.s) {
                    Label("已下载", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                    Button { modelToDelete = model } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("删除模型").accessibilityLabel("删除 \(model.title)")
                        .disabled(controller.isRecording || controller.assistantBusy || runtime.downloadingModel != nil)
                }
            } else {
                Button("下载") {
                    Task { await runtime.downloadModel(model.id); if model.id == LocalModel.name { await runtime.prepare() } }
                }
                .disabled(runtime.downloadingModel != nil || runtime.busy || controller.assistantBusy)
            }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(model.title)
                Text(model.size + " · " + model.purpose).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
