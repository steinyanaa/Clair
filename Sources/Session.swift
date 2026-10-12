import Foundation
import AppKit
import Translation
import UniformTypeIdentifiers
import Observation

struct TranscriptLine: Codable, Identifiable, Equatable {
    var id: String
    var start: Double
    var french: String
    var chinese = ""
    var backend = ""
    var isFinal = false
    var revision = 0
    var error: String?
    var latency: Double?
    /// End of the speech this line came from; used to decide whether a pause split a sentence.
    var end: Double?
    /// Recogniser confidence (0–1). Below `TranscriptRules.lowConfidence` the line is flagged.
    var confidence: Double?
    /// Words recognised with low confidence, in text order; underlined in the transcript.
    var uncertainWords: [String]?
}

struct ClassSession: Codable, Identifiable, Equatable {
    var id = UUID()
    var created = Date()
    var title = "法语课堂"
    var source = "麦克风"
    var lines: [TranscriptLine] = []
    var duration: Double = 0
    var projectID: UUID?
    var deletedAt: Date?
    var studyMessages: [StudyMessage]?
    /// Subject, topic and terms chosen for this class; nil means general.
    var preset: ClassPreset?
}

// SpeechAnalyzer can move the beginning of a volatile range past preceding
// silence when it finalizes. Retire the old range by audio overlap, not text:
// a lecturer is allowed to repeat the same sentence later.
struct SpeechDraftIndex {
    private var ranges: [String: Range<Double>] = [:]
    mutating func reconcile(anchor: String, event: SpeechEvent) -> [String] {
        let end = event.start + max(0.001, event.duration)
        let range = event.start..<end
        let removed = ranges.filter { key, old in
            key != anchor && min(old.upperBound, range.upperBound) - max(old.lowerBound, range.lowerBound) > 0.001
        }.map(\.key)
        for key in removed { ranges[key] = nil }
        ranges[anchor] = event.isFinal ? nil : range
        return removed
    }
}

enum TranscriptRules {
    static func hasSpeech(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
    }
    static func sentences(_ text: String) -> [String] {
        // Keep decimals and common French honorifics intact. Complete sentence
        // prefixes remain stable as a volatile speech result grows.
        let expression = try! NSRegularExpression(pattern: #"[.!?…]+\s+|\n+"#)
        let range = NSRange(text.startIndex..., in: text)
        var start = text.startIndex
        var parts: [String] = []
        for match in expression.matches(in: text, range: range) {
            guard let boundary = Range(match.range, in: text) else { continue }
            let piece = String(text[start..<boundary.upperBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            let word = piece.split(separator: " ").last.map(String.init) ?? ""
            if ["M.", "Mme.", "Mlle.", "Dr.", "Pr.", "etc."].contains(word) { continue }
            if !piece.isEmpty { parts.append(piece) }
            start = boundary.upperBound
        }
        let remainder = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty { parts.append(remainder) }
        return parts
    }
    /// Per-word threshold for content words. Calibrated on 928 aligned words from 16
    /// noisy test recordings: 2.7 marks per 100 words, 68 % of them real errors.
    /// Marking every word below 0.6 gave 11.7 per 100 at 47 %, and real microphone
    /// audio averages ~0.7, so function words and line averages are not used.
    static let uncertainWord = 0.5
    private static let stopWords: Set<String> = Set("""
        le la les l un une des du de d au aux et ou mais donc or ni car que qu qui quoi dont où ce cet cette ces c ça
        il ils elle elles on je j tu nous vous me m te t se s lui leur leurs y en ne n pas plus a ai as avons avez ont
        est es sont suis être été avait était avaient sur sous dans par pour avec sans à son sa ses mon ma mes ton ta
        tes notre nos votre vos si alors puis aussi très tout tous toute toutes comme oui non là cela ceci celui celle
        ceux celles quel quelle quels quelles lorsque quand chaque autre autres même mêmes
        """.split(whereSeparator: \.isWhitespace).map(String.init))
    /// Words that carry meaning; a doubtful article or pronoun rarely changes the sentence.
    static func isContentWord(_ word: String) -> Bool {
        let bare = word.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .punctuationCharacters)
        let core = bare.split(separator: "'").last.map(String.init) ?? bare
        let numeric = core.contains(where: \.isNumber) && core.allSatisfy { $0.isNumber || $0 == "," || $0 == "." }
        return !core.isEmpty && !stopWords.contains(core) && !numeric
    }
    /// Doubtful words worth showing: final lines only, content words only.
    static func markedWords(_ line: TranscriptLine) -> [String] {
        line.isFinal ? (line.uncertainWords ?? []).filter(isContentWord) : []
    }
    /// A line is called out only when several of its meaningful words are doubtful.
    static func isDoubtful(_ line: TranscriptLine) -> Bool {
        let marked = markedWords(line).count
        let content = line.french.split(separator: " ").filter { isContentWord(String($0)) }.count
        return marked >= 3 || (marked >= 2 && Double(marked) >= 0.25 * Double(max(1, content)))
    }
    /// An unfinished sentence waits this long for its continuation before translation.
    static let unfinishedHold: TimeInterval = 1.2
    static let fallbackBackend = "系统翻译回退"

    static func endsSentence(_ text: String) -> Bool {
        // French puts a (no-break) space before closing guillemets: "? »".
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: "»\"”')").union(.whitespacesAndNewlines))
        return trimmed.last.map { ".!?…".contains($0) } ?? false
    }
    static func startsAsContinuation(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespaces).first else { return false }
        return first.isLowercase || ",;:)–-".contains(first)
    }
    /// The recogniser splits a sentence wherever the speaker pauses. Translating the
    /// halves separately loses the sentence structure, so a final chunk that clearly
    /// continues an unfinished line is folded into it.
    static func shouldMerge(previous: TranscriptLine, next: TranscriptLine, maxCharacters: Int = 320) -> Bool {
        guard previous.isFinal, !endsSentence(previous.french),
              previous.french.count + next.french.count <= maxCharacters else { return false }
        let gap = next.start - (previous.end ?? previous.start)
        return gap <= 2 || (startsAsContinuation(next.french) && gap <= 6)
    }
    private static let functionWords: Set<String> = ["le", "la", "les", "un", "une", "des", "du", "de", "et", "mais", "ou", "donc",
        "car", "que", "qui", "il", "elle", "ils", "elles", "on", "nous", "vous", "ce", "cette", "ces", "en", "à", "pour", "avec",
        "dans", "sur", "par", "puis", "alors", "parce", "si", "quand", "comme"]
    static func join(_ first: String, _ second: String) -> String {
        let head = first.trimmingCharacters(in: .whitespacesAndNewlines)
        var tail = second.trimmingCharacters(in: .whitespacesAndNewlines)
        if let mark = tail.first, ",;:)".contains(mark) { return head + tail }
        // The recogniser capitalises each chunk; restore lower case for ordinary words.
        let word = tail.prefix(while: { $0.isLetter }).lowercased()
        if functionWords.contains(word), let first = tail.first { tail = first.lowercased() + tail.dropFirst() }
        return head + " " + tail
    }
    private static let fillers: Set<String> = ["euh", "heu", "euhm", "hum", "hmm", "hm", "bah", "ben", "hein", "mmh"]
    private static let stutterWords: Set<String> = ["le", "la", "les", "un", "une", "des", "du", "de", "et", "je", "il", "on", "ce"]
    /// Text sent to the translator: hesitations and stutters removed, wording otherwise untouched.
    static func translationSource(_ text: String) -> String {
        var words: [Substring] = []
        for word in text.split(separator: " ") {
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            if fillers.contains(bare) {
                // Keep sentence punctuation that was attached to the filler.
                if let mark = word.last, ".!?…".contains(mark), let last = words.popLast() { words.append(last + String(mark)) }
                continue
            }
            if stutterWords.contains(bare), let last = words.last, last.lowercased() == bare { continue }
            words.append(word)
        }
        return words.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ",;: ").union(.whitespaces))
    }
    static func mayApply(current: TranscriptLine, requested: TranscriptLine, sessionMatches: Bool) -> Bool {
        sessionMatches && current.id == requested.id && current.revision == requested.revision && current.french == requested.french
    }
    static func timecode(_ seconds: Double) -> String {
        let value = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", value / 60, value % 60)
    }
    static func plainText(_ session: ClassSession) -> String {
        session.title + "\n" + session.created.formatted(date: .abbreviated, time: .shortened) + "\n\n" +
        session.lines.map { "[\(timecode($0.start))]\n\($0.french)\n\($0.chinese.isEmpty ? ($0.error ?? "译文尚未完成") : $0.chinese)\n" }.joined(separator: "\n")
    }
    static func srt(_ session: ClassSession) -> String {
        func clock(_ t: Double) -> String {
            let ms = max(0, Int(t * 1000))
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
        }
        return session.lines.enumerated().map { index, line in
            let end = index + 1 < session.lines.count ? max(line.start + 0.5, session.lines[index + 1].start) : max(line.start + 2, session.duration)
            return "\(index + 1)\n\(clock(line.start)) --> \(clock(end))\n\(line.french)\n\(line.chinese)\n"
        }.joined(separator: "\n")
    }
}


enum CaptureState: Equatable {
    case idle, starting, recording, importing, paused, stopping
}

enum PreferenceKey {
    static let showFrench = "showFrench"
    static let fontSize = "fontSize"
    static let allowFallback = "allowFallback"
    static let source = "audioSource"
    static let lastClass = "lastClass"
    static let markUncertain = "markUncertainWords"
    static let lastPreset = "lastClassPreset"
}

@MainActor
@Observable
final class ClassController {
    static let fontSizes: [Double] = [17, 21, 26, 32]
    static let defaultFontSize = 21.0

    var session = ClassSession()
    var history: [ClassSession] = []
    var projects: [ClassProject] = []
    var assistantBusy = false
    var studyStatus = "本地课堂助手"
    @ObservationIgnored var studyTask: Task<Void, Never>?
    @ObservationIgnored var studyRequestID = UUID()
    var source: AudioSource = .system { didSet { UserDefaults.standard.set(source.rawValue, forKey: PreferenceKey.source) } }
    var isRecording = false
    var isPaused = false
    var isStarting = false
    var isStopping = false
    var isImporting = false
    var status = "准备好后，开始听课"
    var error: String?
    /// Input level for the meter only. Kept apart from `session` so the meter
    /// redraws itself and nothing else while audio arrives.
    var level: Float = 0
    /// Live length of a capture, ticking once a second; saved into `session` on write.
    var elapsed: Double = 0
    var translationMode = "Gemma 本地翻译"
    var showFrench = true { didSet { UserDefaults.standard.set(showFrench, forKey: PreferenceKey.showFrench) } }
    var fontSize = 21.0 { didSet { UserDefaults.standard.set(fontSize, forKey: PreferenceKey.fontSize) } }
    var allowFallback = true { didSet { UserDefaults.standard.set(allowFallback, forKey: PreferenceKey.allowFallback) } }
    var markUncertain = true { didSet { UserDefaults.standard.set(markUncertain, forKey: PreferenceKey.markUncertain) } }
    var backupConfiguration: TranslationSession.Configuration?
    var backupReady = false
    let runtime = ModelRuntime()
    let translation = TranslationService()
    /// Lines queued for translation, and the one currently being translated.
    /// Rows only show progress for these, never for work that was abandoned.
    private(set) var readyAt: [String: Date] = [:]
    private(set) var translatingLine: String?
    /// Fallback lines Gemma has already retried in this window, so failures are not looped.
    @ObservationIgnored private var upgradeTried: Set<String> = []
    @ObservationIgnored private var capture: SpeechCapture?
    @ObservationIgnored private(set) var captureID = UUID()
    @ObservationIgnored private var drafts = SpeechDraftIndex()
    /// Word lookups already answered, keyed by selection, preset and model.
    @ObservationIgnored var lookupCache: [WordLookup.CacheKey: WordMeaning] = [:]
    @ObservationIgnored private var captureOffset: Double = 0
    @ObservationIgnored private var captureStarted: Date?
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var elapsedTask: Task<Void, Never>?
    @ObservationIgnored private var securityScopedURL: URL?
    @ObservationIgnored private var initialized = false
    @ObservationIgnored private let library: LibraryStore

    init(workspace: WorkspaceConfiguration = .current()) {
        library = LibraryStore(workspace: workspace)
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PreferenceKey.showFrench) != nil { showFrench = defaults.bool(forKey: PreferenceKey.showFrench) }
        if defaults.object(forKey: PreferenceKey.allowFallback) != nil { allowFallback = defaults.bool(forKey: PreferenceKey.allowFallback) }
        if defaults.object(forKey: PreferenceKey.markUncertain) != nil { markUncertain = defaults.bool(forKey: PreferenceKey.markUncertain) }
        if let value = defaults.object(forKey: PreferenceKey.fontSize) as? Double, Self.fontSizes.contains(value) { fontSize = value }
        if let raw = defaults.string(forKey: PreferenceKey.source), let value = AudioSource(rawValue: raw) { source = value }
        loadHistory()
        // Restore before anything awaits: the window opens on the last class, and
        // a capture started during model warm-up can never be swapped out.
        restoreLastClass()
    }

    var preset: ClassPreset { session.preset ?? ClassPreset() }
    /// Changes the class preset. Later sentences are translated with it, and new
    /// classes start from the last one used.
    func setPreset(_ preset: ClassPreset) {
        guard session.deletedAt == nil else { return }
        session.preset = preset.isDefault ? nil : preset
        if let data = try? JSONEncoder().encode(preset) { UserDefaults.standard.set(data, forKey: PreferenceKey.lastPreset) }
        if !session.lines.isEmpty { scheduleSave() }
    }
    private var lastPreset: ClassPreset? {
        guard let data = UserDefaults.standard.data(forKey: PreferenceKey.lastPreset),
              let preset = try? JSONDecoder().decode(ClassPreset.self, from: data), !preset.isDefault else { return nil }
        return preset
    }
    /// Up to two finished sentences before a line, so the translator can resolve
    /// pronouns, ellipses and repeated terms. Bounded to keep the prompt short.
    func translationContext(before id: String) -> TranslationContext {
        var previous: [String] = []
        if let index = session.lines.firstIndex(where: { $0.id == id }) {
            for line in session.lines[..<index].reversed() where line.isFinal {
                let text = TranscriptRules.translationSource(line.french)
                guard TranscriptRules.hasSpeech(text) else { continue }
                if previous.joined().count + text.count > 400 { break }
                previous.insert(text, at: 0)
                if previous.count == 2 { break }
            }
        }
        return TranslationContext(preset: preset, previous: previous)
    }

    var pendingCount: Int { readyAt.count + (translatingLine == nil ? 0 : 1) }
    func isPending(_ id: String) -> Bool { readyAt[id] != nil || translatingLine == id }
    var locked: Bool { isRecording || isStarting || isStopping }
    /// Title for the start action: an open class with captions is continued, not replaced.
    var startTitle: String { isPaused || !session.lines.isEmpty ? "继续听课" : "开始听课" }
    var canToggleCapture: Bool { !isStarting && !isStopping && session.deletedAt == nil }
    var deletedCount: Int { history.filter { $0.deletedAt != nil }.count }
    var untranslatedCount: Int { session.lines.filter { $0.chinese.isEmpty && !isPending($0.id) }.count }
    var displayDuration: Double { isRecording && !isImporting ? max(elapsed, session.duration) : session.duration }
    var captureState: CaptureState {
        if isStopping { return .stopping }
        if isStarting { return .starting }
        if isRecording { return isImporting ? .importing : .recording }
        return isPaused ? .paused : .idle
    }

    func stepFontSize(by step: Int) {
        let index = Self.fontSizes.firstIndex(of: fontSize) ?? 1
        fontSize = Self.fontSizes[min(max(index + step, 0), Self.fontSizes.count - 1)]
    }

    func initialize() async {
        guard !initialized else { return }
        initialized = true
        do {
            if try await library.workspace.migrateLegacyData() { loadHistory(); restoreLastClass() }
        } catch { self.error = "已有记录或模型迁移失败：\(error.localizedDescription)" }
        await runtime.prepare(); await runtime.detectAssistant()
    }

    private func restoreLastClass() {
        guard session.lines.isEmpty, !locked, !isPaused,
              let saved = UserDefaults.standard.string(forKey: PreferenceKey.lastClass), let id = UUID(uuidString: saved),
              let record = history.first(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        session = record; elapsed = record.duration
    }

    func toggleCapture() async {
        // An audio file can only be stopped; pausing it would resume from the microphone.
        if isRecording { await stop(paused: !isImporting) } else { await start() }
    }

    func start() async {
        guard !isRecording, !isStarting, !isStopping, session.deletedAt == nil else { return }
        // A saved class continues where it ended; a new class starts from 新课堂 (⌘N).
        isStarting = true; error = nil; status = "正在准备法语语音识别…"
        defer { isStarting = false }
        captureID = UUID(); drafts = SpeechDraftIndex(); let token = captureID
        captureOffset = session.duration; elapsed = session.duration
        let capture = SpeechCapture(); self.capture = capture
        do {
            try await capture.start(source: source,
                event: { [weak self] event in self?.receive(event, token: token) },
                meter: { [weak self] value in if self?.captureID == token { self?.level = value } },
                failure: { [weak self] message in self?.captureFailed(message, token: token) })
            session.source = source.rawValue
            captureStarted = Date()
            isRecording = true; isPaused = false; status = "正在听课 · 法语 → 中文"
            elapsedTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self, let started = self.captureStarted else { break }
                    self.elapsed = self.captureOffset + Date().timeIntervalSince(started)
                }
            }
        } catch {
            await capture.stop()
            self.capture = nil; self.error = error.localizedDescription; status = "暂时无法开始听课"
        }
    }

    private func captureFailed(_ message: String, token: UUID) {
        guard token == captureID else { return }
        error = message
        if isRecording { Task { await stop(paused: false) } }
    }

    func stop(paused: Bool = false) async {
        guard !isStopping, isRecording || isPaused else { return }
        isStopping = true; status = "正在整理最后一段字幕…"
        isRecording = false
        elapsedTask?.cancel(); elapsedTask = nil
        if let started = captureStarted { session.duration = max(session.duration, captureOffset + Date().timeIntervalSince(started)) }
        captureStarted = nil
        await capture?.stop()
        capture = nil; captureID = UUID(); level = 0
        if let securityScopedURL { securityScopedURL.stopAccessingSecurityScopedResource() }
        securityScopedURL = nil
        // Any last volatile result is now a fixed segment; do not leave it in a
        // permanent partial state if the recognition stream ended without a final.
        for index in session.lines.indices where !session.lines[index].isFinal {
            session.lines[index].isFinal = true
            if session.lines[index].chinese.isEmpty { readyAt[session.lines[index].id] = Date() }
        }
        startWorker()
        elapsed = session.duration
        isPaused = paused; isStopping = false; isImporting = false
        status = paused ? "已暂停 · 可继续本次课堂" : "本次课堂已保存"
        save()
    }

    func receive(_ event: SpeechEvent, token: UUID) {
        guard token == captureID else { return }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranscriptRules.hasSpeech(text) else { return }
        let anchor = token.uuidString + ":" + String(Int64(event.start * 1000)) + ":"
        let replaced = drafts.reconcile(anchor: anchor, event: event)
        let replacedIDs = session.lines.filter { line in replaced.contains(where: { line.id.hasPrefix($0) }) }.map(\.id)
        session.lines.removeAll { replacedIDs.contains($0.id) }
        for id in replacedIDs { readyAt[id] = nil }
        // Hesitation-only pieces ("Euh…") carry nothing to translate.
        let parts = TranscriptRules.sentences(text).filter { TranscriptRules.hasSpeech(TranscriptRules.translationSource($0)) }
        let ids = Set(parts.indices.map { anchor + String($0) })
        let obsolete = session.lines.filter { $0.id.hasPrefix(anchor) && !ids.contains($0.id) }.map(\.id)
        session.lines.removeAll { obsolete.contains($0.id) }
        for id in obsolete { readyAt[id] = nil }
        var characters = 0
        let eventEnd = captureOffset + max(0, event.start) + max(0, event.duration)
        for (partIndex, part) in parts.enumerated() {
            let id = anchor + String(partIndex)
            let time = captureOffset + max(0, event.start) + max(0, event.duration) * Double(characters) / Double(max(1, text.count))
            characters += part.count + 1
            let end = partIndex + 1 < parts.count
                ? captureOffset + max(0, event.start) + max(0, event.duration) * Double(characters) / Double(max(1, text.count))
                : eventEnd
            let words = Set(part.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }).map(String.init))
            let doubtful = event.uncertainWords.filter { words.contains($0.lowercased()) }
            updateLine(id: id, time: time, end: end, text: part, isFinal: event.isFinal, confidence: event.confidence, uncertain: doubtful)
        }
        session.lines.sort { $0.start < $1.start }
        if event.isFinal { mergeContinuation(anchor: anchor) }
        session.duration = max(session.duration, captureOffset + event.start + event.duration)
        scheduleSave(); startWorker()
    }

    /// When a line may be translated: drafts wait for the recogniser to settle, and
    /// an unfinished sentence waits briefly for the chunk that completes it.
    private func translateAfter(_ text: String, isFinal: Bool) -> Date {
        guard isFinal else { return Date().addingTimeInterval(0.8) }
        return Date().addingTimeInterval(TranscriptRules.endsSentence(text) ? 0 : TranscriptRules.unfinishedHold)
    }

    private func updateLine(id: String, time: Double, end: Double, text: String, isFinal: Bool, confidence: Double?, uncertain: [String]) {
        if let index = session.lines.firstIndex(where: { $0.id == id }) {
            session.lines[index].start = time
            session.lines[index].end = end
            session.lines[index].confidence = confidence
            session.lines[index].uncertainWords = uncertain.isEmpty ? nil : uncertain
            if session.lines[index].french != text {
                session.lines[index].french = text
                session.lines[index].revision += 1
                session.lines[index].chinese = ""; session.lines[index].backend = ""; session.lines[index].error = nil
                readyAt[id] = translateAfter(text, isFinal: isFinal)
            }
            session.lines[index].isFinal = isFinal
            if isFinal, session.lines[index].chinese.isEmpty { readyAt[id] = translateAfter(text, isFinal: true) }
        } else {
            var line = TranscriptLine(id: id, start: time, french: text, isFinal: isFinal)
            line.end = end; line.confidence = confidence; line.uncertainWords = uncertain.isEmpty ? nil : uncertain
            session.lines.append(line)
            readyAt[id] = translateAfter(text, isFinal: isFinal)
        }
    }

    /// Folds the first sentence of a just-finalised chunk into the line before it
    /// when the speaker only paused mid-sentence, so the sentence is translated whole.
    private func mergeContinuation(anchor: String) {
        guard let index = session.lines.firstIndex(where: { $0.id == anchor + "0" }), index > 0 else { return }
        let previous = session.lines[index - 1], fragment = session.lines[index]
        guard !previous.id.hasPrefix(anchor), TranscriptRules.shouldMerge(previous: previous, next: fragment) else { return }
        let merged = TranscriptRules.join(previous.french, fragment.french)
        session.lines[index - 1].french = merged
        session.lines[index - 1].end = fragment.end
        session.lines[index - 1].revision += 1
        session.lines[index - 1].chinese = ""; session.lines[index - 1].backend = ""
        session.lines[index - 1].error = nil; session.lines[index - 1].latency = nil
        if let a = previous.confidence, let b = fragment.confidence { session.lines[index - 1].confidence = min(a, b) }
        let doubtful = (previous.uncertainWords ?? []) + (fragment.uncertainWords ?? [])
        session.lines[index - 1].uncertainWords = doubtful.isEmpty ? nil : doubtful
        session.lines.remove(at: index)
        readyAt[fragment.id] = nil
        readyAt[previous.id] = translateAfter(merged, isFinal: true)
    }

    func addText(_ french: String) {
        let clean = french.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, session.deletedAt == nil else { return }
        let id = UUID().uuidString
        session.lines.append(TranscriptLine(id: id, start: session.duration, french: clean, isFinal: true))
        readyAt[id] = Date(); startWorker(); scheduleSave()
    }

    /// A line translated by the system fallback that Gemma has not yet retried.
    private var upgradeCandidate: TranscriptLine? {
        guard !isRecording, !isStarting, runtime.ready, session.deletedAt == nil else { return nil }
        return session.lines.first { $0.backend == TranscriptRules.fallbackBackend && $0.isFinal && !upgradeTried.contains($0.id) }
    }
    var upgradableCount: Int { session.lines.filter { $0.backend == TranscriptRules.fallbackBackend }.count }

    private func startWorker() {
        guard worker == nil, !readyAt.isEmpty || upgradeCandidate != nil else { return }
        let sessionID = session.id
        worker = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.session.id == sessionID {
                let candidates = self.session.lines.filter { self.readyAt[$0.id] != nil }
                // Queue entries without a line can only be leftovers; never wait on them.
                if candidates.isEmpty { self.readyAt.removeAll() }
                if candidates.isEmpty {
                    // Nothing live to translate: let Gemma redo fallback lines, one at a
                    // time and never while capturing, so captions are never held up.
                    guard let line = self.upgradeCandidate else { break }
                    self.upgradeTried.insert(line.id)
                    self.translatingLine = line.id
                    let result = try? await LocalModel.generate(TranscriptRules.translationSource(line.french),
                                                                context: self.translationContext(before: line.id), patient: true)
                    if self.translatingLine == line.id { self.translatingLine = nil }
                    guard let result, !Task.isCancelled, self.session.id == sessionID,
                          let index = self.session.lines.firstIndex(where: { $0.id == line.id }),
                          TranscriptRules.mayApply(current: self.session.lines[index], requested: line, sessionMatches: true) else { continue }
                    self.session.lines[index].chinese = result.text
                    self.session.lines[index].backend = result.backend
                    self.session.lines[index].latency = result.seconds
                    self.scheduleSave()
                    continue
                }
                guard let line = candidates.first(where: { (self.readyAt[$0.id] ?? .distantFuture) <= Date() }) else {
                    try? await Task.sleep(for: .milliseconds(100)); continue
                }
                self.readyAt[line.id] = nil
                self.translatingLine = line.id
                self.translation.allowFallback = self.allowFallback
                let outcome: Result<TranslationResult, Error>
                let context = self.translationContext(before: line.id)
                do { outcome = .success(try await self.translation.translate(TranscriptRules.translationSource(line.french), context: context)) }
                catch { outcome = .failure(error) }
                if self.translatingLine == line.id { self.translatingLine = nil }
                guard !Task.isCancelled, self.session.id == sessionID,
                      let index = self.session.lines.firstIndex(where: { $0.id == line.id }),
                      TranscriptRules.mayApply(current: self.session.lines[index], requested: line, sessionMatches: true) else { continue }
                switch outcome {
                case .success(let result):
                    self.session.lines[index].chinese = result.text
                    self.session.lines[index].backend = result.backend
                    self.session.lines[index].latency = result.seconds
                    self.session.lines[index].error = nil
                    self.translationMode = result.backend
                case .failure(let error):
                    self.session.lines[index].error = error.localizedDescription
                    self.translationMode = "翻译暂不可用"
                }
                self.scheduleSave()
            }
            if self.session.id == sessionID { self.worker = nil; self.save() }
        }
    }

    func retryFailed() {
        guard session.deletedAt == nil else { return }
        for line in session.lines where line.chinese.isEmpty && !line.french.isEmpty && !isPending(line.id) { readyAt[line.id] = Date() }
        startWorker()
    }

    /// Translates one finished line again, keeping the current text until the new one arrives.
    func retranslate(_ id: String) {
        guard session.deletedAt == nil, !isPending(id),
              let line = session.lines.first(where: { $0.id == id }), line.isFinal else { return }
        readyAt[id] = Date(); startWorker()
    }

    func requestBackup() { backupConfiguration = TranslationSession.Configuration(source: Locale.Language(identifier: "fr"), target: Locale.Language(identifier: "zh-Hans")) }
    func backupPrepared(_ session: TranslationSession) {
        translation.attachFallback(session); backupReady = true; retryFailed()
    }

    private func resetTranslationQueue() {
        worker?.cancel(); worker = nil; readyAt.removeAll(); translatingLine = nil
    }

    func newSession() {
        guard !locked else { return }
        cancelStudy(); save(); resetTranslationQueue()
        session = ClassSession(); session.preset = lastPreset
        isPaused = false; error = nil; status = "准备好后，开始听课"; elapsed = 0
        translationMode = "Gemma 本地翻译"
    }
    func select(_ item: ClassSession) {
        // Re-selecting the open class must not reload an older saved copy over it.
        guard !locked, item.id != session.id else { return }
        cancelStudy(); save(); resetTranslationQueue()
        session = item; isPaused = false; status = "已打开课堂记录"; error = nil; elapsed = item.duration
        UserDefaults.standard.set(item.id.uuidString, forKey: PreferenceKey.lastClass)
        startWorker()
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }
    func save() {
        guard !session.lines.isEmpty else { return }
        if isRecording, !isImporting { session.duration = max(session.duration, elapsed) }
        // Switching between classes saves the one being left; skip it when unchanged.
        if let saved = history.first(where: { $0.id == session.id }), saved == session { return }
        do {
            try library.save(session)
            UserDefaults.standard.set(session.id.uuidString, forKey: PreferenceKey.lastClass)
            if let index = history.firstIndex(where: { $0.id == session.id }) { history[index] = session }
            else { history.insert(session, at: 0) }
        } catch { self.error = "记录保存失败：\(error.localizedDescription)" }
    }
    func loadHistory() {
        history = library.load()
        do { projects = try library.loadProjects() }
        catch { self.error = "项目目录读取失败：\(error.localizedDescription)" }
    }
    func createProject(_ name: String) -> UUID? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        let item = ClassProject(name: clean)
        do { try library.saveProjects(projects + [item]); projects.append(item); return item.id }
        catch { self.error = "项目创建失败：\(error.localizedDescription)"; return nil }
    }
    func renameProject(_ id: UUID, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        var next = projects; next[index].name = clean
        do { try library.saveProjects(next); projects = next }
        catch { self.error = "项目重命名失败：\(error.localizedDescription)" }
    }
    /// Deletes only the folder: its classes, including ones in Recently Deleted, become unfiled.
    func deleteProject(_ id: UUID) {
        guard !locked else { return }
        for record in history where record.projectID == id { editRecord(record.id, project: nil, move: true) }
        if session.projectID == id { session.projectID = nil }
        guard !history.contains(where: { $0.projectID == id }) else {
            error = "项目中的课堂未能全部移出，项目已保留。"; return
        }
        let next = projects.filter { $0.id != id }
        do { try library.saveProjects(next); projects = next; try library.removeProject(id) }
        catch { self.error = "项目删除失败：\(error.localizedDescription)" }
    }
    // Batch edits for a multi-selection. Each record goes through `editRecord`,
    // so the open class is saved first and a failure leaves the rest intact.
    func moveRecords(_ ids: Set<UUID>, to project: UUID?) {
        for id in ids { editRecord(id, project: project, move: true) }
    }
    func setDeleted(_ ids: Set<UUID>, _ deleted: Bool) {
        for id in ids { editRecord(id, deleted: deleted) }
    }
    /// Permanently deletes classes from Recently Deleted. Classes that are not in
    /// Recently Deleted are ignored, never purged.
    func purge(_ ids: Set<UUID>) {
        guard !locked else { return }
        let targets = history.filter { ids.contains($0.id) && $0.deletedAt != nil }
        if targets.contains(where: { $0.id == session.id }) {
            // Leave the class without saving it again first.
            cancelStudy(); resetTranslationQueue()
            session = ClassSession(); isPaused = false; elapsed = 0; status = "准备好后，开始听课"
        }
        var failed = 0
        for record in targets {
            do { try library.purge(record); history.removeAll { $0.id == record.id } }
            catch { failed += 1 }
        }
        if failed > 0 { error = "有 \(failed) 堂课未能彻底删除，仍保留在「最近删除」中。" }
    }
    func editRecord(_ id: UUID, title: String? = nil, project: UUID? = nil, move: Bool = false, deleted: Bool? = nil) {
        guard !locked else { return }
        if session.id == id { cancelStudy(); save() }
        guard var record = history.first(where: { $0.id == id }) else { return }
        if let title {
            let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }; record.title = clean
        }
        if move { record.projectID = project }
        if let deleted { record.deletedAt = deleted ? Date() : nil }
        do {
            try library.save(record)
            if let index = history.firstIndex(where: { $0.id == id }) { history[index] = record }
            if session.id == id {
                session = record
                if deleted == true { newSession() }
            }
        } catch { self.error = "记录更新失败：\(error.localizedDescription)" }
    }
    static func fileName(_ title: String) -> String {
        let clean = title.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "法语课堂" : clean
    }
    func export(srt: Bool) {
        guard !session.lines.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [srt ? UTType(filenameExtension: "srt") ?? .plainText : .plainText]
        panel.nameFieldStringValue = Self.fileName(session.title) + (srt ? ".srt" : ".txt")
        if panel.runModal() == .OK, let url = panel.url {
            do { try (srt ? TranscriptRules.srt(session) : TranscriptRules.plainText(session)).write(to: url, atomically: true, encoding: .utf8) }
            catch { self.error = "导出失败：\(error.localizedDescription)" }
        }
    }
    func importAudio() async {
        guard !locked else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await importAudioFile(url)
    }
    static func isAudioFile(_ url: URL) -> Bool {
        url.isFileURL && (UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) ?? false)
    }
    func importAudioFile(_ url: URL, realtime: Bool = false) async {
        guard !locked else { return }
        let project = session.projectID
        newSession(); session.projectID = project; session.title = url.deletingPathExtension().lastPathComponent; session.source = "音频文件"
        _ = url.startAccessingSecurityScopedResource(); securityScopedURL = url
        captureID = UUID(); drafts = SpeechDraftIndex(); let token = captureID; captureOffset = 0
        isStarting = true; error = nil; status = "正在准备音频转写…"
        let capture = SpeechCapture(); self.capture = capture
        do {
            try await capture.transcribeFile(url, realtime: realtime, event: { [weak self] event in self?.receive(event, token: token) },
                failure: { [weak self] message in self?.captureFailed(message, token: token) },
                completed: { [weak self] in
                    guard let self, self.captureID == token else { return }
                    self.isRecording = false; self.isImporting = false; self.capture = nil; self.captureID = UUID()
                    self.securityScopedURL?.stopAccessingSecurityScopedResource(); self.securityScopedURL = nil
                    self.elapsed = self.session.duration
                    self.status = "音频转写已完成，译文正在补齐"; self.save()
                })
            isRecording = true; isImporting = true; status = "正在转写音频文件…"
        } catch { self.error = error.localizedDescription; await capture.stop(); self.capture = nil; securityScopedURL?.stopAccessingSecurityScopedResource(); securityScopedURL = nil }
        isStarting = false
    }
    func shutdown() {
        cancelStudy(); save(); worker?.cancel(); saveTask?.cancel(); elapsedTask?.cancel()
        runtime.shutdown()
    }
}
