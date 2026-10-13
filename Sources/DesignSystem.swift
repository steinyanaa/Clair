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

    /// Headings: New York for Latin text, Songti SC for Chinese. Built once per size.
    static func display(_ size: CGFloat) -> Font {
        if let font = displayCache[size] { return font }
        let font = makeDisplay(size); displayCache[size] = font
        return font
    }
    nonisolated(unsafe) private static var displayCache: [CGFloat: Font] = [:]
    private static func makeDisplay(_ size: CGFloat) -> Font {
        let base = NSFont.systemFont(ofSize: size, weight: .semibold).fontDescriptor
        let serif = base.withDesign(.serif) ?? base
        let songti = NSFontDescriptor(fontAttributes: [.family: "Songti SC", .face: "Bold"])
        return Font(NSFont(descriptor: serif.addingAttributes([.cascadeList: [songti]]), size: size) ?? .systemFont(ofSize: size))
    }
    /// French source text reads as a book line beside the Chinese translation.
    static func french(_ size: CGFloat) -> Font { .system(size: size, design: .serif) }
}

/// Warm paper palette: one clay accent, everything else warm neutrals.
enum Palette {
    static let canvas = Color(light: 0xFAF9F5, dark: 0x262624)
    static let panel = Color(light: 0xF1EFE8, dark: 0x1F1E1D)
    static let surface = Color(light: 0xFFFFFF, dark: 0x30302E)
    static let bubble = Color(light: 0xF0EEE6, dark: 0x1A1A18)
    static let ink = Color(light: 0x1F1E1D, dark: 0xEEECE4)
    static let ink2 = Color(light: 0x66645D, dark: 0xA8A59B)
    static let ink3 = Color(light: 0x8F8C83, dark: 0x7D7A72)
    static let clay = Color(light: 0xD97757, dark: 0xD97757)
    /// Clay dark enough to read as text on the canvas.
    static let clayInk = Color(light: 0xB4502C, dark: 0xE58A69)
    static let claySoft = clay.opacity(0.14)
    static let hairline = Color(light: 0x1F1E1D, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.08)
    static let hairlineStrong = Color(light: 0x1F1E1D, dark: 0xFFFFFF, lightAlpha: 0.14, darkAlpha: 0.13)
    /// Hover and pressed wash for quiet controls.
    static let wash = Color(light: 0x7F7869, dark: 0xFFFFFF, lightAlpha: 0.11, darkAlpha: 0.07)
    /// Selected list row; a touch deeper while the list has keyboard focus.
    static let selection = Color(light: 0xEDEAE1, dark: 0x33322F)
    static let selectionFocused = Color(light: 0xE7E3D8, dark: 0x3A3935)
    /// AppKit forms for text drawn by NSTextView (the French line).
    static let nsInk2 = NSColor.clair(light: 0x66645D, dark: 0xA8A59B)
    static let nsInk3 = NSColor.clair(light: 0x8F8C83, dark: 0x7D7A72)
    static let nsClay = NSColor.clair(light: 0xD97757, dark: 0xD97757)
    static let nsClayInk = NSColor.clair(light: 0xB4502C, dark: 0xE58A69)
    static let ready = Color(light: 0x5E9A52, dark: 0x7DB370)
}

extension NSColor {
    /// A colour that follows the light or dark appearance it is drawn in.
    static func clair(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) {
        self.init(nsColor: .clair(light: light, dark: dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }
}

extension View {
    /// Raised surface used by the composer, the capture dock and banners.
    func surfaceCard(cornerRadius: CGFloat) -> some View {
        background(Palette.surface, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 4)
            .shadow(color: .black.opacity(0.03), radius: 1, y: 1)
    }
}

/// The one clay action per screen: start listening, send a question.
struct ClayButtonStyle: ButtonStyle {
    var kind: Kind = .text
    enum Kind { case text, icon }
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, kind: kind) }

    private struct Styled: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, kind == .icon ? 0 : Spacing.m + Spacing.xxs)
                .frame(minWidth: 32, minHeight: 32)
                .background(Palette.clay.opacity(enabled ? 1 : 0.4), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(configuration.isPressed ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.97 : 1)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}

/// Outlined secondary control: quick actions, source menu, terms toggle.
struct GhostButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, selected: selected) }

    private struct Styled: View {
        let configuration: Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12.5))
                .foregroundStyle(selected ? Palette.ink : Palette.ink2)
                .padding(.horizontal, Spacing.m - Spacing.xxs)
                .frame(minHeight: 28)
                .background(Palette.wash.opacity(configuration.isPressed ? 1.6 : hovering || selected ? 1 : 0), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
                .opacity(enabled ? 1 : 0.45)
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovering = $0 && enabled }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Borderless icon or text control that shows a wash on hover.
struct QuietButtonStyle: ButtonStyle {
    var size: CGFloat? = 28
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, size: size) }

    private struct Styled: View {
        let configuration: Configuration
        let size: CGFloat?
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .foregroundStyle(hovering ? Palette.ink : Palette.ink2)
                .padding(.horizontal, size == nil ? Spacing.s : 0)
                .frame(minWidth: size, minHeight: size ?? 24)
                .background(Palette.wash.opacity(configuration.isPressed ? 1.6 : hovering ? 1 : 0), in: RoundedRectangle(cornerRadius: 7))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 7))
                .onHover { hovering = $0 && enabled }
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
    }
}

/// Round transport control; `filled` marks the end-class button.
struct CircleControlStyle: ButtonStyle {
    var filled = false
    func makeBody(configuration: Configuration) -> some View { Styled(configuration: configuration, filled: filled) }

    private struct Styled: View {
        let configuration: Configuration
        let filled: Bool
        @Environment(\.isEnabled) private var enabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(filled ? Palette.canvas : Palette.ink)
                .frame(width: 34, height: 34)
                .background(filled ? Palette.ink : Palette.panel, in: Circle())
                .overlay(Circle().fill(.black.opacity(configuration.isPressed ? 0.12 : 0)))
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .opacity(enabled ? 1 : 0.4)
                .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
                .contentShape(Circle())
        }
    }
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
/// A raised card because it floats over scrolling captions; only the icon carries the tint.
extension View {
    /// Scrolling content fades out where it meets the toolbar and a floating bottom bar,
    /// instead of being cut mid-line or showing through the bar. The mask follows the
    /// safe area, so nothing is drawn beneath either bar.
    func edgeFade(top: CGFloat = Spacing.xl, bottom: CGFloat = Spacing.xxl + Spacing.xs) -> some View {
        mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: top)
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: bottom)
            }
        }
    }
}

struct Banner<Actions: View>: View {
    let symbol: String
    let message: String
    var tint: Color?
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
            Image(systemName: symbol).foregroundStyle(tint ?? Palette.ink2).accessibilityHidden(true)
            Text(message).foregroundStyle(Palette.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Spacing.s)
            actions.buttonStyle(QuietButtonStyle(size: nil))
        }
        .font(.callout)
        .padding(.horizontal, Spacing.m + Spacing.xxs).padding(.vertical, Spacing.s + Spacing.xxs)
        .surfaceCard(cornerRadius: Radius.medium)
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
        .buttonStyle(QuietButtonStyle(size: nil))
    }
}
