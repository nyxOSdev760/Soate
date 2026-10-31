import SwiftUI

/// Grid of boards sorted by last edit. Long-press a board to rename,
/// duplicate or delete it.
struct HomeView: View {
    @State private var model = HomeViewModel()
    @State private var path: [UUID] = []
    @State private var renameTarget: BoardHeader?
    @State private var renameText = ""
    @State private var deleteTarget: BoardHeader?

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 300), spacing: 16)]

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.boards.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(model.boards) { header in
                                Button {
                                    path.append(header.id)
                                } label: {
                                    BoardCardView(header: header)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        renameText = header.name
                                        renameTarget = header
                                    } label: {
                                        Label("Rename", systemImage: "pencil")
                                    }
                                    Button {
                                        model.duplicate(header.id)
                                    } label: {
                                        Label("Duplicate", systemImage: "plus.square.on.square")
                                    }
                                    Button(role: .destructive) {
                                        deleteTarget = header
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("Slate")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        createBoard()
                    } label: {
                        Image(systemName: "plus")
                            .fontWeight(.semibold)
                    }
                    .accessibilityLabel("New Board")
                    .keyboardShortcut("n", modifiers: .command)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                BoardScreen(boardID: id)
            }
            .onAppear {
                model.reload()
            }
            .onReceive(NotificationCenter.default.publisher(for: .slateBoardsDidChange)) { _ in
                model.reload()
            }
            .alert("Rename Board", isPresented: renamePresented) {
                TextField("Board name", text: $renameText)
                Button("Cancel", role: .cancel) {
                    renameTarget = nil
                }
                Button("Rename") {
                    if let target = renameTarget {
                        model.rename(target.id, to: renameText)
                    }
                    renameTarget = nil
                }
            }
            .confirmationDialog("Delete this board?",
                                isPresented: deletePresented,
                                titleVisibility: .visible,
                                presenting: deleteTarget) { header in
                Button("Delete \u{201C}\(header.name)\u{201D}", role: .destructive) {
                    model.delete(header.id)
                    deleteTarget = nil
                }
                Button("Cancel", role: .cancel) {
                    deleteTarget = nil
                }
            } message: { _ in
                Text("This board and its contents will be permanently deleted.")
            }
            .alert("Slate", isPresented: alertPresented) {
                Button("OK", role: .cancel) {
                    model.alertMessage = nil
                }
            } message: {
                Text(model.alertMessage ?? "")
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Boards Yet", systemImage: "rectangle.on.rectangle.angled")
        } description: {
            Text("Create a board to start sketching ideas.")
        } actions: {
            Button {
                createBoard()
            } label: {
                Label("New Board", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func createBoard() {
        if let id = model.createBoard() {
            path.append(id)
        }
    }

    private var renamePresented: Binding<Bool> {
        Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })
    }

    private var deletePresented: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var alertPresented: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }
}
