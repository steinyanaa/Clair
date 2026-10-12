import SwiftUI

/// Subject chips, topic and optional terms. Edits apply immediately, so a change
/// mid-class affects the sentences that follow. The full form is the new-class
/// composer: a raised card holding the topic, terms and, before capture, the start controls.
struct PresetEditor: View {
    let controller: ClassController
    var compact = false
    var showsStart = false
    @State private var draft = ClassPreset()
    @State private var showsTerms = false
    @FocusState private var topicFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if compact {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    chips(alignment: .leading)
                    topicField.font(.body)
                        .padding(.vertical, Spacing.s)
                        .overlay(alignment: .bottom) { Rectangle().fill(Palette.hairlineStrong).frame(height: 0.5) }
                    termsToggle.buttonStyle(.plain).foregroundStyle(Palette.ink2).font(.callout)
                    if showsTerms { termsEditor.frame(height: 96).background(Palette.wash, in: RoundedRectangle(cornerRadius: Radius.small)) }
                }
            } else {
                VStack(spacing: Spacing.l + Spacing.xxs) {
                    composer
                    chips(alignment: .center)
                }
            }
        }
        .onAppear { draft = controller.preset; showsTerms = !draft.terms.isEmpty }
        .onChange(of: controller.session.id) { _, _ in draft = controller.preset }
        .onChange(of: draft) { _, value in if value != controller.preset { controller.setPreset(value) } }
        .disabled(controller.session.deletedAt != nil)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            topicField.font(.system(size: 15.5))
                .padding(.top, Spacing.xs).padding(.bottom, Spacing.l + Spacing.xs)
            if showsTerms {
                termsEditor.frame(height: 88)
                    .overlay(alignment: .top) { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
                    .padding(.bottom, Spacing.m)
                    .transition(.opacity)
            }
            HStack(spacing: Spacing.s) {
                termsToggle.buttonStyle(GhostButtonStyle(selected: showsTerms))
                Spacer(minLength: Spacing.s)
                if showsStart {
                    SourceMenu(controller: controller)
                    StartButton(controller: controller)
                }
            }
        }
        .padding(.leading, Spacing.l + Spacing.xxs).padding(.trailing, Spacing.m).padding(.vertical, Spacing.m + Spacing.xxs)
        .frame(width: 600)
        .surfaceCard(cornerRadius: 20)
        .animation(Motion.enter(reduced: reduceMotion), value: showsTerms)
    }

    private var topicField: some View {
        TextField("主题（可选），例如：线性代数 · 特征值", text: $draft.topic)
            .textFieldStyle(.plain)
            .foregroundStyle(Palette.ink)
            .focused($topicFocused)
    }

    private var termsToggle: some View {
        Button { showsTerms.toggle() } label: {
            Label(draft.terms.isEmpty ? "术语对照" : "术语对照 · \(draft.terms.count) 条",
                  systemImage: compact ? (showsTerms ? "chevron.down" : "chevron.right") : "character.book.closed")
                .contentTransition(.symbolEffect(.replace))
        }
        .help("每行一条法语术语和对应中文，翻译会照用")
    }

    private var termsEditor: some View {
        TextEditor(text: $draft.glossary)
            .font(.body.monospaced())
            .scrollContentBackground(.hidden)
            .padding(.vertical, Spacing.s)
            .overlay(alignment: .topLeading) {
                if draft.glossary.isEmpty {
                    Text("每行一条，例如：\ncorps = 域\nfonction = 函数").font(.callout).foregroundStyle(Palette.ink3)
                        .padding(.top, Spacing.s).padding(.leading, Spacing.xs + Spacing.xxs).allowsHitTesting(false)
                }
            }
    }

    private func chips(alignment: HorizontalAlignment) -> some View {
        FlowLayout(spacing: Spacing.s, alignment: alignment) {
            ForEach(Subject.allCases) { subject in
                SubjectChip(subject: subject, selected: draft.subject == subject) { draft.subject = subject }
            }
        }
        .frame(maxWidth: 620)
    }
}

/// Selected subject is a solid ink pill; others are hairline outlines. Colour only fades.
struct SubjectChip: View {
    let subject: Subject
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.xs + Spacing.xxs) {
                Image(systemName: subject.symbol).font(.system(size: 11)).opacity(selected ? 0.85 : 1)
                Text(subject.title)
            }
            .font(.system(size: 12.5, weight: selected ? .medium : .regular))
            .foregroundStyle(selected ? Palette.canvas : Palette.ink2)
            .padding(.horizontal, Spacing.m).frame(height: 30)
            .background(Capsule().fill(selected ? Palette.ink : hovering ? Palette.wash : .clear))
            .overlay(Capsule().strokeBorder(selected ? Color.clear : Palette.hairlineStrong, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.16), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Small tag in the class header; opens the preset editor.
struct PresetTag: View {
    let controller: ClassController
    @State private var editing = false
    @State private var hovering = false

    var body: some View {
        let preset = controller.preset
        Button { editing = true } label: {
            HStack(spacing: Spacing.xs + Spacing.xxs) {
                Image(systemName: preset.subject.symbol).font(.system(size: 11)).foregroundStyle(preset.isDefault ? Palette.ink3 : Palette.clayInk)
                Text(preset.isDefault ? "设置课堂预设" : preset.label)
            }
            .font(.system(size: 12.5))
            .foregroundStyle(Palette.ink2)
            .padding(.horizontal, Spacing.m - Spacing.xxs).frame(height: 26)
            .background(Capsule().fill(hovering ? Palette.wash : Color.clear))
            .background(Capsule().fill(Palette.surface))
            .overlay(Capsule().strokeBorder(Palette.hairlineStrong, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("课堂预设：学科、主题和术语会用于翻译")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("课堂预设").font(.display(17))
                Text("翻译会按所选学科理解术语；修改后从下一句开始生效。").font(.callout).foregroundStyle(Palette.ink2)
                PresetEditor(controller: controller, compact: true)
            }
            .padding(Spacing.xl)
            .frame(width: 480)
        }
        .disabled(controller.session.deletedAt != nil)
    }
}

/// Wraps its children onto new lines, like text.
struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat
    var alignment: HorizontalAlignment = .leading

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: LayoutSubviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = alignment == .center ? bounds.minX + (bounds.width - row.width) / 2 : bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(_ subviews: LayoutSubviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: [Int] = [], rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.isEmpty ? size.width : rowWidth + spacing + size.width
            if needed > width, !current.isEmpty {
                rows.append((current, rowWidth, rowHeight)); current = []; rowWidth = 0; rowHeight = 0
            }
            rowWidth = current.isEmpty ? size.width : rowWidth + spacing + size.width
            rowHeight = max(rowHeight, size.height); current.append(index)
        }
        if !current.isEmpty { rows.append((current, rowWidth, rowHeight)) }
        return rows
    }
}
