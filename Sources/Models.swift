import Foundation

struct ModelOption: Identifiable, Hashable {
    let id: String
    let title: String
    let size: String
    let purpose: String
    static let translation = [
        Self(id: "translategemma:4b", title: "TranslateGemma 4B", size: "约 3.3 GB", purpose: "实时翻译，速度优先"),
        Self(id: "translategemma:12b", title: "TranslateGemma 12B", size: "约 8.1 GB", purpose: "更大模型，翻译耗时较长")
    ]
    static let assistant = [
        Self(id: "gemma3:4b", title: "Gemma 3 4B", size: "约 3.4 GB", purpose: "整理、纪要和课堂问答"),
        Self(id: "gemma3:12b", title: "Gemma 3 12B", size: "约 8.1 GB", purpose: "更大模型，适合课后整理")
    ]
    static var all: [Self] { translation + assistant }
    static var selectedTranslation: String {
        let value = UserDefaults.standard.string(forKey: "translationModel") ?? "translategemma:4b"
        return translation.contains(where: { $0.id == value }) ? value : "translategemma:4b"
    }
    static var selectedAssistant: String {
        let value = UserDefaults.standard.string(forKey: "assistantModel") ?? "gemma3:4b"
        return assistant.contains(where: { $0.id == value }) ? value : "gemma3:4b"
    }
}
