import SwiftUI
import AppKit

@MainActor @Observable
final class LookupState {
    let phrase: String
    let lemma: String?
    var meaning: WordMeaning?
    var failure: String?
    init(phrase: String, lemma: String?) { self.phrase = phrase; self.lemma = lemma }
    var isPhrase: Bool { phrase.contains(" ") }
}

/// Popover card: the word in the transcript's serif, then its senses, quiet labels above values.
struct LookupCard: View {
    let state: LookupState
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(state.phrase).font(.french(state.isPhrase ? 15 : 18).weight(.semibold)).foregroundStyle(Palette.ink)
                    .lineLimit(4).fixedSize(horizontal: false, vertical: true)
                if let lemma = state.lemma {
                    Text("原形 \(Text(lemma).font(.french(13)).foregroundStyle(Palette.ink2))").foregroundStyle(Palette.ink3)
                }
            }
            .font(.system(size: 12))
            if let meaning = state.meaning {
                if let term = meaning.glossary { sense("术语对照", term) }
                if let plain = meaning.plain { sense(meaning.isGrammar ? "常见用法" : (state.isPhrase ? "译文" : "释义"), plain) }
                if let used = meaning.inSentence { sense("在这句里", used) }
                HStack {
                    Text(meaning.backend).font(.system(size: 11)).foregroundStyle(Palette.ink3)
                    Spacer()
                    CopyButton(text: { [meaning.glossary, meaning.plain, meaning.inSentence].compactMap { $0 }.first ?? "" })
                        .font(.system(size: 11.5))
                }
            } else if let failure = state.failure {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    Text(failure).font(.system(size: 12.5)).foregroundStyle(Palette.ink2).fixedSize(horizontal: false, vertical: true)
                    Button("重试", action: retry).buttonStyle(GhostButtonStyle())
                }
            } else {
                HStack(spacing: Spacing.s) {
                    ProgressView().controlSize(.small)
                    Text("正在查…").font(.system(size: 12.5)).foregroundStyle(Palette.ink3)
                }
            }
        }
        .padding(Spacing.l)
        .frame(width: 280, alignment: .leading)
        .animation(.easeOut(duration: 0.15), value: state.meaning)
    }

    private func sense(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(Palette.ink3)
            Text(value).font(.system(size: 15)).foregroundStyle(Palette.ink).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// French source line as selectable text: a click on a word looks it up, a dragged
/// selection translates the selection. Off when lookup is turned off in Settings.
struct FrenchLine: NSViewRepresentable {
    let text: String
    let uncertain: [String]
    let size: CGFloat
    let settled: Bool
    let lookupEnabled: Bool
    let lookup: @MainActor (String, String?, String, NSRange) async throws -> WordMeaning

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> FrenchTextView {
        let view = FrenchTextView(usingTextLayoutManager: false)
        view.isEditable = false; view.isSelectable = true; view.drawsBackground = false
        view.isRichText = false; view.isAutomaticLinkDetectionEnabled = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = false; view.isHorizontallyResizable = false
        view.selectedTextAttributes = [.backgroundColor: Palette.nsClay.withAlphaComponent(0.22)]
        let coordinator = context.coordinator
        view.onLookup = { [weak coordinator] range in coordinator?.lookUp(range) }
        coordinator.textView = view
        update(view, coordinator: coordinator)
        Self.runLaunchLookup(in: view, text: text)
        return view
    }

    /// UI-check hook: `-ClairClassUITestLookup <word>` looks up the first occurrence once.
    @MainActor private static var launchLookupDone = false
    @MainActor private static func runLaunchLookup(in view: FrenchTextView, text: String) {
        guard !launchLookupDone,
              let word = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)["ClairClassUITestLookup"] as? String else { return }
        let range = (text as NSString).range(of: word)
        guard range.location != NSNotFound else { return }
        launchLookupDone = true
        Task { @MainActor [weak view] in
            try? await Task.sleep(for: .seconds(2))
            if let view { view.onLookup?(range) }
        }
    }

    static func dismantleNSView(_ view: FrenchTextView, coordinator: Coordinator) {
        coordinator.closeLookup()
    }

    func updateNSView(_ view: FrenchTextView, context: Context) {
        context.coordinator.parent = self
        update(view, coordinator: context.coordinator)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FrenchTextView, context: Context) -> CGSize? {
        guard let container = nsView.textContainer, let layout = nsView.layoutManager else { return nil }
        let proposed = proposal.width.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let width = proposed ?? 10_000
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        if let cached = nsView.measuredSizes[width] { return cached }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container)
        let measured = CGSize(width: proposed ?? ceil(used.width), height: ceil(used.height))
        if nsView.measuredSizes.count >= 8 { nsView.measuredSizes.removeAll() }
        nsView.measuredSizes[width] = measured
        return measured
    }

    private func update(_ view: FrenchTextView, coordinator: Coordinator) {
        view.lookupEnabled = lookupEnabled && settled
        let key = "\(text)|\(uncertain)|\(size)|\(settled)"
        guard coordinator.contentKey != key else { return }
        coordinator.contentKey = key
        view.measuredSizes.removeAll()
        view.textStorage?.setAttributedString(attributed())
        view.invalidateIntrinsicContentSize()
    }

    private func attributed() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3
        let base = NSFont.systemFont(ofSize: size)
        let font = base.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? base
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: font, .paragraphStyle: paragraph, .foregroundColor: settled ? Palette.nsInk2 : Palette.nsInk3
        ])
        // Uncertain words in reading order, so a repeated word is marked only where it was doubtful.
        let string = text as NSString
        var cursor = 0
        for word in uncertain {
            let found = string.range(of: word, options: .caseInsensitive, range: NSRange(location: cursor, length: string.length - cursor))
            guard found.location != NSNotFound else { continue }
            result.addAttributes([.foregroundColor: Palette.nsClayInk, .underlineColor: Palette.nsClay,
                                  .underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue], range: found)
            cursor = NSMaxRange(found)
        }
        return result
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var parent: FrenchLine
        weak var textView: FrenchTextView?
        var contentKey = ""
        private var popover: NSPopover?
        private var shownRange: NSRange?
        private var lookupTask: Task<Void, Never>?
        deinit { lookupTask?.cancel() }

        func closeLookup() {
            lookupTask?.cancel(); lookupTask = nil
            popover?.close()
        }

        init(parent: FrenchLine) { self.parent = parent }

        func lookUp(_ range: NSRange) {
            guard let textView, let storage = textView.textStorage, NSMaxRange(range) <= storage.length else { return }
            if popover?.isShown == true, shownRange == range { return }
            let sentence = storage.string
            guard let selection = WordLookup.selection(in: sentence, range: range) else { return }
            let phrase = selection.phrase
            guard phrase.contains(where: \.isLetter), phrase.count <= 160 else { return }
            let state = LookupState(phrase: phrase, lemma: WordLookup.lemma(of: phrase, in: sentence, range: selection.range))
            let lookup = parent.lookup
            let load: () -> Void = { [weak self, weak state] in
                self?.lookupTask?.cancel()
                self?.lookupTask = Task { @MainActor in
                    guard let state else { return }
                    state.failure = nil
                    do { state.meaning = try await lookup(phrase, state.lemma, sentence, selection.range) }
                    catch is CancellationError { }
                    catch { if !Task.isCancelled { state.failure = error.localizedDescription } }
                }
            }
            closeLookup()
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.delegate = self
            let host = NSHostingController(rootView: LookupCard(state: state, retry: load))
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            self.popover = popover; shownRange = range
            textView.setSelectedRange(range)
            popover.show(relativeTo: textView.rect(for: range), of: textView, preferredEdge: .maxY)
            load()
        }

        func popoverDidClose(_ notification: Notification) {
            guard let closed = notification.object as? NSPopover, closed === popover else { return }
            lookupTask?.cancel(); lookupTask = nil
            if let textView, textView.selectedRange() == shownRange {
                textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
            }
            popover = nil; shownRange = nil
        }
    }
}

final class FrenchTextView: NSTextView {
    var onLookup: ((NSRange) -> Void)?
    var lookupEnabled = true
    // SwiftUI probes several widths repeatedly, even when only the Chinese line changed.
    var measuredSizes: [CGFloat: CGSize] = [:]

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)   // runs the selection tracking loop until mouse up
        guard lookupEnabled else { return }
        let selection = selectedRange()
        if selection.length > 0 { onLookup?(selection); return }
        if event.clickCount == 1, let word = wordRange(at: event) { onLookup?(word) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let selection = selectedRange()
        if lookupEnabled, let target = selection.length > 0 ? selection : wordRange(at: event) {
            let item = NSMenuItem(title: selection.length > 0 ? "翻译所选" : "查词", action: #selector(lookUpFromMenu(_:)), keyEquivalent: "")
            item.representedObject = NSValue(range: target); item.target = self
            menu.addItem(item)
        }
        if selection.length > 0 { menu.addItem(withTitle: "复制", action: #selector(copy(_:)), keyEquivalent: "") }
        let whole = NSMenuItem(title: "复制原文", action: #selector(copyLine(_:)), keyEquivalent: ""); whole.target = self
        menu.addItem(whole)
        return menu
    }

    @objc private func lookUpFromMenu(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? NSValue { onLookup?(value.rangeValue) }
    }
    @objc private func copyLine(_ sender: Any?) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string)
    }

    /// The word under the pointer, only when the pointer is on its glyphs rather than past a line end.
    private func wordRange(at event: NSEvent) -> NSRange? {
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return nil }
        var point = convert(event.locationInWindow, from: nil)
        point.x -= textContainerOrigin.x; point.y -= textContainerOrigin.y
        let glyph = layoutManager.glyphIndex(for: point, in: textContainer)
        let box = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard box.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        let word = selectionRange(forProposedRange: NSRange(location: index, length: 0), granularity: .selectByWord)
        return word.length > 0 ? word : nil
    }

    /// Bounds of a character range in view coordinates, for anchoring the popover.
    func rect(for range: NSRange) -> NSRect {
        guard let layoutManager, let textContainer else { return bounds }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        // A selection over several lines anchors on its first line.
        var first = NSRect.zero
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                              in: textContainer) { rect, stop in first = rect; stop.pointee = true }
        return first.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }
}
