import Foundation

/// Brackets identify the exact UTF-16 selection, including repeated occurrences.
/// Accept short synonyms, but reject adjacent meanings and sentence translations.
enum LookupEvaluation {
    struct Sample {
        let marked: String
        let expected: [String]
        var forbidden: [String] = []
        var preset = ClassPreset()
        var sentence: String { marked.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") }
        var range: NSRange {
            let start = marked.firstIndex(of: "[")!, end = marked.firstIndex(of: "]")!
            return NSRange(location: marked[..<start].utf16.count, length: marked[marked.index(after: start)..<end].utf16.count)
        }
    }
    static let samples: [Sample] = [
        Sample(marked: "Le taux d’intérêt est passé de 2,5 % à 3,75 % [en] janvier.", expected: ["在"], forbidden: ["利率", "一月", "1月"]),
        Sample(marked: "Des exemples, nous [en] avons trois.", expected: ["代词", "其中"], forbidden: ["例子", "三个"]),
        Sample(marked: "Nous [y] allons demain.", expected: ["那里", "代词"], forbidden: ["明天"]),
        Sample(marked: "C’est le résultat [dont] nous parlons.", expected: ["关系代词", "其中", "的"], forbidden: ["结果", "说"]),
        Sample(marked: "Je pense [que] cette hypothèse est juste.", expected: ["连词", "引导"], forbidden: ["假设", "认为"]),
        Sample(marked: "Le livre [que] tu lis est utile.", expected: ["关系代词", "宾语", "的"], forbidden: ["书", "读"]),
        Sample(marked: "La concentration [de] la solution augmente.", expected: ["的", "介词"], forbidden: ["浓度"]),
        Sample(marked: "Nous allons [à] Paris.", expected: ["到", "向", "介词"], forbidden: ["巴黎"]),
        Sample(marked: "[Le] taux augmente.", expected: ["定冠词", "冠词"], forbidden: ["利率"]),
        Sample(marked: "La cellule [se] divise.", expected: ["自反", "代词"], forbidden: ["细胞"]),
        Sample(marked: "Cette preuve [ne] suffit pas.", expected: ["否定", "不", "没有"], forbidden: ["证明"]),
        Sample(marked: "La cellule [en] contient en janvier.", expected: ["代词", "其中"], forbidden: ["细胞", "一月", "1月"]),
        Sample(marked: "La cellule en contient [en] janvier.", expected: ["在", "介词"], forbidden: ["细胞", "一月", "1月"]),
        Sample(marked: "Il dit [que] le livre que tu lis est utile.", expected: ["连词", "引导"], forbidden: ["书", "说"]),
        Sample(marked: "Il dit que le livre [que] tu lis est utile.", expected: ["关系代词", "宾语", "的"], forbidden: ["书", "读"]),
        Sample(marked: "[L’augmentation] est rapide.", expected: ["增加", "增长", "上升"]),
        Sample(marked: "Le taux [d’intérêt] augmente.", expected: ["利息", "利率"], forbidden: ["增加"]),
        Sample(marked: "Je sais [qu’ils] arrivent.", expected: ["他们"], forbidden: ["到达", "知道"]),
        Sample(marked: "Elle mesure [l'accélération] du mobile.", expected: ["加速度"], forbidden: ["测量"]),
        Sample(marked: "Le coût augmente ; [en revanche], la qualité s’améliore.", expected: ["然而", "相反", "另一方面", "不过", "反过来"]),
        Sample(marked: "[Il y a] deux solutions.", expected: ["有", "存在"], forbidden: ["两个", "两种", "解决"]),
        Sample(marked: "Il faut vérifier [au lieu de] deviner.", expected: ["而不是", "代替", "而非"], forbidden: ["猜", "验证"]),
        Sample(marked: "Le [corps] des nombres réels est ordonné.", expected: ["域"], preset: ClassPreset(subject: .science, topic: "Algèbre")),
        Sample(marked: "Le [corps] humain contient plusieurs organes.", expected: ["身体", "人体", "躯体"], preset: ClassPreset(subject: .life)),
        Sample(marked: "On ajoute une [base] forte à la solution.", expected: ["碱"], forbidden: ["强"], preset: ClassPreset(subject: .science, topic: "Chimie")),
        Sample(marked: "Le [moment] de cette force dépend du bras de levier.", expected: ["力矩", "转矩"], preset: ClassPreset(subject: .science, topic: "Mécanique")),
        Sample(marked: "Cette [fonction] est dérivable.", expected: ["函数"], preset: ClassPreset(subject: .science)),
        Sample(marked: "Nous [allons] à la bibliothèque.", expected: ["去", "前往"], forbidden: ["图书馆", "我们"]),
        Sample(marked: "Ces calculs sont [faits] à la main.", expected: ["做", "完成", "进行", "制作"], forbidden: ["事实", "手工"]),
        Sample(marked: "La hausse [ralentit] les investissements.", expected: ["减缓", "放缓", "减慢", "放慢", "减速"], forbidden: ["投资"]),
        Sample(marked: "Cette augmentation peut [ralentir] les investissements.", expected: ["减缓", "放缓", "减慢", "放慢", "减速"], forbidden: ["可能", "能够", "可以", "投资"]),
        Sample(marked: "Cette augmentation peut [ralentir] les investissements et ralentir la croissance.", expected: ["减缓", "放缓", "减慢", "放慢", "减速"], forbidden: ["可能", "可以", "投资"]),
        Sample(marked: "Cette augmentation peut ralentir les investissements et [ralentir] la croissance.", expected: ["减缓", "放缓", "减慢", "放慢", "减速"], forbidden: ["可能", "可以", "增长"]),
        Sample(marked: "Les [faits] sont vérifiables, les calculs sont faits à la main.", expected: ["事实"]),
        Sample(marked: "Les faits sont vérifiables, les calculs sont [faits] à la main.", expected: ["做", "完成", "进行", "制作"], forbidden: ["事实", "手工"]),
        Sample(marked: "Le [corps] des nombres complexes est algébriquement clos.", expected: ["域"], preset: ClassPreset(subject: .science, glossary: "corps = 域"))
    ]

    /// Frozen 0.5.0 behavior for comparison; first-occurrence lookup is intentional here.
    @MainActor static func original(phrase: String, sample: Sample, service: TranslationService, marked: Bool) async throws -> WordMeaning {
        let first = (sample.sentence as NSString).range(of: phrase)
        let lemma = WordLookup.lemma(of: phrase, in: sample.sentence, range: first)
        let base = try await service.lookUp(lemma ?? phrase, sentence: nil, preset: sample.preset)
        let instructions = "You are a professional French (fr) to Chinese (zh-Hans) translator. Your goal is to accurately convey the meaning and nuances of the original French text while adhering to Chinese grammar, vocabulary, and cultural sensitivities.\nProduce only the Chinese translation, without any additional explanations or commentary. Preserve all dates, numbers, and negations. "
        var prompt = instructions + LocalModel.contextBlocks(TranslationContext(preset: sample.preset))
            + "The word or phrase is taken from this sentence (context only, do not translate it): «\(sample.sentence)»\n\n"
            + "Please translate only the following French word or phrase into Chinese, as it is used in that sentence. Answer with the Chinese word or phrase only:\n\n\n" + phrase
        if marked {
            let sentence = (sample.sentence as NSString).replacingCharacters(in: sample.range, with: "[" + phrase + "]")
            prompt = "Translate the French text inside square brackets into Simplified Chinese. The surrounding sentence only disambiguates its meaning. Translate exactly the bracketed span, excluding all words outside it, including modal and auxiliary verbs. Output only the short Chinese equivalent, no explanation.\n"
                + LocalModel.contextBlocks(TranslationContext(preset: sample.preset)) + "\nSentence: «" + sentence + "»\n\nTranslate only: " + phrase
        }
        let forms = Set([phrase.lowercased(), lemma?.lowercased()].compactMap { $0 })
        var meaning = WordMeaning(glossary: sample.preset.terms.first { forms.contains($0.source.lowercased()) }?.target,
                                  plain: WordLookup.tidy(base.text), backend: base.backend)
        if let used = try? await LocalModel.generate(prompt: prompt, limit: 48),
           !WordLookup.looksLikeSentence(used.text, source: phrase), WordLookup.tidy(used.text) != meaning.plain {
            meaning.inSentence = WordLookup.tidy(used.text)
        }
        return meaning
    }

    @MainActor static func run() async throws {
        guard let root = WorkspaceConfiguration.testRoot else { throw AppError("查词评测需要 -ClairClassDataRoot <临时目录>（模型服务端口 11449）。") }
        try await LocalModel.warmup()
        let controller = ClassController(workspace: WorkspaceConfiguration(projectRoot: root))
        controller.allowFallback = false
        defer { controller.shutdown() }
        var passed = 0, total = 0.0, failures = 0, contextualCount = 0
        var timings: [Double] = []
        for (index, sample) in samples.enumerated() {
            controller.session.preset = sample.preset
            controller.lookupCache.removeAll()
            let phrase = WordLookup.clean((sample.sentence as NSString).substring(with: sample.range))
            let start = Date()
            var actual = "", plain = "", contextual = "", failure = "", backend = ""
            do {
                let meaning: WordMeaning
                if CommandLine.arguments.contains("--baseline") || CommandLine.arguments.contains("--marked") {
                    meaning = try await original(phrase: phrase, sample: sample, service: controller.translation,
                                                 marked: CommandLine.arguments.contains("--marked"))
                } else {
                    let selection = WordLookup.selection(in: sample.sentence, range: sample.range)!
                    meaning = try await controller.lookUp(selection.phrase,
                        lemma: WordLookup.lemma(of: selection.phrase, in: sample.sentence, range: selection.range),
                        in: sample.sentence, range: selection.range)
                }
                backend = meaning.backend
                plain = meaning.plain ?? ""; contextual = meaning.inSentence ?? ""
                actual = meaning.inSentence ?? meaning.glossary ?? meaning.plain ?? ""
            } catch { failure = error.localizedDescription }
            let seconds = Date().timeIntervalSince(start); total += seconds; timings.append(seconds)
            if !failure.isEmpty { failures += 1 }; if !contextual.isEmpty { contextualCount += 1 }
            let grammar = index < 15 || index == 17
            let good = sample.expected.contains(where: { grammar ? actual.contains($0) : actual == $0 })
                && !sample.forbidden.contains(where: actual.contains) && failure.isEmpty
            if good { passed += 1 }
            TestMain.printJSON(["case": index + 1, "selection": sample.marked, "expected": sample.expected, "forbidden": sample.forbidden,
                                "actual": actual, "backend": backend, "plain": plain, "inSentence": contextual, "ok": good, "seconds": seconds, "error": failure])
            fflush(stdout)
        }
        TestMain.printJSON(["lookup": "complete", "model": LocalModel.name, "passed": passed, "total": samples.count,
                            "accuracy": Double(passed) / Double(samples.count), "meanSeconds": total / Double(samples.count), "maxSeconds": timings.max() ?? 0,
                            "overHalfSecond": timings.filter { $0 > 0.5 }.count, "inSentenceCount": contextualCount,
                            "errors": failures, "mode": CommandLine.arguments.contains("--baseline") ? "baseline" : (CommandLine.arguments.contains("--marked") ? "marked" : "current")])
        if failures > 0 { throw AppError("查词评测有 \(failures) 项服务错误。") }
    }
}
