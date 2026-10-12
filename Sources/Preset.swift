import Foundation

/// What a class is about. The translator uses it to pick the right sense of
/// words that differ between fields (fonction = 函数 or 作用, corps = 域 or 身体).
enum Subject: String, Codable, CaseIterable, Identifiable, Sendable {
    case general, literature, science, economics, law, humanities, life, engineering, arts

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "通用"
        case .literature: "文学"
        case .science: "数理"
        case .economics: "经济"
        case .law: "法律"
        case .humanities: "历史哲学"
        case .life: "医学生物"
        case .engineering: "工程计算机"
        case .arts: "艺术"
        }
    }
    var symbol: String {
        switch self {
        case .general: "sparkles"
        case .literature: "book.closed"
        case .science: "function"
        case .economics: "chart.line.uptrend.xyaxis"
        case .law: "building.columns"
        case .humanities: "scroll"
        case .life: "leaf"
        case .engineering: "cpu"
        case .arts: "paintpalette"
        }
    }
    /// How the field is named to the translation model.
    var field: String? {
        switch self {
        case .general: nil
        case .literature: "French literature"
        case .science: "mathematics and physical sciences"
        case .economics: "economics"
        case .law: "law"
        case .humanities: "history and philosophy"
        case .life: "medicine and biology"
        case .engineering: "engineering and computer science"
        case .arts: "art and music"
        }
    }
}

/// Set before (or during) a class: the subject, an optional topic and an
/// optional term list ("corps = 域", one per line). Saved with the class.
struct ClassPreset: Codable, Equatable, Sendable {
    var subject: Subject = .general
    var topic = ""
    var glossary = ""

    var isDefault: Bool { subject == .general && cleanTopic.isEmpty && terms.isEmpty }
    var cleanTopic: String { topic.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// Glossary lines as (French, Chinese) pairs; accepts "=", "→", "：" or ":" as separator.
    var terms: [(source: String, target: String)] {
        glossary.split(whereSeparator: \.isNewline).compactMap { line in
            guard let separator = line.firstIndex(where: { "=→：:".contains($0) }) else { return nil }
            let source = line[..<separator].trimmingCharacters(in: .whitespaces)
            let target = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            return source.isEmpty || target.isEmpty ? nil : (source, target)
        }
    }
    /// Short label for the class header, e.g. "数理 · 线性代数".
    var label: String { cleanTopic.isEmpty ? subject.title : subject.title + " · " + cleanTopic }
}
