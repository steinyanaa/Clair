import SwiftUI
import AppKit

// Shared layout, type and motion values. Views use these instead of ad-hoc
// numbers so rhythm and timing stay consistent across panes (4 pt grid).
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum Radius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 12
    static let bubble: CGFloat = 18
}

enum Layout {
    /// Comfortable reading measure for bilingual captions on wide windows.
    static let readingWidth: CGFloat = 820
    static let timecodeWidth: CGFloat = 44
}

extension Font {
    static let rowTitle = Font.body.weight(.semibold)
    static let rowPreview = Font.subheadline
    static let rowMeta = Font.caption
}

// Motion only where it explains a change of state. Keyboard-driven and
// high-frequency updates (captions arriving, the level meter) never animate.
enum Motion {
    /// Pointer-driven state changes such as starting or ending a capture.
    static let state = Animation.smooth(duration: 0.28)
    /// Banners and floating controls entering or leaving.
    static let enter = Animation.easeOut(duration: 0.22)
    /// Brief confirmation like a highlight fading out.
    static let settle = Animation.easeOut(duration: 0.6)

    static func state(reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.15) : state }
    static func enter(reduced: Bool) -> Animation { reduced ? .easeOut(duration: 0.15) : enter }
    /// A new caption rises a few points into place; Reduce Motion keeps only the fade.
    static func arrival(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .opacity.combined(with: .offset(y: 8))
    }
    /// Reduce Motion keeps the fade and drops the travel.
    static func edge(_ edge: Edge, reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .move(edge: edge).combined(with: .opacity)
    }
}

/// Inline notice above content: an error, or a state such as Recently Deleted.
/// Uses glass because it floats over scrolling captions, tinted only for warnings.
struct Banner<Actions: View>: View {
    let symbol: String
    let message: String
    var tint: Color?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: symbol).foregroundStyle(tint ?? .secondary).accessibilityHidden(true)
            Text(message).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            actions
        }
        .font(.callout)
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s + Spacing.xxs)
        .glassEffect(tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular, in: .rect(cornerRadius: Radius.medium))
        .accessibilityElement(children: .contain)
    }
}

extension AudioSource {
    static func symbol(forRecordSource source: String) -> String {
        switch source {
        case AudioSource.microphone.rawValue: return AudioSource.microphone.symbol
        case AudioSource.system.rawValue: return AudioSource.system.symbol
        default: return "waveform"
        }
    }
}

/// Small transient "copied" confirmation for copy buttons.
struct CopyButton: View {
    let text: () -> String
    var title = "复制"
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
        } label: {
            Label(copied ? "已复制" : title, systemImage: copied ? "checkmark" : "doc.on.doc")
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.borderless)
    }
}
