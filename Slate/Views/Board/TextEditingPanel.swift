import SwiftUI

/// Edits the text of a text object or sticky note. The canvas updates live.
struct TextEditingPanel: View {
    @Bindable var viewModel: BoardViewModel
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(viewModel.editingIsSticky ? "Sticky Note" : "Text",
                      systemImage: viewModel.editingIsSticky ? "note.text" : "textformat")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    viewModel.endEditing()
                }
                .fontWeight(.semibold)
                .keyboardShortcut(.return, modifiers: .command)
            }

            TextEditor(text: Binding(get: { viewModel.editingText }, set: { viewModel.setEditingText($0) }))
                .focused($isFocused)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 64, maxHeight: 150)
                .padding(6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Text")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
        .onAppear {
            isFocused = true
        }
    }
}
