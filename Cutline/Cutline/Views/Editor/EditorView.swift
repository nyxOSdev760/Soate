import AVFoundation
import PhotosUI
import SwiftUI

/// Loads a project and shows the editor, or explains why it couldn't open.
struct EditorScreen: View {
    let projectID: UUID
    let home: HomeViewModel

    @State private var viewModel: EditorViewModel?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let viewModel {
                EditorView(viewModel: viewModel)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Project Unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                }
            } else {
                ProgressView()
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        guard viewModel == nil, errorMessage == nil else { return }
        do {
            let result = try ProjectStore.shared.loadProject(id: projectID)
            let model = EditorViewModel(project: result.project)
            if result.recovered {
                model.alert = AlertMessage(title: "Project Recovered",
                                           message: "Cutline restored this project from its last good save after an unexpected shutdown.")
            }
            viewModel = model
            let pending = home.takePendingImports(for: projectID)
            if !pending.isEmpty {
                model.importPicked(pending)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct EditorView: View {
    @Bindable var viewModel: EditorViewModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        VStack(spacing: 0) {
            banners
            PreviewArea(viewModel: viewModel)
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            TransportBar(viewModel: viewModel)
            TimelineView(viewModel: viewModel)
                .frame(height: sizeClass == .regular ? 300 : 230)
            ContextToolbar(viewModel: viewModel)
        }
        .background(Color.black)
        .navigationTitle(viewModel.project.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.activeSheet = .export
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(viewModel.project.videoClips.isEmpty && viewModel.project.texts.isEmpty)
            }
        }
        .photosPicker(isPresented: $viewModel.showMediaPicker, selection: $pickerItems, maxSelectionCount: 30,
                      matching: .any(of: [.videos, .images]), preferredItemEncoding: .current)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            viewModel.importPicked(items)
            pickerItems = []
        }
        .sheet(item: $viewModel.activeSheet) { sheet in
            EditorSheetView(sheet: sheet, viewModel: viewModel)
                .presentationDetents(sheet == .export ? [.large] : [.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .presentationDragIndicator(.visible)
        }
        .overlay {
            if let busy = viewModel.busy {
                BusyOverlay(state: busy) { viewModel.cancelBusy() }
            }
        }
        .alert(item: $viewModel.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                viewModel.playback.pause()
                viewModel.flushSave()
            }
        }
        .onDisappear {
            viewModel.close()
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var banners: some View {
        if !viewModel.missingMedia.isEmpty {
            banner("Missing media: \(viewModel.missingMedia.joined(separator: ", ")). Those clips show black.", icon: "exclamationmark.triangle.fill", tint: .orange)
        }
        if let warning = viewModel.storageWarning {
            banner(warning, icon: "externaldrive.badge.exclamationmark", tint: .orange)
        }
    }

    private func banner(_ text: String, icon: String, tint: Color) -> some View {
        Label {
            Text(text).font(.footnote)
        } icon: {
            Image(systemName: icon).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(.secondarySystemBackground))
    }
}

// MARK: - Preview

struct PreviewArea: View {
    let viewModel: EditorViewModel

    var body: some View {
        let aspect = viewModel.project.canvas.aspect
        ZStack {
            PlayerLayerView(player: viewModel.playback.player)
                .aspectRatio(aspect.ratio, contentMode: .fit)
                .overlay {
                    if viewModel.showSafeArea {
                        SafeAreaGuides(aspect: aspect)
                    }
                }
                .overlay {
                    if !viewModel.playback.isPlaying && viewModel.project.duration > 0 {
                        Image(systemName: "play.fill")
                            .font(.system(size: 28))
                            .padding(18)
                            .background(.black.opacity(0.35), in: Circle())
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.togglePlay()
                }
                .accessibilityLabel(viewModel.playback.isPlaying ? "Pause" : "Play")
                .accessibilityAddTraits(.isButton)

            if viewModel.project.videoClips.isEmpty && viewModel.busy == nil {
                Button {
                    viewModel.showMediaPicker = true
                } label: {
                    Label("Add Videos & Photos", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerUIView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.backgroundColor = .black
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

/// Dashed guides showing where platform UI (captions, buttons, profile
/// info) covers the video.
struct SafeAreaGuides: View {
    let aspect: AspectRatio

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let insets: (top: CGFloat, bottom: CGFloat, left: CGFloat, right: CGFloat) = {
                switch aspect {
                case .vertical: return (0.12, 0.22, 0.05, 0.16)
                case .widescreen: return (0.05, 0.12, 0.05, 0.05)
                case .square, .portrait: return (0.06, 0.1, 0.06, 0.06)
                }
            }()
            let rect = CGRect(x: size.width * insets.left, y: size.height * insets.top,
                              width: size.width * (1 - insets.left - insets.right),
                              height: size.height * (1 - insets.top - insets.bottom))
            Path { path in
                path.addRect(rect)
            }
            .stroke(Color.white.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            Text(aspect.platformName)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .position(x: rect.midX, y: rect.minY + 8)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Transport

struct TransportBar: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        HStack(spacing: 4) {
            Text("\(TimeFormat.string(viewModel.playhead)) / \(TimeFormat.string(viewModel.duration))")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 110, alignment: .leading)
            Spacer()
            Button {
                viewModel.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 44, height: 44)
            }
            .disabled(!viewModel.canUndo)
            .accessibilityLabel(viewModel.undoLabel.map { "Undo \($0)" } ?? "Undo")
            Button {
                viewModel.togglePlay()
            } label: {
                Image(systemName: viewModel.playback.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .frame(width: 52, height: 44)
            }
            .accessibilityLabel(viewModel.playback.isPlaying ? "Pause" : "Play")
            Button {
                viewModel.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 44, height: 44)
            }
            .disabled(!viewModel.canRedo)
            .accessibilityLabel("Redo")
            Spacer()
            Button {
                viewModel.showSafeArea.toggle()
            } label: {
                Image(systemName: viewModel.showSafeArea ? "rectangle.dashed" : "rectangle")
                    .frame(width: 40, height: 44)
            }
            .accessibilityLabel("Safe Area Guides")
            Button {
                viewModel.setMagnetic(!viewModel.project.isMagnetic)
                Haptics.light()
            } label: {
                Image(systemName: viewModel.project.isMagnetic ? "link" : "link.badge.plus")
                    .frame(width: 40, height: 44)
                    .foregroundStyle(viewModel.project.isMagnetic ? Color.accentColor : .secondary)
            }
            .accessibilityLabel(viewModel.project.isMagnetic ? "Magnetic timeline on" : "Magnetic timeline off")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .frame(height: 48)
    }
}
