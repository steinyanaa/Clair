import Foundation
import Speech
import Translation
import AVFoundation

@main
struct TestMain {
    @MainActor
    static func main() async {
        do {
            let arguments = CommandLine.arguments
            if arguments.contains("--lookup") { try await LookupEvaluation.run(); return }
            if arguments.contains("--fallback") {
                let service = TranslationService()
                let result = try await service.translate("Bonjour. Le cours commence à neuf heures.")
                guard result.backend == "系统翻译回退", !result.text.isEmpty else { throw AppError("Expected native fallback while local server is stopped") }
                printJSON(["fallback": "passed", "backend": result.backend, "chinese": result.text, "seconds": result.seconds])
                return
            }
            if let index = arguments.firstIndex(of: "--pipeline"), arguments.count > index + 1 {
                let controller = ClassController()
                let source = URL(fileURLWithPath: arguments[index + 1])
                let file = try AVAudioFile(forReading: source)
                let timeout = max(180, Double(file.length) / file.processingFormat.sampleRate + 60)
                await controller.importAudioFile(source, realtime: arguments.contains("--realtime"))
                let start = Date()
                var peakPending = 0
                var nextReport = start.addingTimeInterval(60)
                while (controller.isRecording || controller.pendingCount > 0) && Date().timeIntervalSince(start) < timeout {
                    peakPending = max(peakPending, controller.pendingCount)
                    if Date() >= nextReport {
                        printJSON(["elapsedSeconds": Int(Date().timeIntervalSince(start)), "segments": controller.session.lines.count,
                                   "pending": controller.pendingCount, "peakPending": peakPending])
                        fflush(stdout)
                        nextReport = Date().addingTimeInterval(60)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                if controller.isRecording { await controller.stop(); throw AppError("Pipeline timed out") }
                if let error = controller.error { throw AppError(error) }
                guard !controller.session.lines.isEmpty else { throw AppError("Pipeline produced no transcript") }
                guard controller.session.lines.allSatisfy({ !$0.chinese.isEmpty && $0.error == nil }) else {
                    throw AppError("Some pipeline segments have no translation: " + controller.session.lines.compactMap(\.error).joined(separator: "; "))
                }
                controller.save()
                let targetID = controller.session.id
                let fresh = ClassController()
                guard let saved = fresh.history.first(where: { $0.id == targetID }), saved.lines == controller.session.lines else {
                    throw AppError("Pipeline transcript did not survive reload")
                }
                let seconds = controller.session.lines.compactMap(\.latency)
                printJSON(["pipeline": "passed", "segments": saved.lines.count, "sourceSeconds": saved.duration,
                           "wallSeconds": Date().timeIntervalSince(start), "translationSeconds": seconds,
                           "peakPending": peakPending, "allGemma": saved.lines.allSatisfy({ $0.backend == "Gemma 本地" }), "persistedAndReloaded": true])
                controller.shutdown(); fresh.shutdown()
                return
            }
            if arguments.contains("--capabilities") {
                let locales = await SpeechTranscriber.supportedLocales.map(\.identifier)
                let installed = await SpeechTranscriber.installedLocales.map(\.identifier)
                let backup = await LanguageAvailability().status(from: Locale.Language(identifier: "fr"), to: Locale.Language(identifier: "zh-Hans"))
                printJSON(["speechAvailable": SpeechTranscriber.isAvailable, "frenchSupported": locales.filter { $0.hasPrefix("fr") },
                           "frenchInstalled": installed.filter { $0.hasPrefix("fr") }, "backupTranslation": String(describing: backup)])
                return
            }
            if let index = arguments.firstIndex(of: "--recognize"), arguments.count > index + 1 {
                guard await SpeechTranscriber.installedLocales.contains(where: { $0.identifier == "fr_FR" || $0.identifier == "fr-FR" }) else {
                    throw AppError("Offline recognition test requires installed French speech assets")
                }
                let capture = SpeechCapture()
                var events: [SpeechEvent] = []
                var arrivals: [Double] = []
                var failure: String?
                var finished = false
                let start = Date()
                try await capture.transcribeFile(URL(fileURLWithPath: arguments[index + 1]),
                    realtime: arguments.contains("--realtime"),
                    event: { event in
                        let elapsed = Date().timeIntervalSince(start)
                        let gap = elapsed - (arrivals.last ?? 0)
                        arrivals.append(elapsed); events.append(event)
                        printJSON(["speechArrivalSeconds": elapsed, "gapSeconds": gap, "final": event.isFinal,
                                   "audioEndSeconds": event.start + event.duration, "characters": event.text.count])
                    }, failure: { failure = $0; finished = true }, completed: { finished = true })
                while !finished && Date().timeIntervalSince(start) < 100 { try await Task.sleep(for: .milliseconds(100)) }
                if !finished { await capture.stop(); throw AppError("Speech test timed out") }
                if let failure { throw AppError(failure) }
                var textByStart: [Int: String] = [:]
                for event in events { textByStart[Int(event.start * 1000)] = event.text }
                let text = textByStart.keys.sorted().compactMap { textByStart[$0] }.joined(separator: " ")
                guard !text.isEmpty else { throw AppError("No speech recognized") }
                let finals = events.filter(\.isFinal).map { ["start": $0.start, "duration": $0.duration, "text": $0.text, "confidence": $0.confidence ?? -1,
                                                             "words": $0.wordConfidences.map { [$0.0, $0.1] as [Any] }] as [String: Any] }
                printJSON(["recognized": text, "events": events.count, "finals": finals, "seconds": Date().timeIntervalSince(start)])
                return
            }
            var line = TranscriptLine(id: "segment", start: 1.2, french: "Il ne faut pas confondre ces deux concepts.", isFinal: true)
            let requested = line
            try check(TranscriptRules.mayApply(current: line, requested: requested, sessionMatches: true))
            line.revision += 1; line.french = "Il ne faut pas confondre ces deux concepts économiques."
            try check(!TranscriptRules.mayApply(current: line, requested: requested, sessionMatches: true), "Stale speech revision must not overwrite new text")
            try check(!TranscriptRules.mayApply(current: requested, requested: requested, sessionMatches: false), "Old sessions must never receive a result")
            try check(TranscriptRules.timecode(125) == "02:05")
            try check(!TranscriptRules.hasSpeech(" . … "))
            try check(TranscriptRules.hasSpeech("2,5 %"))
            try check(TranscriptRules.hasSpeech("Économie"))
            try check(TranscriptRules.sentences("M. Dupont parle. Le taux est de 2.5 %. Il ne change pas.").count == 3)
            try check(TranscriptRules.sentences("Bonjour à tous. Nous étudions le climat. Cette phrase continue").count == 3)
            var drafts = SpeechDraftIndex()
            try check(drafts.reconcile(anchor: "silence:", event: SpeechEvent(start: 0, duration: 45.6, text: "Bonjour.", isFinal: false)).isEmpty)
            try check(drafts.reconcile(anchor: "corrected:", event: SpeechEvent(start: 31.62, duration: 13.98, text: "Bonjour.", isFinal: true)) == ["silence:"])
            try check(drafts.reconcile(anchor: "repeated:", event: SpeechEvent(start: 46, duration: 3, text: "Bonjour.", isFinal: false)).isEmpty)
            var sample = ClassSession(); sample.lines = [requested]; sample.duration = 4
            let data = try JSONEncoder().encode(sample)
            let decoded = try JSONDecoder().decode(ClassSession.self, from: data)
            try check(decoded.lines == sample.lines)
            try check(TranscriptRules.srt(sample).contains("00:00:01,200 --> 00:00:04,000"))
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ClairClassLibraryTest-" + UUID().uuidString)
            defer { try? FileManager.default.trashItem(at: temporary, resultingItemURL: nil) }
            let library = LibraryStore(workspace: WorkspaceConfiguration(projectRoot: temporary.path))
            let project = ClassProject(name: "经济学")
            try library.saveProjects([project]); try library.save(sample)
            sample.projectID = project.id; sample.title = "经济增长与发展"
            sample.studyMessages = [StudyMessage(role: "assistant", text: "复习笔记 [00:01]")]
            try library.save(sample)
            try check(library.files().count == 1 && library.load().first?.title == sample.title, "Project move must retain one readable record; files=\(library.files().count), records=\(library.load().count)")
            try check(FileManager.default.fileExists(atPath: library.destination(for: sample).path))
            sample.deletedAt = Date(); try library.save(sample)
            try check(library.load().first?.deletedAt != nil && library.files().count == 1)
            sample.deletedAt = nil; try library.save(sample)
            try check(library.load().first?.projectID == project.id && library.load().first?.studyMessages == sample.studyMessages)
            let loadedProjects = try library.loadProjects()
            try check(loadedProjects == [project])
            // Autosave in place keeps exactly one copy; deleting a project removes only its empty folder.
            sample.duration = 9; try library.save(sample); try library.save(sample)
            try check(library.files().count == 1 && library.load().first?.duration == 9, "In-place autosave must not duplicate records")
            let projectFolder = temporary.appendingPathComponent("ClairClassData/Sessions/Projects/" + project.id.uuidString)
            try library.removeProject(project.id)
            try check(FileManager.default.fileExists(atPath: projectFolder.path), "A project folder that still holds a class must be kept")
            sample.projectID = nil; try library.save(sample)
            try library.removeProject(project.id)
            try check(!FileManager.default.fileExists(atPath: projectFolder.path) && library.files().count == 1, "Empty project folder should be removed, class kept")
            try check(ClassController.fileName("经济/增长: 第1讲") == "经济-增长- 第1讲" && ClassController.fileName(" / ") == "-")
            // Markdown as the local model writes it, including the term table.
            let blocks = MarkdownBlock.parse("""
            ## 术语表
            | 法语 | 中文 | 含义 |
            |:---|---|---:|
            | croissance | 增长 | 生产增加 [00:09] |
            - 要点 **一**
              - 子项
            2. 第二步
            > 引用
            ---
            普通段落
            """)
            try check(blocks == [
                .heading(level: 2, text: "术语表"),
                .table([["法语", "中文", "含义"], ["croissance", "增长", "生产增加 [00:09]"]]),
                .bullet(text: "要点 **一**", depth: 0), .bullet(text: "子项", depth: 1),
                .numbered(marker: "2.", text: "第二步", depth: 0), .quote("引用"), .rule, .paragraph("普通段落")
            ], "Markdown blocks parsed incorrectly: \(blocks)")
            try check(MarkdownBlock.parse("#标签 不是标题") == [.paragraph("#标签 不是标题")])
            try check(MarkdownBlock.parse("*   经济增长 [00:09]") == [.bullet(text: "经济增长 [00:09]", depth: 0)], "Gemma-style bullets")
            // Permanent delete: only from Recently Deleted, every stored copy removed,
            // and an open class is discarded without being written back.
            let purgeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ClairClassPurgeTest-" + UUID().uuidString)
            defer { try? FileManager.default.trashItem(at: purgeRoot, resultingItemURL: nil) }
            let purgeLibrary = LibraryStore(workspace: WorkspaceConfiguration(projectRoot: purgeRoot.path))
            var live = ClassSession(); live.title = "保留"; live.lines = [requested]
            var trashed = ClassSession(); trashed.title = "删除"; trashed.lines = [requested]; trashed.deletedAt = Date()
            try purgeLibrary.save(live); try purgeLibrary.save(trashed)
            try check((try? purgeLibrary.purge(live)) == nil && purgeLibrary.files().count == 2, "A class outside Recently Deleted must never be purged")
            try purgeLibrary.purge(trashed)
            try check(purgeLibrary.load().map(\.id) == [live.id], "Purge must remove the trashed record only")
            var other = ClassSession(); other.title = "另一堂"; other.lines = [requested]
            try purgeLibrary.save(other)
            let batchController = ClassController(workspace: WorkspaceConfiguration(projectRoot: purgeRoot.path))
            batchController.purge([live.id, other.id])
            try check(batchController.history.count == 2, "Purge must ignore classes that are not deleted")
            batchController.setDeleted([live.id, other.id], true)
            try check(batchController.history.allSatisfy { $0.deletedAt != nil } && purgeLibrary.files().count == 2, "Batch trash")
            if let open = batchController.history.first(where: { $0.id == live.id }) { batchController.select(open) }
            try check(batchController.session.id == live.id, "Trashed class should open for review")
            batchController.purge([live.id, other.id])
            batchController.save()
            try check(batchController.history.isEmpty && purgeLibrary.files().isEmpty && batchController.session.lines.isEmpty,
                      "Batch purge must remove all copies and not resurrect the open class; files=\(purgeLibrary.files().count)")
            printJSON(["libraryAutosave": "passed", "projectRemoval": "passed", "markdownBlocks": "passed", "batchTrashAndPurge": "passed"])
            // Sentence repair and translation input.
            try check(TranscriptRules.endsSentence("Il ne change pas.") && TranscriptRules.endsSentence("« Vraiment ? »") && !TranscriptRules.endsSentence("Si les taux augmentent"))
            try check(TranscriptRules.join("Alors imaginez des liens plus forts", ", avec des gens.") == "Alors imaginez des liens plus forts, avec des gens.")
            try check(TranscriptRules.join("Si les taux augmentent", "Les ménages empruntent moins.") == "Si les taux augmentent les ménages empruntent moins.")
            try check(TranscriptRules.join("Nous partons demain pour", "Paris.") == "Nous partons demain pour Paris.")
            try check(TranscriptRules.translationSource("Euh, le le taux, euh, est stable.") == "le taux, est stable.", TranscriptRules.translationSource("Euh, le le taux, euh, est stable."))
            try check(TranscriptRules.translationSource("Nous nous sommes trompés.") == "Nous nous sommes trompés.")
            try check(!TranscriptRules.hasSpeech(TranscriptRules.translationSource("Hum.")))
            var first = TranscriptLine(id: "a", start: 0, french: "Si les taux augmentent", isFinal: true); first.end = 2
            let next = TranscriptLine(id: "b", start: 2.6, french: "les ménages empruntent moins.", isFinal: true)
            try check(TranscriptRules.shouldMerge(previous: first, next: next))
            var finished = first; finished.french = "Les taux augmentent."
            try check(!TranscriptRules.shouldMerge(previous: finished, next: next), "A finished sentence never absorbs the next one")
            var distant = next; distant.start = 12
            try check(!TranscriptRules.shouldMerge(previous: first, next: distant), "A long silence starts a new sentence")
            try check(TranscriptRules.translationHold("Si les taux", isFinal: false) == TranscriptRules.draftFragmentHold
                      && TranscriptRules.translationHold("Si les taux augmentent.", isFinal: false) == TranscriptRules.draftHold
                      && TranscriptRules.translationHold("Si les taux augmentent.", isFinal: true) == 0
                      && TranscriptRules.translationHold("Si les taux", isFinal: true) == TranscriptRules.unfinishedHold, "Translation holds")
            let mergeRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ClairClassMergeTest-" + UUID().uuidString)
            defer { try? FileManager.default.trashItem(at: mergeRoot, resultingItemURL: nil) }
            let captioner = ClassController(workspace: WorkspaceConfiguration(projectRoot: mergeRoot.path))
            captioner.newSession()
            captioner.receive(SpeechEvent(start: 0, duration: 2, text: "Si les taux augmentent", isFinal: true, confidence: 0.96), token: captioner.captureID)
            try check(captioner.isPending(captioner.session.lines[0].id), "Unfinished sentence waits for its continuation")
            captioner.receive(SpeechEvent(start: 2.5, duration: 2, text: "les ménages empruntent moins.", isFinal: true, confidence: 0.7), token: captioner.captureID)
            captioner.receive(SpeechEvent(start: 5, duration: 1, text: "Euh.", isFinal: true), token: captioner.captureID)
            captioner.receive(SpeechEvent(start: 7, duration: 1, text: "Moi.", isFinal: true, confidence: 0.95), token: captioner.captureID)
            try check(captioner.session.lines.map(\.french) == ["Si les taux augmentent les ménages empruntent moins.", "Moi."],
                      "Merged lines: \(captioner.session.lines.map(\.french))")
            try check(captioner.session.lines[0].confidence == 0.7 && captioner.session.lines[0].end == 4.5, "Merged line keeps the lowest confidence and the later end")
            captioner.shutdown()
            // A revised line keeps its earlier Chinese on screen, never in storage, until replaced.
            let reviser = ClassController(workspace: WorkspaceConfiguration(projectRoot: mergeRoot.path))
            reviser.newSession()
            reviser.receive(SpeechEvent(start: 0, duration: 2, text: "Les taux montent.", isFinal: false), token: reviser.captureID)
            let revisedID = reviser.session.lines[0].id
            reviser.session.lines[0].chinese = "旧译文"
            reviser.receive(SpeechEvent(start: 0, duration: 2.5, text: "Les taux augmentent.", isFinal: false), token: reviser.captureID)
            try check(reviser.session.lines[0].chinese == "旧译文" && reviser.isRevising(revisedID) && reviser.isPending(revisedID),
                      "Revised draft keeps its earlier Chinese while queued")
            try check(reviser.settledSession.lines[0].chinese.isEmpty, "Provisional Chinese is not stored")
            reviser.save()
            try check(LibraryStore(workspace: WorkspaceConfiguration(projectRoot: mergeRoot.path)).load()
                .first(where: { $0.id == reviser.session.id })?.lines.first?.chinese == "", "Saved class has no provisional Chinese")
            reviser.receive(SpeechEvent(start: 3, duration: 1, text: "et les ménages", isFinal: false), token: reviser.captureID)
            reviser.session.lines[1].chinese = "旧片段"
            reviser.receive(SpeechEvent(start: 0, duration: 2.5, text: "Les taux augmentent", isFinal: true), token: reviser.captureID)
            reviser.receive(SpeechEvent(start: 3, duration: 1.5, text: "et les ménages empruntent moins.", isFinal: true), token: reviser.captureID)
            try check(reviser.session.lines.count == 1 && reviser.session.lines[0].french == "Les taux augmentent et les ménages empruntent moins."
                      && !reviser.session.lines[0].chinese.isEmpty && reviser.isRevising(revisedID), "Merged line keeps its Chinese while re-translated")
            // Without the model or fallback the new translation fails: the earlier Chinese is withdrawn.
            let priorFallback = reviser.allowFallback
            reviser.allowFallback = false
            let waitStart = Date()
            while reviser.isPending(revisedID) && Date().timeIntervalSince(waitStart) < 15 { try await Task.sleep(for: .milliseconds(100)) }
            reviser.allowFallback = priorFallback
            let settled = reviser.session.lines[0]
            try check(!reviser.isRevising(revisedID) && settled.chinese != "旧译文" && settled.chinese != "旧片段"
                      && (!settled.chinese.isEmpty || settled.error != nil), "Provisional Chinese is replaced or withdrawn")
            reviser.shutdown()
            // Uncertain-word marks: content words of final lines only; a line is called out only when garbled.
            try check(TranscriptRules.isContentWord("étoiles") && TranscriptRules.isContentWord("l'augmentation"))
            try check(!TranscriptRules.isContentWord("Ce") && !TranscriptRules.isContentWord("qu'on") && !TranscriptRules.isContentWord("d'une") && !TranscriptRules.isContentWord("2,5"))
            var doubtful = TranscriptLine(id: "d", start: 0, french: "Ce n'est pas pour rien que l'on utilise le mot rompre", isFinal: true)
            doubtful.uncertainWords = ["Ce", "le", "rompre"]
            try check(TranscriptRules.markedWords(doubtful) == ["rompre"] && !TranscriptRules.isDoubtful(doubtful), "One doubtful content word is marked, the line is not called out")
            doubtful.isFinal = false
            try check(TranscriptRules.markedWords(doubtful).isEmpty, "Lines still being recognised are never marked")
            var garbled = TranscriptLine(id: "g", start: 0, french: "les banques sont étoiles si les taux augmente le ménage en train de loin", isFinal: true)
            garbled.uncertainWords = ["étoiles", "ménage", "train", "loin"]
            try check(TranscriptRules.isDoubtful(garbled))
            printJSON(["sentenceRepair": "passed", "fillerCleanup": "passed", "continuationMerge": "passed", "provisionalChinese": "passed", "uncertainMarks": "passed"])
            // Word lookup: elisions are stripped, verbs get their base form, sentence-like answers are rejected.
            try check(WordLookup.clean("l’augmentation") == "augmentation" && WordLookup.clean("qu'ils") == "ils" && WordLookup.clean("d’intérêt,") == "intérêt")
            try check(WordLookup.clean("en revanche") == "en revanche" && WordLookup.clean("Deux.") == "Deux" && WordLookup.clean("l'") == "l")
            let frenchLemmaAvailable = WordLookup.tag(of: "allons", in: "Nous allons étudier la croissance.",
                range: NSRange(location: 5, length: 6), scheme: .lemma) != nil
            // Fresh CI Macs may lack French NLP assets; a returned but wrong lemma must still fail.
            if frenchLemmaAvailable {
                try check(WordLookup.lemma(of: "allons", in: "Nous allons étudier la croissance.", range: NSRange(location: 5, length: 6)) == "aller", "Conjugated verb lemma")
                try check(WordLookup.lemma(of: "croissance", in: "Nous allons étudier la croissance.", range: NSRange(location: 23, length: 10)) == nil, "Base form is not repeated")
            }
            try check(WordLookup.looksLikeSentence("今天，我们将研究经济增长", source: "allons") && WordLookup.looksLikeSentence("仅仅一个假设是不够的。", source: "ne suffit pas"))
            try check(!WordLookup.looksLikeSentence("投资", source: "investissements") && !WordLookup.looksLikeSentence("不足以", source: "ne suffit pas"))
            let lookupPrompt = LocalModel.lookupPrompt("base", sentence: "On ajoute une base forte.", range: NSRange(location: 14, length: 4), preset: ClassPreset(subject: .science))
            try check(lookupPrompt.contains("«On ajoute une [base] forte.»") && lookupPrompt.hasSuffix("Translate only: base") && lookupPrompt.contains("mathematics"))
            let repeated = "Les faits sont vérifiables, les calculs sont faits à la main."
            let firstFact = (repeated as NSString).range(of: "faits")
            let lastFact = (repeated as NSString).range(of: "faits", options: .backwards)
            if frenchLemmaAvailable {
                try check(WordLookup.lemma(of: "faits", in: repeated, range: firstFact) == "fait")
                try check(WordLookup.lemma(of: "faits", in: repeated, range: lastFact) == "faire")
            }
            printJSON(["frenchLemmatizer": frenchLemmaAvailable ? "passed" : "skipped (system French NLP assets unavailable)"])
            let repeatedPrompt = LocalModel.lookupPrompt("faits", sentence: repeated, range: lastFact, preset: ClassPreset())
            try check(repeatedPrompt.contains("Les faits sont vérifiables, les calculs sont [faits]"))
            let elided = "🧪 Le taux d’intérêt et l’intérêt."
            let elidedRange = (elided as NSString).range(of: "l’intérêt")
            let selected = WordLookup.selection(in: elided, range: elidedRange)!
            try check(selected.phrase == "intérêt" && selected.range.location == elidedRange.location + 2)
            try check((elided as NSString).substring(with: selected.range) == "intérêt")
            try check(WordLookup.selection(in: elided, range: NSRange(location: 1, length: 1)) == nil, "Reject split surrogate")
            try check(WordLookup.selection(in: elided, range: NSRange(location: NSNotFound, length: 0)) == nil)
            try check(WordLookup.lemma(of: "faits", in: repeated, range: NSRange(location: 0, length: 5)) == nil)
            try check(WordLookup.commonUsage("en", lexicalClass: nil)?.contains("代词") == true)
            try check(WordLookup.commonUsage("pas", lexicalClass: "Noun") == nil)
            try check(WordLookup.needsPlainOnly("me", lexicalClass: "Pronoun") && !WordLookup.needsPlainOnly("en revanche", lexicalClass: nil))
            try check(!WordLookup.acceptsContext("复数域", plain: "域", source: "corps"))
            try check(WordLookup.acceptsContext("力矩", plain: "时刻", source: "moment"))
            try check(WordLookup.acceptsContext("加速度", plain: "加速", source: "accélération"))
            let positionController = ClassController(workspace: WorkspaceConfiguration(projectRoot: mergeRoot.path))
            positionController.session.preset = ClassPreset(glossary: "faits = 事实")
            let factMeaning = try await positionController.lookUp("faits", lemma: "fait", in: repeated, range: firstFact)
            positionController.session.preset = ClassPreset(glossary: "faits = 完成")
            let madeMeaning = try await positionController.lookUp("faits", lemma: "faire", in: repeated, range: lastFact)
            let changedMeaning = try await positionController.lookUp("faits", lemma: "fait", in: repeated, range: firstFact)
            try check(factMeaning.glossary == "事实" && madeMeaning.glossary == "完成" && changedMeaning.glossary == "完成")
            try check(positionController.lookupCache.count == 3, "Cache distinguishes occurrence, lemma and preset")
            let grammarMeaning = try await positionController.lookUp("en", lemma: nil, in: "en janvier", range: NSRange(location: 0, length: 2))
            try check(grammarMeaning.isGrammar && grammarMeaning.inSentence == nil && grammarMeaning.backend == "内置法语用法")
            let cancelledLookup = Task { @MainActor in
                try await positionController.lookUp("en", lemma: nil, in: "en janvier", range: NSRange(location: 0, length: 2))
            }
            cancelledLookup.cancel()
            do {
                _ = try await cancelledLookup.value
                throw AppError("Cancelled lookup must not return cached results")
            } catch is CancellationError { }
            positionController.shutdown()
            // A saved class is continued, not replaced, by the start action.
            let resumable = ClassController(workspace: WorkspaceConfiguration(projectRoot: mergeRoot.path))
            resumable.newSession()
            try check(resumable.startTitle == "开始听课")
            resumable.session.lines = [TranscriptLine(id: "r", start: 0, french: "Bonjour.", chinese: "你好。", isFinal: true)]
            try check(resumable.startTitle == "继续听课", "A class with captions offers to continue")
            resumable.shutdown()
            printJSON(["wordLookup": "passed", "continueClass": "passed"])
            // Presets and context: the plain prompt is unchanged; context goes in separate blocks.
            let plain = LocalModel.prompt("Bonjour.")
            try check(plain.hasSuffix("Please translate the following French text into Chinese:\n\n\nBonjour.") && !plain.contains("Previous sentences"))
            var preset = ClassPreset(subject: .science, topic: " Algèbre linéaire ", glossary: "corps = 域\nbase → 碱\nligne sans séparateur\n = vide")
            try check(preset.terms.map(\.source) == ["corps", "base"] && preset.label == "数理 · Algèbre linéaire" && !preset.isDefault)
            let framed = LocalModel.prompt("Deux.", context: TranslationContext(preset: preset, previous: ["Combien de solutions ?"]))
            try check(framed.contains("mathematics and physical sciences (Algèbre linéaire)") && framed.contains("corps → 域")
                      && framed.contains("Previous sentences (context, not to be translated):\nCombien de solutions ?")
                      && framed.hasSuffix("Please translate only the following French text into Chinese:\n\n\nDeux."))
            preset = ClassPreset(); try check(preset.isDefault && LocalModel.contextBlocks(TranslationContext(preset: preset)).isEmpty)
            let contextRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ClairContextTest-" + UUID().uuidString)
            defer { try? FileManager.default.trashItem(at: contextRoot, resultingItemURL: nil) }
            let lecture = ClassController(workspace: WorkspaceConfiguration(projectRoot: contextRoot.path))
            lecture.newSession()
            lecture.setPreset(ClassPreset(subject: .law, topic: "Droit constitutionnel"))
            for (index, text) in ["Le Parlement a voté la loi en 1905.", "Euh.", "Elle sépare l'Église et l'État.", "Elle reste en vigueur."].enumerated() {
                lecture.receive(SpeechEvent(start: Double(index * 5), duration: 3, text: text, isFinal: true), token: lecture.captureID)
            }
            let last = lecture.session.lines.last!.id
            let context = lecture.translationContext(before: last)
            try check(context.previous == ["Le Parlement a voté la loi en 1905.", "Elle sépare l'Église et l'État."] && context.preset.subject == .law,
                      "Context should be the two previous sentences: \(context.previous)")
            lecture.newSession()
            try check(lecture.session.preset?.subject == .law, "A new class starts from the last preset")
            lecture.shutdown()
            printJSON(["classPresets": "passed", "translationContext": "passed"])
            if arguments.contains("--bench") { try benchmark() }
            try check(StudyContext.chunks(sample, limit: 20).allSatisfy { $0.count <= 20 })
            try check(StudyContext.citations("结论 [00:01]，虚构时间 [99:99]", session: sample) == ["00:01"])
            let citationFixture = "[00:09] 生产增长。\n[00:18] 利率从 2,5 % 提高到 3.75%。"
            try check(!StudyContext.numericCitationsAreSupported("从2.5%到3.75% [00:09]", context: citationFixture))
            try check(StudyContext.numericCitationsAreSupported("从2.5%到3.75% [00:18]", context: citationFixture))
            try check(StudyContext.reconcilePercentageCitations("从2.5%到3.75% [00:09]", context: citationFixture).contains("[00:18]"))
            try check(!StudyContext.reconcilePercentageCitations("2.5% [00:09]", context: "[00:18] 2.5%\n[00:22] 2.5%").contains("数字来源"))
            printJSON(["transcriptRules": "passed", "sessionPersistence": "passed", "srtExport": "passed"])
            printJSON(["projectRenameMove": "passed", "softDeleteRestore": "passed", "studyPersistence": "passed", "contextBoundaries": "passed"])
            if arguments.contains("--study") {
                var classroom = ClassSession()
                classroom.lines = [
                    TranscriptLine(id: "intro", start: 0, french: "Aujourd’hui, nous allons étudier la croissance économique et le développement durable.", chinese: "今天讨论经济增长与可持续发展。", isFinal: true),
                    TranscriptLine(id: "concept", start: 6, french: "Il ne faut pas confondre ces deux concepts.", chinese: "不要将这两个概念混淆。", isFinal: true),
                    TranscriptLine(id: "growth", start: 9, french: "La croissance mesure l’augmentation de la production.", chinese: "增长衡量生产量的增加。", isFinal: true),
                    TranscriptLine(id: "rates", start: 18, french: "Le taux d’intérêt est passé de 2,5 % à 3,75 % en janvier.", chinese: "1月，利率从2.5%提高到3.75%。", isFinal: true),
                    TranscriptLine(id: "effects", start: 22, french: "Cette augmentation peut ralentir les investissements.", chinese: "这种增加可能减缓投资。", isFinal: true),
                    TranscriptLine(id: "hypothesis", start: 25, french: "Pour conclure, une hypothèse ne suffit pas.", chinese: "仅有一个假设不足以得出结论。", isFinal: true),
                    TranscriptLine(id: "data", start: 28, french: "Nous devons vérifier les données avant de prendre une décision.", chinese: "决定前需要核实数据。", isFinal: true)
                ]
                let minutes = try await StudyModel.run(action: .minutes, question: "", source: classroom, progress: { _ in })
                let answer = try await StudyModel.run(action: .question, question: "一月份的利率从多少变成多少？", source: classroom, progress: { _ in })
                printJSON(["studyMinutes": minutes, "studyAnswer": answer])
                guard answer.contains("2.5"), answer.contains("3.75"), answer.contains("[00:18]"), !answer.contains("[00:09]") else { throw AppError("Study answer must preserve classroom numbers and cite real timestamps") }
                printJSON(["studyModel": "passed", "minutes": minutes, "answer": answer])
            }
            if arguments.contains("--context") {
                let law = ClassPreset(subject: .law), science = ClassPreset(subject: .science, glossary: "corps = 域\nbase = 碱")
                let cases: [(String, TranslationContext, [String], [String])] = [
                    ("Elle sépare l'Église et l'État.", TranslationContext(preset: law, previous: ["Le Parlement a voté la loi en 1905."]), ["它", "该法"], ["她"]),
                    ("Deux.", TranslationContext(preset: science, previous: ["Combien de solutions a cette équation ?"]), ["两"], ["第二"]),
                    ("Il ne s'applique que si la fonction est dérivable.", TranslationContext(preset: science, previous: ["Prenons le théorème de Rolle."]), ["它", "该定理"], ["他"]),
                    ("Le corps des nombres réels est ordonné.", TranslationContext(preset: science), ["域"], []),
                    ("On ajoute une base forte à la solution.", TranslationContext(preset: science), ["碱"], [])
                ]
                for (french, context, expected, forbidden) in cases {
                    let result = try await LocalModel.generate(french, context: context)
                    let good = expected.contains(where: result.text.contains) && !forbidden.contains(where: result.text.contains)
                    printJSON(["french": french, "chinese": result.text, "seconds": result.seconds, "ok": good])
                    guard good else { throw AppError("Context translation failed for: " + french) }
                }
                printJSON(["contextTranslation": "passed"])
            }
            if arguments.contains("--model") || arguments.contains("--quality") {
                let coldStarted = Date()
                try await LocalModel.warmup()
                printJSON(["warmupSeconds": Date().timeIntervalSince(coldStarted)])
                let samples = [
                    "Bonjour. Aujourd’hui, nous allons étudier le développement durable.",
                    "Il ne faut pas confondre la croissance économique et le développement durable.",
                    "Le taux d’intérêt est passé de 2,5 % à 3,75 % en janvier.",
                    "La demande augmente lorsque le prix diminue, toutes choses égales par ailleurs.",
                    "Même si cette hypothèse semble plausible, les données ne permettent pas encore de la confirmer."
                ]
                for (index, text) in samples.enumerated() {
                    let result = try await LocalModel.generate(text)
                    guard result.text.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) else {
                        throw AppError("Model did not return Chinese")
                    }
                    if index == 2 {
                        guard result.text.contains("2.5"), result.text.contains("3.75"),
                              result.text.contains("1 月") || result.text.contains("1月") || result.text.contains("一月") else {
                            throw AppError("Translation must retain the interest rates and January date")
                        }
                    }
                    printJSON(["french": text, "chinese": result.text, "seconds": result.seconds, "backend": result.backend])
                    if arguments.contains("--quality") {
                        let system = TranslationSession(installedSource: Locale.Language(identifier: "fr"), target: Locale.Language(identifier: "zh-Hans"))
                        let translated = try await system.translate(text)
                        printJSON(["french": text, "systemChinese": translated.targetText])
                    }
                }
            }
        } catch {
            printJSON(["error": error.localizedDescription])
            exit(1)
        }
    }
    /// Median timings for the main-thread library paths, on 200 one-hour classes.
    static func benchmark() throws {
        func median(_ runs: Int, _ body: () throws -> Void) rethrows -> Double {
            var samples: [Double] = []
            for _ in 0..<runs {
                let elapsed = try ContinuousClock().measure(body).components
                samples.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            }
            return samples.sorted()[runs / 2]
        }
        func lecture(_ count: Int) -> ClassSession {
            var record = ClassSession()
            record.lines = (0..<count).map {
                TranscriptLine(id: "line-\($0)", start: Double($0) * 3, french: "Le taux d’intérêt est passé de 2,5 % à 3,75 % en janvier, phrase \($0).",
                               chinese: "1月，利率从2.5%提高到3.75%，第\($0)句。", backend: "Gemma 本地", isFinal: true, latency: 0.4)
            }
            record.duration = Double(count) * 3
            return record
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClairClassBench-" + UUID().uuidString)
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let library = LibraryStore(workspace: WorkspaceConfiguration(projectRoot: root.path))
        for _ in 0..<199 { try library.save(lecture(1200)) }
        var live = lecture(1200)
        try library.save(live)
        let autosave = try median(21) { live.duration += 1; try library.save(live) }
        let scan = median(21) { _ = library.files() }
        let load = median(5) { _ = library.load() }
        let copy = live
        let unchanged = median(21) { _ = copy == live }
        printJSON(["benchClasses": 200, "benchLinesPerClass": 1200, "autosaveMs": autosave, "avoidedLibraryScanMs": scan,
                   "historyLoadMs": load, "unchangedCompareMs": unchanged])
    }
    static func check(_ value: Bool, _ message: String = "Assertion failed", line: Int = #line) throws {
        if !value { throw AppError("Test line \(line): \(message)") }
    }
    static func printJSON(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
