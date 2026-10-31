import PhotosUI
import SwiftUI
import UIKit

/// Loads a board from disk and shows it, or explains why it couldn't open.
struct BoardScreen: View {
    let boardID: UUID

    @State private var viewModel: BoardViewModel?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let viewModel {
                BoardView(viewModel: viewModel)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Board Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else {
                ProgressView()
            }
        }
        .onAppear {
            load()
        }
    }

    private func load() {
        if let viewModel {
            viewModel.reopen()
            return
        }
        guard errorMessage == nil else { return }
        do {
            let result = try BoardStore.shared.loadBoard(id: boardID)
            let model = BoardViewModel(board: result.board)
            if result.recovered {
                model.showNotice("This board was restored from its last good backup.")
            }
            viewModel = model
        } catch {
            errorMessage = error.localizedDescription
            NotificationCenter.default.post(name: .slateBoardsDidChange, object: nil)
        }
    }
}

/// The board editor: canvas, floating toolbar, tool options, inspector and
/// text editing panel.
struct BoardView: View {
    @Bindable var viewModel: BoardViewModel

    @Environment(\.scenePhase) private var scenePhase
    @State private var showThemePicker = false
    @State private var showFontPicker = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showRename = false
    @State private var renameText = ""

    var body: some View {
        ZStack {
            CanvasRepresentable(viewModel: viewModel)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                banners
                Spacer(minLength: 0)
                bottomPanels
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
        }
        .navigationTitle(viewModel.boardName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showThemePicker = true
                } label: {
                    Image(systemName: "paintpalette")
                }
                .accessibilityLabel("Theme and Background")

                Menu {
                    Button {
                        renameText = viewModel.boardName
                        showRename = true
                    } label: {
                        Label("Rename", systemImage: "pencil")
                    }
                    Button {
                        viewModel.selectAll()
                    } label: {
                        Label("Select All", systemImage: "checkmark.circle")
                    }
                    Menu {
                        ForEach(ExportFormat.allCases) { format in
                            Button {
                                viewModel.export(format: format, selectionOnly: false)
                            } label: {
                                Label(format.title, systemImage: format.systemImage)
                            }
                        }
                    } label: {
                        Label("Export Board", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("More")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                viewModel.flushSave()
            }
        }
        .onDisappear {
            viewModel.close()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { @MainActor in
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    viewModel.insertImage(image)
                } else {
                    viewModel.showNotice("That image couldn't be loaded.")
                }
                photoItem = nil
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker(onImage: { image in
                viewModel.insertImage(image)
            }, onFinish: {
                showCamera = false
            })
            .ignoresSafeArea()
        }
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showFontPicker) {
            FontPickerView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $viewModel.shareItem) { item in
            ActivityView(items: [item.url])
                .presentationDetents([.medium, .large])
                .ignoresSafeArea()
        }
        .alert("Rename Board", isPresented: $showRename) {
            TextField("Board name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") {
                viewModel.renameBoard(renameText)
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 8) {
            if let warning = viewModel.storageWarning {
                BannerView(text: warning, systemImage: "externaldrive.badge.exclamationmark", tint: .orange)
            }
            if let notice = viewModel.noticeMessage {
                BannerView(text: notice, systemImage: "info.circle", tint: .accentColor)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 560)
        .padding(.top, 6)
        .animation(.easeInOut(duration: 0.25), value: viewModel.noticeMessage)
    }

    private var bottomPanels: some View {
        VStack(spacing: 10) {
            if viewModel.editingTextID != nil {
                TextEditingPanel(viewModel: viewModel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                if !viewModel.selection.isEmpty {
                    InspectorView(viewModel: viewModel, showFontPicker: $showFontPicker)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                } else if viewModel.showToolOptions && viewModel.tool.hasOptions {
                    ToolOptionsView(viewModel: viewModel)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                }
                MainToolbarView(viewModel: viewModel,
                                onPhotoLibrary: { showPhotoPicker = true },
                                onCamera: { showCamera = true })
            }
        }
        .frame(maxWidth: 560)
        .animation(.snappy(duration: 0.25), value: viewModel.selection.isEmpty)
        .animation(.snappy(duration: 0.25), value: viewModel.tool)
        .animation(.easeOut(duration: 0.2), value: viewModel.showToolOptions)
        .animation(.snappy(duration: 0.25), value: viewModel.editingTextID)
    }
}

struct BannerView: View {
    let text: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label {
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
