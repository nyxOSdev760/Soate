import SwiftUI
import UIKit

/// Font picker with a live preview of the selected text in each font.
struct FontPickerView: View {
    @Bindable var viewModel: BoardViewModel
    @Environment(\.dismiss) private var dismiss

    private var currentText: TextContent? {
        viewModel.selectedObjects.lazy.compactMap { $0.textContent }.first
    }

    private var previewString: String {
        let text = currentText?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            return "The quick brown fox"
        }
        return String(text.prefix(60))
    }

    var body: some View {
        NavigationStack {
            List {
                if let text = currentText {
                    Section("Preview") {
                        Text(previewString)
                            .font(Font(text.font.uiFont(size: scaled(28), bold: text.isBold, italic: text.isItalic) as CTFont))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
                Section("System Fonts") {
                    ForEach(FontFamily.allCases) { family in
                        let isSelected = currentText?.font == family
                        Button {
                            viewModel.setFont(family)
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(previewString)
                                        .font(Font(family.uiFont(size: scaled(20),
                                                                 bold: currentText?.isBold ?? false,
                                                                 italic: currentText?.isItalic ?? false) as CTFont))
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                    Text(family.displayName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if isSelected {
                                    Image(systemName: "checkmark")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(family.displayName)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            .navigationTitle("Font")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    /// Scales preview sizes with Dynamic Type.
    private func scaled(_ size: CGFloat) -> CGFloat {
        UIFontMetrics(forTextStyle: .body).scaledValue(for: size)
    }
}
