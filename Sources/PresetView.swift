import SwiftUI

/// Subject chips, topic and optional terms. Edits apply immediately, so a change
/// mid-class affects the sentences that follow.
struct PresetEditor: View {
    let controller: ClassController
    var compact = false
    @State private var draft = ClassPreset()
    @State private var showsTerms = false
    @FocusState private var topicFocused: Bool

    var body: some View {
        VStack(alignment: compact ? .leading : .center, spacing: compact ? Spacing.m : Spacing.l) {
            FlowLayout(spacing: Spacing.s, alignment: compact ? .leading : .center) {
                ForEach(Subject.allCases) { subject in
                    SubjectChip(subject: subject, selected: draft.subject == subject) { draft.subject = subject }
                }
            }
            TextField("主题（可选），例如：线性代数 · 特征值", text: $draft.topic)
                .textFieldStyle(.plain)
                .multilineTextAlignment(compact ? .leading : .center)
                .font(compact ? .body : .title3)
                .padding(.vertical, Spacing.s)
                .overlay(alignment: .bottom) { Rectangle().fill(.separator).frame(height: 1) }
                .focused($topicFocused)
                .frame(maxWidth: 420)
            VStack(alignment: .leading, spacing: Spacing.s) {
                Button {
                    showsTerms.toggle()
                } label: {
                    Label(draft.terms.isEmpty ? "术语对照（可选）" : "术语对照 · \(draft.terms.count) 条",
                          systemImage: showsTerms ? "chevron.down" : "chevron.right")
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
                if showsTerms {
                    TextEditor(text: $draft.glossary)
                        .font(.body.monospaced())
                        .scrollContentBackground(.hidden)
                        .padding(Spacing.s)
                        .frame(width: 420, height: 96)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.small))
                        .overlay(alignment: .topLeading) {
                            if draft.glossary.isEmpty {
                                Text("每行一条，例如：\ncorps = 域\nfonction = 函数").font(.callout).foregroundStyle(.tertiary)
                                    .padding(Spacing.s + Spacing.xs).allowsHitTesting(false)
                            }
                        }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)
        }
        .onAppear { draft = controller.preset; showsTerms = !draft.terms.isEmpty }
        .onChange(of: controller.session.id) { _, _ in draft = controller.preset }
        .onChange(of: draft) { _, value in if value != controller.preset { controller.setPreset(value) } }
        .disabled(controller.session.deletedAt != nil)
    }
}

struct SubjectChip: View {
    let subject: Subject
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(subject.title, systemImage: subject.symbol)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s - Spacing.xxs)
                .foregroundStyle(selected ? Color.accentColor : Color.primary)
                .background {
                    Capsule().fill(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(hovering ? 0.12 : 0.07))
                }
                .overlay { Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.35) : .clear) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.easeOut(duration: 0.15), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Small tag in the class header; opens the preset editor.
struct PresetTag: View {
    let controller: ClassController
    @State private var editing = false

    var body: some View {
        let preset = controller.preset
        Button { editing = true } label: {
            Label(preset.isDefault ? "设置课堂预设" : preset.label, systemImage: preset.subject.symbol)
                .font(.callout)
                .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.xs)
                .foregroundStyle(preset.isDefault ? Color.secondary : Color.accentColor)
                .background(Capsule().fill(preset.isDefault ? Color.secondary.opacity(0.08) : Color.accentColor.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help("课堂预设：学科、主题和术语会用于翻译")
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text("课堂预设").font(.headline)
                Text("翻译会按所选学科理解术语；修改后从下一句开始生效。").font(.callout).foregroundStyle(.secondary)
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
