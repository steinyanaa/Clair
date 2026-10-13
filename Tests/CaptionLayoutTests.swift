import AppKit
import SwiftUI

@main struct CaptionLayoutTests {
    @MainActor static func main() {
        precondition(WorkspaceConfiguration.testRoot != nil, "Temporary data root required")
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 580, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        var line = TranscriptLine(id: "fixture", start: 0, french: "Bonjour.")
        func row(_ lookup: Bool = true) -> TranscriptRow {
            TranscriptRow(line: line, showFrench: true, fontSize: 22, markUncertain: true,
                          isPending: false, highlighted: false, editable: true, lookupEnabled: lookup,
                          retranslate: {}, lookup: { _, _, _, _ in WordMeaning() })
        }
        let host = NSHostingView(rootView: row().fixedSize(horizontal: false, vertical: true))
        host.sizingOptions = []
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 580, height: 700)
        func layout() {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
        }
        func frenchViews(_ view: NSView) -> [FrenchTextView] {
            (view as? FrenchTextView).map { [$0] } ?? view.subviews.flatMap(frenchViews)
        }
        layout()
        precondition(frenchViews(host).isEmpty, "Drafts should use lightweight text")
        line.isFinal = true
        host.rootView = row().fixedSize(horizontal: false, vertical: true); layout()
        precondition(frenchViews(host).count == 1, "Settled captions retain word selection")
        let shortHeight = frenchViews(host)[0].frame.height
        line.french = String(repeating: "Le taux d’intérêt peut ralentir les investissements. ", count: 8)
        host.rootView = row().fixedSize(horizontal: false, vertical: true); layout()
        let wideHeight = frenchViews(host)[0].frame.height
        precondition(wideHeight > shortHeight, "Text edits must invalidate measured height")
        window.setContentSize(NSSize(width: 300, height: 700)); host.frame.size.width = 300; layout()
        precondition(frenchViews(host)[0].frame.height > wideHeight, "Narrow captions must wrap")
        window.setContentSize(NSSize(width: 580, height: 700)); host.frame.size.width = 580; layout()
        precondition(abs(frenchViews(host)[0].frame.height - wideHeight) < 1, "Cached width must restore layout")
        precondition(frenchViews(host)[0].string == line.french)
        host.rootView = row(false).fixedSize(horizontal: false, vertical: true); layout()
        precondition(frenchViews(host).isEmpty, "Disabled lookup needs no AppKit text view")
        // A revised line keeps its height: earlier Chinese stays, dimmed, with no status row.
        func height(_ chinese: String, pending: Bool, revising: Bool) -> CGFloat {
            var shown = line; shown.chinese = chinese
            let view = NSHostingView(rootView: TranscriptRow(line: shown, showFrench: true, fontSize: 22, markUncertain: true,
                isPending: pending, isRevising: revising, highlighted: false, editable: true, lookupEnabled: false,
                retranslate: {}, lookup: { _, _, _, _ in WordMeaning() }).frame(width: 580))
            return view.fittingSize.height
        }
        let translated = height("利率可能减缓投资。", pending: false, revising: false)
        let revising = height("利率可能减缓投资。", pending: true, revising: true)
        let blanked = height("", pending: true, revising: false)
        precondition(abs(translated - revising) < 1, "Revising must not change the row height (\(translated) vs \(revising))")
        print("captionLayout: row height translated \(translated), revising \(revising), cleared-and-waiting \(blanked)")
        // Assistant citations: a matching timecode is a link into the transcript, another stays plain.
        let cited = MarkdownReading.inline("可能减缓投资 [00:33]，还需看通胀 [00:52]", citations: ["00:33"])
        let linked = cited.runs.compactMap { run in run.link.map { (String(cited.characters[run.range]), $0.absoluteString) } }
        precondition(String(cited.characters) == "可能减缓投资 00:33，还需看通胀 00:52", "Citation brackets are removed")
        precondition(linked.count == 1 && linked[0].0 == "00:33" && linked[0].1 == MarkdownReading.sourceScheme + ":00:33",
                     "Only matching citations link to the transcript: \(linked)")
        print("captionLayout: passed (draft, final, edited text, narrower width, restored width, disabled lookup, revising height, citation links)")
    }
}
