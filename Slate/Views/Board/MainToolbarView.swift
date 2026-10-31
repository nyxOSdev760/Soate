import SwiftUI
import UIKit

/// The floating bottom toolbar: Select, Text, Pen, Image, Sticky, Undo, Redo.
struct MainToolbarView: View {
    @Bindable var viewModel: BoardViewModel
    let onPhotoLibrary: () -> Void
    let onCamera: () -> Void

    @ScaledMetric(relativeTo: .title3) private var scaledButtonSize: CGFloat = 40

    /// Capped so all seven tools plus undo/redo always fit on a 375-390 pt
    /// wide iPhone (7 x 44 + chrome is about 345 pt), even with large text.
    private var buttonSize: CGFloat {
        min(max(scaledButtonSize, 36), 44)
    }

    var body: some View {
        HStack(spacing: 2) {
            toolButton(.select, systemImage: "cursorarrow", label: "Select")
            toolButton(.text, systemImage: "textformat", label: "Text")
            toolButton(.pen, systemImage: viewModel.penKind.systemImage, label: "Pen")

            Menu {
                Button {
                    onPhotoLibrary()
                } label: {
                    Label("Photo Library", systemImage: "photo.on.rectangle")
                }
                Button {
                    onCamera()
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
                .disabled(!CameraPicker.isAvailable)
            } label: {
                icon("photo", isSelected: false)
            }
            .accessibilityLabel("Add Image")

            toolButton(.sticky, systemImage: "note.text", label: "Sticky Note")

            Divider()
                .frame(height: buttonSize * 0.6)
                .padding(.horizontal, 3)

            Button {
                viewModel.undo()
            } label: {
                icon("arrow.uturn.backward", isSelected: false)
            }
            .disabled(!viewModel.canUndo)
            .accessibilityLabel("Undo")
            .keyboardShortcut("z", modifiers: .command)

            Button {
                viewModel.redo()
            } label: {
                icon("arrow.uturn.forward", isSelected: false)
            }
            .disabled(!viewModel.canRedo)
            .accessibilityLabel("Redo")
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .buttonStyle(.plain)
        .padding(6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
    }

    private func toolButton(_ tool: Tool, systemImage: String, label: String) -> some View {
        let isSelected = viewModel.tool == tool
        return Button {
            viewModel.selectTool(tool)
        } label: {
            icon(systemImage, isSelected: isSelected)
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func icon(_ systemImage: String, isSelected: Bool) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: buttonSize * 0.44, weight: .medium))
            .frame(width: buttonSize, height: buttonSize)
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .background {
                if isSelected {
                    Circle().fill(Color.accentColor.opacity(0.2))
                }
            }
            .contentShape(Circle())
    }
}

/// Options for the active tool when nothing is selected.
struct ToolOptionsView: View {
    @Bindable var viewModel: BoardViewModel

    static func hasOptions(for tool: Tool) -> Bool {
        tool == .pen || tool == .sticky
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch viewModel.tool {
            case .pen:
                penOptions
            case .sticky:
                stickyOptions
            case .select, .text:
                EmptyView()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var penOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Pen type", selection: Binding(get: { viewModel.penKind }, set: { viewModel.setPenKind($0) })) {
                ForEach(PenKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            if viewModel.penKind != .eraser {
                ColorSwatchRow(selected: viewModel.currentPenColor,
                               theme: viewModel.theme,
                               allowsClear: false,
                               allowsAuto: true) { color in
                    viewModel.setPenColor(color)
                }
            } else {
                Text("Erases whole pen and highlighter strokes it touches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundStyle(.secondary)
                Slider(value: Binding(get: { viewModel.currentPenWidth }, set: { viewModel.setPenWidth($0) }),
                       in: widthRange)
                    .accessibilityLabel("Thickness")
                Image(systemName: "circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                Text("\(Int(viewModel.currentPenWidth.rounded()))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24, alignment: .trailing)
            }
        }
    }

    private var widthRange: ClosedRange<Double> {
        switch viewModel.penKind {
        case .pen: return 1...30
        case .highlighter: return 6...60
        case .eraser: return 8...80
        }
    }

    private var stickyOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Tap the board to add a sticky note.")
                .font(.caption)
                .foregroundStyle(.secondary)
            StickyPaletteRow(theme: viewModel.theme, selectedIndex: viewModel.stickyColorIndex) { index in
                viewModel.stickyColorIndex = index
            }
        }
    }
}
