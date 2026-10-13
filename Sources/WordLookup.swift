import Foundation
import NaturalLanguage

/// What a looked-up word or phrase means: a term from the class preset if there is one,
/// the plain sense (of the base form for a single word) and the sense in its sentence.
struct WordMeaning: Equatable, Sendable {
    var glossary: String?
    var plain: String?
    var inSentence: String?
    var backend = ""
    var isGrammar = false
}

enum WordLookup {
    private static let elisions = ["jusqu", "lorsqu", "puisqu", "qu", "l", "d", "j", "m", "n", "s", "t", "c"]

    /// Word selection keeps elided articles and pronouns attached (l’augmentation);
    /// the lookup is about the word after them.
    static func clean(_ phrase: String) -> String {
        let text = phrase.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard !text.contains(where: \.isWhitespace) else { return text }
        let lower = text.lowercased()
        for prefix in elisions {
            for mark in ["'", "’"] where lower.hasPrefix(prefix + mark) && text.count > prefix.count + 1 {
                return String(text.dropFirst(prefix.count + 1))
            }
        }
        return text
    }

    /// Keep the cleaned span in the original UTF-16 coordinates, including elisions.
    static func selection(in sentence: String, range: NSRange) -> (phrase: String, range: NSRange)? {
        guard let selected = Range(range, in: sentence), !selected.isEmpty,
              sentence.indices.contains(selected.lowerBound),
              selected.upperBound == sentence.endIndex || sentence.indices.contains(selected.upperBound) else { return nil }
        let raw = String(sentence[selected]), phrase = clean(raw)
        guard !phrase.isEmpty, let inner = raw.range(of: phrase, options: .backwards) else { return nil }
        let offset = NSRange(inner, in: raw)
        return (phrase, NSRange(location: range.location + offset.location, length: offset.length))
    }

    static func tag(of word: String, in sentence: String, range: NSRange, scheme: NLTagScheme) -> String? {
        guard !word.contains(where: \.isWhitespace), let span = Range(range, in: sentence),
              !span.isEmpty, String(sentence[span]) == word else { return nil }
        let tagger = NLTagger(tagSchemes: [scheme])
        tagger.string = sentence
        tagger.setLanguage(.french, range: sentence.startIndex..<sentence.endIndex)
        return tagger.tag(at: span.lowerBound, unit: .word, scheme: scheme).0?.rawValue
    }

    static func lemma(of word: String, in sentence: String, range: NSRange) -> String? {
        guard let lemma = tag(of: word, in: sentence, range: range, scheme: .lemma),
              lemma.lowercased() != word.lowercased() else { return nil }
        return lemma
    }

    // These are common uses, not a claim that a parser has resolved the sentence.
    // French clitics are too often assigned a nearby content word by the small model.
    static let grammar: [String: String] = [
        "en": "介词：在、用、以；代词：代替 de 引出的成分，可指其中一些。",
        "y": "副代词：在那里、到那里；也代替 à 引出的事物。",
        "dont": "关系代词：代替 de 引出的成分，可表示「……的」或「其中」。",
        "que": "连词：引导从句；关系代词：作宾语；也可用于疑问或感叹。",
        "de": "介词：的、从、关于；也用于数量和不定式前。",
        "à": "介词：到、在、向；也表示用途、方式或间接宾语。",
        "le": "定冠词：阳性单数；也可作直接宾语代词「他／它」。",
        "la": "定冠词：阴性单数；也可作直接宾语代词「她／它」。",
        "les": "定冠词：复数；也可作直接宾语代词「他们／它们」。",
        "un": "不定冠词：一个（阳性）；也表示数目一。",
        "une": "不定冠词：一个（阴性）；也表示数目一。",
        "du": "de 与 le 的缩合；也作部分冠词，表示不确定的量。",
        "des": "de 与 les 的缩合；也作复数不定冠词。",
        "au": "à 与 le 的缩合：到、在、向。",
        "aux": "à 与 les 的缩合：到、在、向。",
        "se": "自反代词：自己；也用于相互动作或代词式动词。",
        "ne": "否定标记：常与 pas、plus、jamais 连用；ne…que 表示「只」。",
        "pas": "与 ne 连用表示「不」；单独作名词时表示「步」。",
        "je": "人称代词：我。", "tu": "人称代词：你。",
        "il": "人称代词：他／它；也用于无人称结构。", "elle": "人称代词：她／它。",
        "ils": "人称代词：他们／它们。", "elles": "人称代词：她们／它们。",
        "nous": "人称代词：我们。", "vous": "人称代词：您／你们。",
        "on": "不定代词：人们、有人；口语中也指我们。",
        "ce": "指示限定词或代词：这、这个。", "ça": "指示代词：这、那个。",
        "qui": "关系或疑问代词：谁；引导关系从句时常作主语。",
        "et": "并列连词：和、并且。", "ou": "并列连词：或者。",
        "où": "疑问或关系副词：哪里；也指某地或某时。",
        "si": "连词：如果、是否；副词：如此；也用于反驳否定问句。"
    ]

    static func commonUsage(_ phrase: String, lexicalClass: String?) -> String? {
        // A noun such as «un pas» still needs its content-word translation.
        if lexicalClass == NLTag.noun.rawValue, phrase.lowercased() == "pas" { return nil }
        return grammar[phrase.lowercased()]
    }

    static func needsPlainOnly(_ phrase: String, lexicalClass: String?) -> Bool {
        guard !phrase.contains(where: \.isWhitespace) else { return false }
        return phrase.count <= 2 || [NLTag.preposition, .determiner, .pronoun, .conjunction, .particle]
            .contains { $0.rawValue == lexicalClass }
    }

    struct CacheKey: Hashable {
        let phrase: String
        let lemma: String?
        let sentence: String
        let range: NSRange
        let subject: Subject
        let topic: String
        let glossary: String
        let model: String
        let allowFallback: Bool
    }

    /// The in-sentence prompt sometimes answers with the whole sentence translated.
    static func looksLikeSentence(_ chinese: String, source: String) -> Bool {
        let sourcePunctuated = source.contains { ".,;:!?".contains($0) }
        if !sourcePunctuated, chinese.contains(where: { "。，；！？".contains($0) }) { return true }
        return chinese.count > max(10, source.split(separator: " ").count * 6)
    }

    static func acceptsContext(_ chinese: String, plain: String, source: String) -> Bool {
        let text = tidy(chinese)
        guard !text.isEmpty, text != plain, !looksLikeSentence(text, source: source) else { return false }
        // A longer version of the same Chinese head often includes an unselected modifier.
        if !plain.isEmpty, text.count >= plain.count + 2, text.contains(plain) { return false }
        return true
    }

    static func tidy(_ chinese: String) -> String {
        chinese.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "。")))
    }
}

extension ClassController {
    /// Looks up a word or phrase from a transcript line. Results are kept for the session.
    func lookUp(_ phrase: String, lemma: String?, in sentence: String, range: NSRange) async throws -> WordMeaning {
        try Task.checkCancellation()
        guard let span = Range(range, in: sentence), String(sentence[span]) == phrase else {
            throw AppError("所选文字已变化，请重新选择。")
        }
        if lookupCache.count >= 256 { lookupCache.removeAll() }
        let preset = self.preset
        let key = WordLookup.CacheKey(phrase: phrase, lemma: lemma, sentence: sentence, range: range,
            subject: preset.subject, topic: preset.cleanTopic, glossary: preset.glossary,
            model: LocalModel.name, allowFallback: allowFallback)
        if let cached = lookupCache[key] { return cached }
        translation.allowFallback = allowFallback
        var meaning = WordMeaning()
        let forms = Set([phrase.lowercased(), lemma?.lowercased()].compactMap { $0 })
        meaning.glossary = preset.terms.first { forms.contains($0.source.lowercased()) }?.target
        if meaning.glossary != nil {
            meaning.backend = "课堂术语"
            lookupCache[key] = meaning
            return meaning
        }
        let lexicalClass = WordLookup.tag(of: phrase, in: sentence, range: range, scheme: .lexicalClass)
        if let usage = WordLookup.commonUsage(phrase, lexicalClass: lexicalClass) {
            meaning.plain = usage; meaning.backend = "内置法语用法"; meaning.isGrammar = true
            lookupCache[key] = meaning
            return meaning
        }
        let plain = try await translation.lookUp(lemma ?? phrase, sentence: nil, preset: preset)
        try Task.checkCancellation()
        meaning.plain = WordLookup.tidy(plain.text); meaning.backend = plain.backend
        // Conjugated verbs often pull in their subject or auxiliary, even with markers.
        // Their dictionary form gives a safer isolated meaning at half the latency.
        if lexicalClass != NLTag.verb.rawValue,
           !WordLookup.needsPlainOnly(phrase, lexicalClass: lexicalClass),
           plain.backend != TranscriptRules.fallbackBackend,
           let used = try? await translation.lookUp(phrase, sentence: sentence, range: range, preset: preset),
           WordLookup.acceptsContext(used.text, plain: meaning.plain ?? "", source: phrase) {
            meaning.inSentence = WordLookup.tidy(used.text)
        }
        try Task.checkCancellation()
        lookupCache[key] = meaning
        return meaning
    }
}
