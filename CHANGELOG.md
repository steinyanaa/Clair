# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [0.5.2] - 2026-10-12

### Fixed
- **Chinese no longer blanks and jumps when a line is revised.** When the French of a translated line changes (the recogniser revises a draft, a sentence is finalised differently, or a sentence split by a pause is merged with its continuation), the earlier Chinese stays on screen, dimmed and without a status row, until the new translation replaces it in place. Previously the Chinese was cleared, an ellipsis showed, and the row shrank and grew back, shifting every caption below (245 pt → 225 pt → 245 pt for a one-line translation in a hidden-window check; now 245 pt throughout). Provisional Chinese is never saved or exported; if the new translation fails it is withdrawn and the error shows.
- **Far fewer wasted live translations.** The recogniser revises a draft about once a second (bursts up to 1.18 s apart), but drafts were translated after 0.8 s without change, so about three in four draft requests were discarded as stale and took about a third of the model's time. An unfinished trailing sentence now waits 1.3 s; complete sentences (0.8 s) and finals keep their holds. Hold rules live in `TranscriptRules.translationHold`.

### Changed
- Live French drafts use SwiftUI text; completed captions keep click/selection lookup. Settled text measurements are cached by width and invalidated on content/style changes. Closing a lookup card cancels its request, and cancelled lookups cannot populate the cache or start the contextual request.

### Added
- Opt-in timing diagnostics: `-ClairClassSpeechDiagnostics` together with `-ClairClassDataRoot <temporary-directory>` writes one `speech-timing-<UUID>.jsonl` per run into that directory. It records audio delivery/conversion, recognition delivery (draft length in characters), main-thread lag of 50 ms or more (a 100 ms main-queue probe), each live translation request (hold, wait, request time, draft/final, complete sentence, shown or discarded, fallback, failure) and each on-screen translation superseded by a change of the French (cause, case/punctuation-only, kept visible or not). It is written on a separate queue and contains no audio or transcript text. It cannot be enabled against the real class library.
- `scripts/test-captions.sh`: hidden-window layout checks with synthetic data (drafts, settled captions, text growth, narrower/restored widths, disabled lookup, unchanged row height while revising). `scripts/test.sh --recognize <audio> --realtime` reports recognition arrival intervals and requires already-installed French speech assets.

### Validation
- `scripts/build.sh --compile-only` passed. Three consecutive `scripts/test.sh` runs each passed all 21 reported groups, including the new provisional-Chinese checks (kept while queued, not stored, kept across a merge, withdrawn when re-translation fails); the seven caption-layout scenarios passed.
- Full-window replay without a microphone (190 s synthesized French lecture in real time, real recognition, local model on the fixture port, synthetic level meter, temporary library), two alternating runs each:
  - Trailing-fragment hold: discarded draft requests 136–142 → 0; model busy 91–95 s → 29 s of ~200 s; finished-sentence queue wait median 203–246 → 54–59 ms. Time from the last French change to Chinese was unchanged within noise (draft sentences ~1.3 s, finals ~1.5–1.7 s median).
  - Revisions: 12 of 59 shown translations were superseded (7 merges, 4 draft revisions, 1 finalisation change); none blank now.
- Live microphone, dev app with a temporary library:
  - About 2 minutes: audio kept pace with the clock (130.6 s in 130.5 s); recognition arrived every 0.92 s (median), 0.07 s behind the audio; longest main-thread lag 115 ms; Chinese 1.3–1.4 s after the French stopped changing.
  - About 4 minutes with this release's code, confirmed by the tester: 62 translations shown, 50 later superseded; 45 stayed visible until replaced and 5 blanked (see Known limitations). 6 of 68 requests were discarded. Main-thread lag stayed under 190 ms while speaking.

### Investigation
- The original report was captions pausing while the lecturer spoke and then arriving as a whole paragraph. It was not reproduced: not in replays of the released 0.5.1 or of this code, and not in the two microphone sessions. In both, recognition arrived in bursts of four or five results about every 0.9 s, with no backlog. Long recognition gaps coincided with the speaker being silent. One early replay showed main-thread lags up to 0.9 s after 160 s; it did not recur in four later replays and remains unexplained. The released 0.5.1 French draft view was also checked: it did not clip or freeze while growing. The diagnostics are kept to capture the stall if it returns.
- A hidden 600-row pane simulation measured mean 6.146 ms before / 6.237 ms after the draft display change (p95 6.993 / 6.812 ms): no meaningful pane-level speedup is claimed.

### Known limitations
- The cause of the original pause-then-burst stall is not confirmed.
- When the recogniser re-times a segment while finalising it, its lines are replaced by new ones, and their Chinese is still cleared and re-translated. All 5 such cases in the 4-minute session differed only in case or punctuation.
- Merging a sentence with its continuation removes the continuation's row, which shifts later captions up once.
- During unpunctuated speech, the trailing fragment is translated only after a 1.3 s pause (previously 0.8 s).

## [0.5.1] - 2026-10-12

### Fixed
- **Lookup follows the selected occurrence**: UTF-16 ranges now travel from the text view through elision cleanup, French lemmatisation, sentence markers and the lookup cache. Repeated `faits` can resolve to `fait` (事实) or `faire` (做) at their own positions. Cache entries also include the subject, topic, glossary and model, so changing the class preset does not reuse an old meaning.
- **Function words no longer borrow a nearby noun's meaning**: common words such as `en`, `y`, `dont`, `que`, `se` and `ne` use a small, original, built-in usage table, labelled 常见用法 with 内置法语用法 as the source. It describes possible uses, without claiming to identify the sense in this sentence. Other short/function words skip contextual generation. Selecting a complete phrase (`en revanche`, `il y a`, `au lieu de`) still translates that phrase.
- **Isolated verb meanings**: verbs use the selected occurrence's dictionary form without another sentence-level generation, avoiding subjects, auxiliaries and modal verbs (`peut ralentir` → 减速 for `ralentir`, without 可能). Other words use a bracket-marked target; sentence-like answers and obvious expansions of the plain Chinese head are suppressed. Matching classroom terms are used directly. System translation fallback remains available; live-caption prompts and their context blocks are unchanged.

### Changed
- Build/package cleanup moves replaced artifacts and staging files to Trash. Full builds refuse to overwrite/sign the app while Clair is running.

### Added
- **Reproducible lookup evaluation**: `scripts/test.sh --lookup -ClairClassDataRoot <temporary-directory>` uses the separate local service on port 11449. Add `--baseline` for frozen 0.5.0 behavior or `--marked` for the marker-only experiment. All 36 cases print their selection, accepted answers, forbidden adjacent meanings, actual result and elapsed time; the summary reports accuracy and latency. No downloads or assistant model are needed.

### Validation
- On this Mac with `translategemma:4b`, temperature 0, warm model and empty lookup caches: **11/36 (30.6%), mean 0.394 s before → 33/36 (91.7%), mean 0.124 s after**; final maximum 0.350 s, 0/36 over 0.5 s, no service errors. The marker-only experiment reached 19/36 (52.8%), mean 0.278 s; a dictionary-entry prompt variant reached only 15/36, so was not adopted. Model warm-up and compilation are excluded; both plain and contextual requests are included.
- Scoring requires an accepted short equivalent for content words and rejects neighbouring meanings; labelled general usage is accepted for function words. This is a fixed regression set, not an estimate of unrestricted translation accuracy. Per-case results: `docs/lookup-evaluation-0.5.1/{before,marked,after}.jsonl`.

- `scripts/build.sh --compile-only` passed with Swift 5 / macOS 26. Three consecutive `scripts/test.sh` runs each passed all **19 reported groups**, including `wordLookup` and `continueClass`; logs are alongside the evaluation results. Range, elision, repeated-lemma, cache invalidation and grammar-only cases run without a model.
- On fresh CI Macs without system French lemmatisation assets, only the asset-dependent lemma assertions are explicitly reported as skipped. A returned but incorrect lemma still fails; selection, elision, cache and grammar checks continue without model or asset downloads.
- An additional system-fallback check reached the existing “备用翻译尚未安装” error: French→Chinese system resources are not installed on this Mac. Successful fallback could not be exercised offline; its implementation is retained. No resources were downloaded.

### Known limitations
- Three cases still fail the strict selection-only test: `L’augmentation est rapide` can return 快速 for `augmentation`; mathematical `corps` without a term entry returns 实数的集合 instead of 域; `base forte` returns 强碱 for selected `base` instead of 碱. A classroom term (`corps = 域`, `base = 碱`) avoids model ambiguity. The lightweight filter does not prove semantic alignment for arbitrary content words.
- Function-word tables do not resolve the current grammatical use, and verb lookups intentionally show the independent dictionary meaning. Select a longer phrase when its construction matters.

## [0.5.0] - 2026-10-12

### Added
- **Word lookup**: click a French word in the transcript to see its base form (allons → aller, from the system lemmatiser), its plain sense, the sense in that sentence and any matching term from the class preset; drag over several words to translate the selection, or use 查词 / 翻译所选 in the context menu. Runs on the local translation model (about 0.2 s per word; falls back to the system translator for the plain sense). Measured on 10 lecture words, the in-sentence prompt picks the field's sense where the plain one does not (base → 强碱, moment → 力矩); answers that come back as a whole sentence are dropped. Can be turned off in Settings.

### Fixed
- **The model service no longer outlives the app**: it now runs under a small watchdog that stops it within about a second when Clair quits, crashes or is force-quit, and a service left behind by an earlier version is stopped on launch instead of being reused (which had kept a model loaded in memory indefinitely). Fixture runs (`-ClairClassDataRoot`) use their own port.

### Changed
- **Redesign**: warm paper palette (light and dark) with a single clay accent, New York / Songti headings and serif French lines. The toolbar is now plain text tabs (转录 / 课堂助手) with a sliding clay underline and two borderless menus; search moved into the sidebar under a new 「新课堂」 row.
- **New class composer**: topic, term list, audio source and 开始听课 sit in one centred card, with subject pills beneath; the bottom dock takes over once listening starts.
- **Class assistant**: quick actions, status, export and send live inside the composer; answers read without a box, questions sit in warm bubbles, citations are small outlined pills.
- Class list and sidebar draw their own warm selection instead of the system accent; clicks, ⌘/⇧-click, ⌘A, arrow keys, Delete, drag and context menus work as before.
- **Ending a class no longer forces a new one**: on a saved class the main button reads 继续听课 and continues the same class; start a new one with 新课堂 (⌘N).

## [0.4.0] - 2026-10-12

### Added
- **Class presets**: before (or during) a class, choose the subject (文学, 数理, 经济, 法律, 历史哲学, 医学生物, 工程计算机, 艺术), an optional topic and an optional term list (`corps = 域`). The preset is saved with the class, new classes start from the last one, and the class assistant uses it too.
- **Context-aware translation**: each sentence is translated together with the subject, the term list and the two previous sentences (as context that is not translated). On 16 lecture sentences whose meaning depends on the field or the previous sentence, correct translations went from 10/16 to 13/16, all six context-dependent cases became correct, and the term list fixed the remaining field-specific words. Median time per sentence 0.33 s (was 0.29 s).

### Changed
- Calmer, more modern interface: a «这节课讲什么？» setup screen with subject chips, a large class title with the preset as a tag, a divider-free reading column with time stamps on hover and a gentle fade-in for new sentences, an animated typing indicator, and a single centred glass capsule with a live waveform for capture controls, with the translation model's status (for example “TranslateGemma 4B 已就绪”) always shown beneath it.

## [0.3.1] - 2026-10-12

### Changed
- The app is now called **Clair** (previously ClairClass): app name, window title, menus, permission prompts, `Clair.app` and the DMG name.
- New app icon: the “clair” wordmark on a white rounded square, built from `Resources/AppIcon.png` instead of being drawn in code.

### Notes
- The bundle identifier (`local.clairclass.mac`) and the data folder (`~/Library/Application Support/ClairClass/`) are unchanged, so existing classes, settings and permissions carry over.

## [0.3.0] - 2026-10-12

First public release.

### Added
- macOS 26 redesign: Mail-style folder title, native sidebar counts, class header, Liquid Glass capture bar with timer and input level, "jump to latest" while reading back, citation highlight, ⌘K palette with keyboard navigation, View menu text size (⌘+ / ⌘− / ⌘0), ⌥⌘F search.
- Multi-selection with batch move, move to Recently Deleted and restore; permanent deletion from Recently Deleted (single, batch or "Empty Recently Deleted"), always confirmed.
- Project deletion (classes move to Unfiled), drag classes onto Unfiled / Recently Deleted, drag audio files into the window to import.
- Per-line copy and re-translate; Markdown tables, lists and quotes in assistant answers.
- Translation quality: sentence halves split by pauses are merged before translation, fillers and stutters are removed from the translation input, fallback lines are re-translated with Gemma when idle, the translation model stays loaded for 2 h, and the model service restarts automatically.
- Uncertain-word marks from recogniser confidence (content words below 0.5), with a setting to turn them off.
- Launch arguments for UI checks against fixture data (`-ClairClassDataRoot` and `-ClairClassUITest…`).

### Fixed
- Launch could replace a capture started during model warm-up; history was loaded twice.
- The input meter redrew the whole window about 23 times per second.
- "Show French" changed from the toolbar was not saved unless Settings was open.
- ⌘R paused an audio import that could not be resumed.
- Reopened classes showed "translating…" forever for abandoned lines.
- Following the same citation twice did nothing; the ⌘K palette ignored arrow keys.
- Selecting a class rewrote the previous one to disk; autosave scanned the whole library.
- French closing guillemets (`? »`) made finished sentences look unfinished.
- Swift 6 strict-concurrency warnings.

## [0.2.0] - 2026-10-11

### Added
- Three-column interface with projects, rename, Recently Deleted and restore.
- Class assistant (notes, minutes, Q&A) with timestamp citations.
- Model selection and download in Settings.
