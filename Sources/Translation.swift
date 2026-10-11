import Foundation
import Translation
import CryptoKit
import Observation

struct TranslationResult: Sendable {
    let text: String
    let backend: String
    let seconds: Double
}

enum LocalModel {
    static var name: String { ModelOption.selectedTranslation }
    static let endpoint = URL(string: "http://127.0.0.1:11439")!
    // One connection pool for the whole class instead of a session per line.
    // Both limits stay at 5 s so a stalled model falls back as before.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }()
    /// For redoing fallback lines after class: nobody is waiting, so allow a cold model load.
    private static let patientSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        return URLSession(configuration: configuration)
    }()
    /// Keeps the translation model in memory through a long class with pauses, so a
    /// cold reload never pushes a line past the 5 s live limit into the fallback.
    static let keepAlive = "2h"
    static func prompt(_ text: String) -> String {
        "You are a professional French (fr) to Chinese (zh-Hans) translator. Your goal is to accurately convey the meaning and nuances of the original French text while adhering to Chinese grammar, vocabulary, and cultural sensitivities.\nProduce only the Chinese translation, without any additional explanations or commentary. Preserve all dates, numbers, and negations. Please translate the following French text into Chinese:\n\n\n" + text
    }
    static func generate(_ text: String, patient: Bool = false) async throws -> TranslationResult {
        let started = Date()
        var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": name, "prompt": prompt(text), "stream": false, "keep_alive": keepAlive,
            "options": ["temperature": 0, "num_ctx": 2048, "num_predict": 512]
        ])
        let (data, response) = try await (patient ? patientSession : session).data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AppError("本地翻译服务尚未就绪。")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["response"] as? String, !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError("本地模型没有返回译文。")
        }
        if object["done_reason"] as? String == "length" { throw AppError("本地译文超出长度限制。") }
        return TranslationResult(text: output.trimmingCharacters(in: .whitespacesAndNewlines),
                                 backend: "Gemma 本地", seconds: Date().timeIntervalSince(started))
    }
    static func warmup() async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"; request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name, "stream": false, "keep_alive": keepAlive,
                  "options": ["num_ctx": 2048], "prompt": ""])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("模型加载失败。请重新准备本地翻译。") }
        _ = data
    }
}

@MainActor
final class TranslationService {
    var allowFallback = true
    private var fallbackSession: TranslationSession?
    func attachFallback(_ session: TranslationSession) {
        // The SwiftUI preparation session is scoped to its task; create a separate
        // installed-resource session for subsequent background requests.
        fallbackSession = TranslationSession(installedSource: Locale.Language(identifier: "fr"), target: Locale.Language(identifier: "zh-Hans"))
    }
    func translate(_ french: String) async throws -> TranslationResult {
        do { return try await LocalModel.generate(french) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            guard allowFallback else { throw error }
            let started = Date()
            if fallbackSession == nil {
                let source = Locale.Language(identifier: "fr")
                let target = Locale.Language(identifier: "zh-Hans")
                let status = await LanguageAvailability().status(from: source, to: target)
                guard status == .installed else {
                    throw AppError("本地翻译暂不可用，系统备用翻译尚未安装。请点击「准备备用翻译」。")
                }
                fallbackSession = TranslationSession(installedSource: source, target: target)
            }
            guard let fallbackSession else { throw error }
            let response = try await fallbackSession.translate(french)
            return TranslationResult(text: response.targetText, backend: TranscriptRules.fallbackBackend, seconds: Date().timeIntervalSince(started))
        }
    }
}

struct WorkspaceConfiguration: Codable {
    var projectRoot: String
    /// Launch-argument override (`-ClairClassDataRoot <path>`) for UI checks against
    /// fixture data. Read from the argument domain only, so it never persists.
    static var testRoot: String? {
        UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["ClairClassDataRoot"] as? String
    }
    static func current() -> WorkspaceConfiguration {
        if let testRoot { return Self(projectRoot: testRoot) }
        if Bundle.main.bundleIdentifier == "local.clairclass.mac" {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            return Self(projectRoot: support.appendingPathComponent("ClairClass").path)
        }
        if let url = Bundle.main.url(forResource: "workspace", withExtension: "json"),
           let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode(Self.self, from: data) {
            return decoded
        }
        return Self(projectRoot: FileManager.default.currentDirectoryPath)
    }
    var root: URL { URL(fileURLWithPath: projectRoot, isDirectory: true) }
    var sessions: URL { root.appendingPathComponent("ClairClassData/Sessions", isDirectory: true) }
    var models: URL { root.appendingPathComponent("models", isDirectory: true) }
    /// Returns true when records or models were copied, so callers reload only then.
    func migrateLegacyData() async throws -> Bool {
        guard Self.testRoot == nil, Bundle.main.bundleIdentifier == "local.clairclass.mac",
              let url = Bundle.main.url(forResource: "workspace", withExtension: "json"),
              let data = try? Data(contentsOf: url), let old = try? JSONDecoder().decode(Self.self, from: data), old.projectRoot != projectRoot else { return false }
        let target = root
        return try await Task.detached {
            let manager = FileManager.default
            var copied = false
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            for name in ["ClairClassData", "models"] {
                let source = old.root.appendingPathComponent(name); let destination = target.appendingPathComponent(name)
                guard manager.fileExists(atPath: source.path), !manager.fileExists(atPath: destination.path) else { continue }
                // Complete the copy before publishing it. Originals remain intact.
                let staging = target.appendingPathComponent(name + ".migration")
                if manager.fileExists(atPath: staging.path) { try manager.removeItem(at: staging) }
                try manager.copyItem(at: source, to: staging); try manager.moveItem(at: staging, to: destination)
                copied = true
            }
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
            return copied
        }.value
    }
}

private final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let progress: @Sendable (Double) -> Void
    var continuation: CheckedContinuation<Void, Error>?
    var session: URLSession?
    var finished = false
    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination; self.progress = progress
    }
    func run(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForResource = 3600
            config.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            self.session = session
            session.downloadTask(with: url).resume()
        }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("模型文件下载失败。请检查网络后重试。") }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
            finished = true
            continuation?.resume(); continuation = nil
        } catch { finished = true; continuation?.resume(throwing: error); continuation = nil }
        session.finishTasksAndInvalidate()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !finished, let error {
            finished = true; continuation?.resume(throwing: error); continuation = nil
            session.finishTasksAndInvalidate()
        }
    }
}

@MainActor
@Observable
final class ModelRuntime {
    var status = "本地翻译待准备"
    var ready = false
    var busy = false
    var progress: Double?
    var assistantReady = false
    var assistantPreparing = false
    var assistantStatus = "课堂助手待准备"
    var installedModels: Set<String> = []
    var downloadingModel: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var log: FileHandle?
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var prepareAgain = false
    let workspace = WorkspaceConfiguration.current()

    func prepare(downloadIfMissing: Bool = false) async {
        // A model switch while loading must not be dropped: run once more after.
        guard !busy else { prepareAgain = true; return }
        busy = true; ready = false
        await load(downloadIfMissing: downloadIfMissing)
        busy = false; progress = nil
        if prepareAgain { prepareAgain = false; await prepare() }
    }

    private func load(downloadIfMissing: Bool) async {
        do {
            status = "正在启动本地翻译…"
            try await ensureServer()
            if !(try await hasModel()) {
                guard downloadIfMissing else { status = "请在设置中下载所选翻译模型"; return }
                try await installModel()
            }
            status = "正在加载翻译模型…"
            try await LocalModel.warmup()
            ready = true; status = "Gemma 本地翻译已就绪"
            if heartbeat == nil {
                heartbeat = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(5))
                        guard !Task.isCancelled, let self else { return }
                        if self.ready, !(await self.healthy()) {
                            // The model server died (crash, memory pressure): restart it so
                            // the rest of the class goes back to Gemma instead of the fallback.
                            self.ready = false; self.status = "本地翻译连接中断，正在自动恢复…"
                            await self.prepare()
                        }
                    }
                }
            }
        } catch { status = error.localizedDescription }
    }

    private func healthy() async -> Bool {
        var request = URLRequest(url: LocalModel.endpoint.appendingPathComponent("api/version"))
        request.timeoutInterval = 1
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse)?.statusCode == 200
    }
    func detectAssistant() async { await refreshModels(); assistantReady = installedModels.contains(StudyModel.name) }
    func refreshModels() async {
        guard let (data, _) = try? await URLSession.shared.data(from: LocalModel.endpoint.appendingPathComponent("api/tags")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return }
        installedModels = Set(models.compactMap { $0["name"] as? String })
    }
    func downloadModel(_ name: String) async {
        guard downloadingModel == nil, !busy, !assistantPreparing else { return }
        downloadingModel = name; progress = nil
        defer { downloadingModel = nil; progress = nil }
        do { try await ensureServer(); try await installModel(name); await refreshModels(); assistantReady = installedModels.contains(StudyModel.name) }
        catch { status = error.localizedDescription }
    }
    func removeModel(_ name: String) async throws {
        var request = URLRequest(url: LocalModel.endpoint.appendingPathComponent("api/delete"))
        request.httpMethod = "DELETE"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": name])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw AppError("模型删除失败。") }
        await refreshModels(); assistantReady = installedModels.contains(StudyModel.name)
        if name == LocalModel.name { ready = false; status = "翻译模型未下载" }
    }
    func prepareAssistant(downloadIfMissing: Bool = false) async throws {
        guard !assistantPreparing else { throw AppError("课堂助手模型正在准备，请稍候。") }
        assistantPreparing = true
        defer { assistantPreparing = false }
        do {
            try await ensureServer()
            if !(try await hasModel(StudyModel.name)) {
                assistantReady = false
                guard downloadIfMissing else { throw AppError("请先在设置中下载约 3.4 GB 的课堂助手模型。") }
                assistantStatus = "正在下载课堂助手模型…"
                try await installModel(StudyModel.name)
            }
            assistantReady = true; assistantStatus = "Gemma 3 4B 课堂助手已就绪"
        } catch { assistantStatus = error.localizedDescription; throw error }
    }
    private func ensureServer() async throws {
        if await healthy() { return }
        guard let resources = Bundle.main.resourceURL else { throw AppError("本地翻译组件缺失。") }
        let executable = resources.appendingPathComponent("Ollama/ollama")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw AppError("本地翻译组件缺失，请重新构建 App。") }
        try FileManager.default.createDirectory(at: workspace.models, withIntermediateDirectories: true)
        let logs = workspace.root.appendingPathComponent("ClairClassData/Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logfile = logs.appendingPathComponent("model-service.log")
        if !FileManager.default.fileExists(atPath: logfile.path) { FileManager.default.createFile(atPath: logfile.path, contents: nil) }
        try? log?.close()
        log = try FileHandle(forWritingTo: logfile); try log?.seekToEnd()
        let process = Process()
        process.executableURL = executable; process.arguments = ["serve"]
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11439"
        environment["OLLAMA_MODELS"] = workspace.models.path
        environment["OLLAMA_NO_CLOUD"] = "1"
        environment["OLLAMA_CONTEXT_LENGTH"] = "2048"
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "2"
        environment["OLLAMA_DEBUG"] = "false"
        environment["OLLAMA_DEBUG_LOG_REQUESTS"] = "false"
        process.environment = environment
        process.standardOutput = log; process.standardError = log
        try process.run(); self.process = process
        for _ in 0..<120 {
            if await healthy() { return }
            if !process.isRunning { throw AppError("本地翻译服务启动失败。") }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw AppError("本地翻译服务启动超时。")
    }
    private func hasModel(_ name: String = LocalModel.name) async throws -> Bool {
        let (data, _) = try await URLSession.shared.data(from: LocalModel.endpoint.appendingPathComponent("api/tags"))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]] else { return false }
        return models.contains { $0["name"] as? String == name }
    }
    private func installModel(_ model: String = LocalModel.name) async throws {
        let components = model.split(separator: ":")
        guard ModelOption.all.contains(where: { $0.id == model }), components.count == 2 else { throw AppError("不支持的模型。") }
        let base = URL(string: "https://registry.ollama.ai/v2/library/" + components[0])!
        let (manifestData, response) = try await URLSession.shared.data(from: base.appendingPathComponent("manifests/" + components[1]))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let manifest = try JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
              let config = manifest["config"] as? [String: Any], let layers = manifest["layers"] as? [[String: Any]] else {
            throw AppError("无法获取翻译模型，请检查网络。")
        }
        let blobs = workspace.models.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        let all = [config] + layers
        for (index, layer) in all.enumerated() {
            guard let digest = layer["digest"] as? String, digest.hasPrefix("sha256:"),
                  let size = layer["size"] as? Int64 else { throw AppError("模型清单格式错误。") }
            let hash = String(digest.dropFirst(7))
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { throw AppError("模型校验信息错误。") }
            let final = blobs.appendingPathComponent("sha256-" + hash)
            if FileManager.default.fileExists(atPath: final.path),
               (try? final.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int(size) { continue }
            status = "下载翻译模型 \(index + 1)/\(all.count)…"
            let temporary = final.appendingPathExtension("download")
            let downloader = ModelDownload(destination: temporary) { [weak self] fraction in
                Task { @MainActor [weak self] in self?.progress = fraction }
            }
            try await downloader.run(base.appendingPathComponent("blobs/" + digest))
            status = "正在校验模型文件…"
            let verified = try await Task.detached {
                let file = try FileHandle(forReadingFrom: temporary)
                defer { try? file.close() }
                var sha = SHA256(); var bytes: Int64 = 0
                while let chunk = try file.read(upToCount: 8 * 1024 * 1024), !chunk.isEmpty { sha.update(data: chunk); bytes += Int64(chunk.count) }
                return bytes == size && sha.finalize().map { String(format: "%02x", $0) }.joined() == hash
            }.value
            guard verified else { throw AppError("模型文件校验失败，请重新下载。") }
            if FileManager.default.fileExists(atPath: final.path) { try FileManager.default.removeItem(at: final) }
            try FileManager.default.moveItem(at: temporary, to: final)
        }
        let manifestURL = workspace.models.appendingPathComponent("manifests/registry.ollama.ai/library/" + components[0] + "/" + components[1])
        try FileManager.default.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manifestData.write(to: manifestURL, options: .atomic)
    }
    func shutdown() {
        heartbeat?.cancel(); heartbeat = nil
        if let process, process.isRunning { process.terminate() }
        process = nil; try? log?.close(); log = nil
    }
}
