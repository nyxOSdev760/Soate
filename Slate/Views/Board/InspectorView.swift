import SwiftUI

/// Contextual controls for the current selection. Shows a section for every
/// kind of object in the selection; edits apply to all selected objects of
/// that kind.
struct InspectorView: View {
    @Bindable var viewModel: BoardViewModel
    @Binding var showFontPicker: Bool
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        let objects = viewModel.selectedObjects
        let editable = objects.filter { !$0.isLocked }
        let theme = viewModel.theme

        VStack(alignment: .leading, spacing: 12) {
            actionRow(objects: objects, editable: editable)

            if !editable.isEmpty {
                ViewThatFits(in: .vertical) {
                    sections(editable: editable, theme: theme)
                    ScrollView {
                        sections(editable: editable, theme: theme)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
                .frame(maxHeight: verticalSizeClass == .compact ? 140 : 280)
            } else if !objects.isEmpty {
                Label("Locked. Unlock to move or edit.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    // MARK: Actions

    private func actionRow(objects: [BoardObject], editable: [BoardObject]) -> some View {
        let isLocked = viewModel.selectionIsLocked
        let canEditText = objects.count == 1 && (objects.first?.isEditableText ?? false) && !isLocked
        return VStack(alignment: .leading, spacing: 8) {
            // Title row: what is selected, plus deselect.
            HStack(spacing: 8) {
                Text(objects.count == 1 ? (objects.first?.kindName ?? "") : "\(objects.count) Selected")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
                actionButton("xmark", label: "Deselect") {
                    viewModel.clearSelection()
                }
                .keyboardShortcut(.escape, modifiers: [])
            }
            // Actions row: sized to fit a 375-390 pt wide iPhone.
            HStack(spacing: 6) {
                if canEditText, let id = objects.first?.id {
                    actionButton("character.cursor.ibeam", label: "Edit Text") {
                        viewModel.beginEditing(id)
                    }
                }
                actionButton("plus.square.on.square", label: "Duplicate") {
                    viewModel.duplicateSelection()
                }
                .keyboardShortcut("d", modifiers: .command)
                actionButton("square.2.layers.3d.top.filled", label: "Bring Forward") {
                    viewModel.bringForward()
                }
                .keyboardShortcut("]", modifiers: .command)
                actionButton("square.2.layers.3d.bottom.filled", label: "Send Backward") {
                    viewModel.sendBackward()
                }
                .keyboardShortcut("[", modifiers: .command)
                actionButton(isLocked ? "lock.fill" : "lock.open", label: isLocked ? "Unlock" : "Lock") {
                    viewModel.toggleLock()
                }
                Menu {
                    ForEach(ExportFormat.allCases) { format in
                        Button {
                            viewModel.export(format: format, selectionOnly: true)
                        } label: {
                            Label("Export Selection as \(format.title)", systemImage: format.systemImage)
                        }
                    }
                } label: {
                    actionIcon("square.and.arrow.up")
                }
                .accessibilityLabel("Export Selection")
                Spacer(minLength: 0)
                actionButton("trash", label: "Delete", role: .destructive) {
                    viewModel.deleteSelection()
                }
                .disabled(editable.isEmpty)
                .keyboardShortcut(.delete, modifiers: [])
            }
        }
        .buttonStyle(.plain)
    }

    private func actionButton(_ systemImage: String,
                              label: String,
                              role: ButtonRole? = nil,
                              action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            actionIcon(systemImage)
                .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        }
        .accessibilityLabel(label)
    }

    private func actionIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.body.weight(.medium))
            .frame(width: 34, height: 34)
            .background(Color.primary.opacity(0.06), in: Circle())
            .contentShape(Circle())
    }

    // MARK: Sections

    @ViewBuilder
    private func sections(editable: [BoardObject], theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let text = editable.lazy.compactMap({ $0.textContent }).first {
                textSection(text, theme: theme)
            }
            if let sticky = editable.lazy.compactMap({ $0.stickyContent }).first {
                stickySection(sticky, theme: theme)
            }
            if let stroke = editable.lazy.compactMap({ $0.strokeContent }).first {
                strokeSection(stroke, theme: theme)
            }
            if let image = editable.lazy.compactMap({ $0.imageContent }).first {
                imageSection(image)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func textSection(_ text: TextContent, theme: Theme) -> some View {
        InspectorSection(title: "Text") {
            HStack(spacing: 8) {
                Button {
                    showFontPicker = true
                } label: {
                    HStack {
                        Text(text.font.displayName)
                            .font(Font(text.font.uiFont(size: 17) as CTFont))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 36)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Font, \(text.font.displayName)")

                toggleButton("bold", label: "Bold", isOn: text.isBold) {
                    viewModel.setBold(!text.isBold)
                }
                .keyboardShortcut("b", modifiers: .command)
                toggleButton("italic", label: "Italic", isOn: text.isItalic) {
                    viewModel.setItalic(!text.isItalic)
                }
                .keyboardShortcut("i", modifiers: .command)
            }

            HStack(spacing: 10) {
                Picker("Alignment", selection: Binding(get: { text.alignment }, set: { viewModel.setAlignment($0) })) {
                    ForEach(TextAlign.allCases) { alignment in
                        Image(systemName: alignment.systemImage)
                            .accessibilityLabel(alignment.title)
                            .tag(alignment)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 160)

                SizeStepper(value: text.fontSize, range: 4...600) { viewModel.setFontSize($0) }
            }

            ColorSwatchRow(selected: text.color, theme: theme, allowsClear: false, allowsAuto: true) { color in
                viewModel.setTextColor(color)
            }
        }
    }

    private func stickySection(_ sticky: StickyContent, theme: Theme) -> some View {
        InspectorSection(title: "Sticky Note") {
            StickyPaletteRow(theme: theme, selectedIndex: stickyIndex(sticky.color)) { index in
                viewModel.setStickyColor(index)
            }
            HStack {
                Text("Text Size")
                    .font(.subheadline)
                Spacer()
                SizeStepper(value: sticky.fontSize, range: 4...400) { viewModel.setFontSize($0) }
            }
        }
    }

    private func stickyIndex(_ color: PaintColor) -> Int? {
        if case .sticky(let index) = color {
            return index
        }
        return nil
    }

    private func strokeSection(_ stroke: StrokeContent, theme: Theme) -> some View {
        InspectorSection(title: stroke.isHighlighter ? "Highlight" : "Drawing") {
            ColorSwatchRow(selected: stroke.color, theme: theme, allowsClear: false, allowsAuto: true) { color in
                viewModel.setStrokeColor(color)
            }
            widthSlider(value: stroke.width, range: 0.5...80)
        }
    }

    private func imageSection(_ image: ImageContent) -> some View {
        InspectorSection(title: "Image") {
            HStack(spacing: 10) {
                Text("Opacity")
                    .font(.subheadline)
                Slider(value: Binding(get: { image.opacity }, set: { viewModel.setOpacity($0) }), in: 0.05...1)
                    .accessibilityLabel("Opacity")
                Text("\(Int((image.opacity * 100).rounded()))%")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 40, alignment: .trailing)
            }
        }
    }

    // MARK: Controls

    private func widthSlider(value: Double, range: ClosedRange<Double>) -> some View {
        let upper = max(range.upperBound, value)
        return HStack(spacing: 10) {
            Text("Width")
                .font(.subheadline)
            Slider(value: Binding(get: { value }, set: { viewModel.setStrokeWidth($0) }), in: range.lowerBound...upper)
                .accessibilityLabel("Stroke width")
            Text(value < 10 ? String(format: "%.1f", value) : "\(Int(value.rounded()))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    private func toggleButton(_ systemImage: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 36, height: 36)
                .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                .background(isOn ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct InspectorSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// Compact size control: minus, value, plus.
struct SizeStepper: View {
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button {
                onChange(max(range.lowerBound, stepDown(value)))
            } label: {
                Image(systemName: "minus")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Smaller")
            Text("\(Int(value.rounded()))")
                .font(.subheadline.monospacedDigit())
                .frame(minWidth: 34)
                .accessibilityLabel("Size \(Int(value.rounded()))")
            Button {
                onChange(min(range.upperBound, stepUp(value)))
            } label: {
                Image(systemName: "plus")
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Larger")
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func step(for value: Double) -> Double {
        if value < 12 { return 1 }
        if value < 48 { return 2 }
        if value < 120 { return 8 }
        return 24
    }

    private func stepUp(_ value: Double) -> Double {
        value + step(for: value)
    }

    private func stepDown(_ value: Double) -> Double {
        value - step(for: value - 0.5)
    }
}
