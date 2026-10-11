import Foundation

struct ClassProject: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var created = Date()
}

struct LibraryStore {
    let workspace: WorkspaceConfiguration
    private var projectsFile: URL { workspace.root.appendingPathComponent("ClairClassData/projects.json") }
    func loadProjects() throws -> [ClassProject] {
        guard FileManager.default.fileExists(atPath: projectsFile.path) else { return [] }
        return try JSONDecoder().decode([ClassProject].self, from: Data(contentsOf: projectsFile))
    }
    func saveProjects(_ projects: [ClassProject]) throws {
        try write(JSONEncoder().encode(projects), to: projectsFile)
        for project in projects {
            let directory = workspace.sessions.appendingPathComponent("Projects/" + project.id.uuidString)
            try write(JSONEncoder().encode(project), to: directory.appendingPathComponent("project.json"))
        }
    }
    func files() -> [URL] {
        let enumerator = FileManager.default.enumerator(at: workspace.sessions, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }
    }
    func load() -> [ClassSession] {
        var latest: [UUID: (Date, ClassSession)] = [:]
        for file in files() {
            guard let data = try? Data(contentsOf: file), var record = try? JSONDecoder().decode(ClassSession.self, from: data) else { continue }
            // A pending generation cannot continue after process termination.
            if var messages = record.studyMessages {
                for i in messages.indices where messages[i].state == "pending" {
                    messages[i].state = "failed"; messages[i].text = "上次生成已中断，可以重试。"
                }
                record.studyMessages = messages
            }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if date >= (latest[record.id]?.0 ?? .distantPast) { latest[record.id] = (date, record) }
        }
        return latest.values.map(\.1).sorted { $0.created > $1.created }
    }
    func destination(for session: ClassSession) -> URL {
        var directory = workspace.sessions
        if session.deletedAt != nil { directory = directory.appendingPathComponent("RecentlyDeleted") }
        else if let project = session.projectID { directory = directory.appendingPathComponent("Projects/" + project.uuidString) }
        return directory.appendingPathComponent(session.id.uuidString + ".json")
    }
    func save(_ record: ClassSession) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let target = destination(for: record)
        let relocated = !FileManager.default.fileExists(atPath: target.path)
        try write(encoder.encode(record), to: target)
        // Autosave during a class rewrites the same file twice a second; only a
        // new location (first save, project move, delete/restore) needs the
        // library scan. Write first, then remove prior locations. A failed move
        // retains a valid copy; load chooses the newest version afterwards.
        guard relocated else { return }
        let targetPath = target.standardizedFileURL.resolvingSymlinksInPath().path
        for old in files() where old.standardizedFileURL.resolvingSymlinksInPath().path != targetPath && old.lastPathComponent == target.lastPathComponent {
            try FileManager.default.removeItem(at: old)
        }
    }
    /// Permanently removes every stored copy of a class. Only classes already in
    /// Recently Deleted may be purged; this cannot be undone.
    func purge(_ record: ClassSession) throws {
        guard record.deletedAt != nil else { throw AppError("只能彻底删除「最近删除」中的课堂。") }
        let name = record.id.uuidString + ".json"
        for file in files() where file.lastPathComponent == name { try FileManager.default.removeItem(at: file) }
    }
    /// Removes a project's marker file and its folder once no records remain in it.
    /// Records must already have been moved out; anything unexpected is left in place.
    func removeProject(_ id: UUID) throws {
        let manager = FileManager.default
        let directory = workspace.sessions.appendingPathComponent("Projects/" + id.uuidString)
        let marker = directory.appendingPathComponent("project.json")
        if manager.fileExists(atPath: marker.path) { try manager.removeItem(at: marker) }
        let remaining = (try? manager.contentsOfDirectory(atPath: directory.path)) ?? []
        if remaining.allSatisfy({ $0 == ".DS_Store" }), manager.fileExists(atPath: directory.path) {
            try manager.removeItem(at: directory)
        }
    }
    private func write(_ data: Data, to file: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        try data.write(to: file, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
