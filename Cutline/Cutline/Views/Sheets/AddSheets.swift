import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Overlays

struct OverlaySheet: View {
    let viewModel: EditorViewModel
    @State private var imageItem: PhotosPickerItem?

    private static let stickers = ["😂", "🔥", "❤️", "😍", "👏", "🎉", "✨", "💯", "😎", "🤯", "👀", "🙌",
                                   "⭐️", "⚡️", "🌈", "🎵", "📍", "✅", "❌", "👉", "👆", "💥", "🍿", "🚀"]

    var body: some View {
        SheetContainer(title: viewModel.selectedOverlay == nil ? "Add Overlay" : "Overlay") {
            if let overlay = viewModel.selectedOverlay {
                editor(overlay)
            } else {
                picker
            }
        }
    }

    private var picker: some View {
        Form {
            Section("Image") {
                PhotosPicker(selection: $imageItem, matching: .images) {
                    Label("Choose a Photo", systemImage: "photo")
                }
                .onChange(of: imageItem) { _, item in
                    guard let item else { return }
                    viewModel.addImageOverlay(item)
                    imageItem = nil
                }
            }
            Section("Stickers") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 48))], spacing: 10) {
                    ForEach(OverlaySheet.stickers, id: \.self) { emoji in
                        Button {
                            viewModel.addOverlay(.sticker(emoji))
                        } label: {
                            Text(emoji)
                                .font(.system(size: 32))
                                .frame(width: 48, height: 48)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Sticker \(emoji)")
                    }
                }
            }
            Section("Shapes") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))], spacing: 10) {
                    ForEach(OverlayShape.allCases) { shape in
                        Button {
                            viewModel.addOverlay(.shape(shape))
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: shape.systemImage)
                                    .font(.title2)
                                    .foregroundStyle(Color.yellow)
                                    .frame(height: 32)
                                Text(shape.title)
                                    .font(.caption2)
                            }
                            .frame(width: 64, height: 60)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func editor(_ overlay: OverlayItem) -> some View {
        let id = overlay.id
        return Form {
            Section {
                SliderRow(title: "Size", value: Binding(get: { overlay.size }, set: { value in
                    viewModel.updateOverlay(id, "Size", coalescing: "size") { $0.size = value }
                }), range: 0.05...1.2, format: { "\(Int($0 * 100))%" })
                SliderRow(title: "Opacity", value: Binding(get: { overlay.transform.opacity }, set: { value in
                    viewModel.updateOverlay(id, "Opacity", coalescing: "opacity") { item in
                        item.transform.opacity = value
                        for index in item.keyframes.indices {
                            item.keyframes[index].values.opacity = value
                        }
                    }
                }), range: 0...1, format: { "\(Int($0 * 100))%" })
                SliderRow(title: "Rotation", value: Binding(get: { overlay.transform.rotation }, set: { value in
                    viewModel.updateOverlay(id, "Rotate", coalescing: "rotation") { $0.transform.rotation = value }
                }), range: -180...180, format: { "\(Int($0))°" })
            } footer: {
                Text("Use Animate to move, scale and rotate over time.")
            }
            if case .shape = overlay.content {
                Section {
                    ColorSwatchPicker(title: "Color", selected: overlay.color) { color in
                        viewModel.updateOverlay(id, "Color", coalescing: "color") { $0.color = color }
                    }
                }
            }
        }
    }
}

// MARK: - Audio

struct AudioSheet: View {
    let viewModel: EditorViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    @State private var recorder = VoiceoverRecorder()
    @State private var recordingFile: String?
    @State private var recordingStart: Double = 0
    @State private var permissionDenied = false

    var body: some View {
        SheetContainer(title: "Audio") {
            Form {
                Section {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Music from Files", systemImage: "folder")
                    }
                } footer: {
                    Text("Music is placed at the playhead. Beats are detected automatically so cuts can snap to them.")
                }
                Section("Voiceover") {
                    VStack(spacing: 14) {
                        Text(TimeFormat.string(recorder.elapsed))
                            .font(.system(size: 36, weight: .semibold).monospacedDigit())
                        LevelMeter(level: recorder.level)
                            .frame(height: 6)
                        Button {
                            Task { await toggleRecording() }
                        } label: {
                            ZStack {
                                Circle().strokeBorder(Color.white, lineWidth: 4).frame(width: 72, height: 72)
                                if recorder.isRecording {
                                    RoundedRectangle(cornerRadius: 6).fill(Color.red).frame(width: 28, height: 28)
                                } else {
                                    Circle().fill(Color.red).frame(width: 56, height: 56)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(recorder.isRecording ? "Stop Recording" : "Record Voiceover")
                        Text(recorder.isRecording ? "Recording… the video plays along." : "Records from the playhead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        if permissionDenied {
                            Text("Microphone access is off. Turn it on in Settings > Privacy & Security > Microphone.")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .movie]) { result in
            switch result {
            case .success(let url):
                viewModel.importMusic(from: url)
                dismiss()
            case .failure(let error):
                viewModel.alert = AlertMessage(title: "Couldn't Open File", message: error.localizedDescription)
            }
        }
        .onDisappear {
            if recorder.isRecording, let recordingFile {
                recorder.stop()
                viewModel.playback.pause()
                viewModel.addVoiceover(fileName: recordingFile, startTime: recordingStart)
                self.recordingFile = nil
            }
        }
    }

    private func toggleRecording() async {
        if recorder.isRecording {
            recorder.stop()
            viewModel.playback.pause()
            if let recordingFile {
                viewModel.addVoiceover(fileName: recordingFile, startTime: recordingStart)
            }
            recordingFile = nil
            dismiss()
            return
        }
        guard await VoiceoverRecorder.requestPermission() else {
            permissionDenied = true
            return
        }
        let fileName = "\(UUID().uuidString)-voiceover.m4a"
        let url = ProjectStore.shared.mediaURL(projectID: viewModel.project.id, fileName: fileName)
        do {
            try ProjectStore.shared.ensureSpace(bytes: 20_000_000)
            recordingStart = viewModel.playhead
            try recorder.start(url: url)
            recordingFile = fileName
            viewModel.playback.play(from: viewModel.playhead)
            Haptics.medium()
        } catch {
            viewModel.alert = AlertMessage(title: "Recording Unavailable", message: error.localizedDescription)
        }
    }
}

struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(level > 0.85 ? Color.red : Color.green)
                    .frame(width: geometry.size.width * level)
            }
        }
        .animation(.linear(duration: 0.05), value: level)
    }
}

// MARK: - Captions

struct CaptionsSheet: View {
    let viewModel: EditorViewModel

    var body: some View {
        SheetContainer(title: "Captions") {
            let captions = viewModel.project.captions
            Form {
                if captions.lines.isEmpty {
                    Section {
                        Button {
                            viewModel.generateCaptions()
                        } label: {
                            Label("Generate Captions", systemImage: "waveform.and.mic")
                                .font(.headline)
                        }
                    } footer: {
                        Text("Speech in your clips and voiceovers is turned into timed captions on this iPhone. Nothing leaves your device.")
                    }
                } else {
                    Section("Style") {
                        HStack(spacing: 10) {
                            ForEach(CaptionStyle.allCases) { style in
                                Button {
                                    viewModel.setCaptionStyle(style)
                                    Haptics.light()
                                } label: {
                                    CaptionStylePreview(style: style, isSelected: captions.style == style)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Picker("Font", selection: Binding(get: { captions.font }, set: { viewModel.setCaptionFont($0) })) {
                            ForEach(FontChoice.allCases) { Text($0.displayName).tag($0) }
                        }
                    }
                    Section("Lines") {
                        ForEach(captions.lines) { line in
                            CaptionLineRow(line: line, viewModel: viewModel)
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { captions.lines[$0].id }
                            viewModel.mutate("Delete Caption") { project in
                                project.captions.lines.removeAll { ids.contains($0.id) }
                            }
                        }
                    }
                    Section {
                        Button("Regenerate") { viewModel.generateCaptions() }
                        Button("Remove All Captions", role: .destructive) { viewModel.removeAllCaptions() }
                    }
                }
            }
        }
    }
}

struct CaptionLineRow: View {
    let line: CaptionLine
    let viewModel: EditorViewModel
    @State private var text = ""

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Button {
                viewModel.scrub(to: line.start)
            } label: {
                Text(TimeFormat.string(line.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.borderless)
            TextField("Caption", text: $text, axis: .vertical)
                .onSubmit { commit() }
                .onChange(of: text) { _, _ in commit() }
        }
        .onAppear { text = line.text }
    }

    private func commit() {
        guard text != line.text else { return }
        viewModel.updateCaptionText(line.id, text: text)
    }
}

struct CaptionStylePreview: View {
    let style: CaptionStyle
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.15))
                switch style {
                case .boldCenter:
                    Text("HELLO")
                        .font(.system(size: 13, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 1)
                case .karaoke:
                    (Text("Hey ").foregroundColor(.white) + Text("there").foregroundColor(.yellow))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                case .minimalBottom:
                    Text("hello")
                        .font(.system(size: 10))
                        .padding(.horizontal, 4)
                        .background(Color.black.opacity(0.6))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 6)
                }
            }
            .frame(height: 50)
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 2))
            Text(style.title)
                .font(.caption2)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Canvas

struct CanvasSheet: View {
    let viewModel: EditorViewModel

    var body: some View {
        SheetContainer(title: "Canvas") {
            Form {
                Section("Format") {
                    ForEach(AspectRatio.allCases) { aspect in
                        Button {
                            viewModel.setAspect(aspect)
                            Haptics.light()
                        } label: {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.primary, lineWidth: 1.5)
                                    .aspectRatio(aspect.ratio, contentMode: .fit)
                                    .frame(width: 30, height: 30)
                                VStack(alignment: .leading) {
                                    Text(aspect.title).font(.headline)
                                    Text(aspect.platformName).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if viewModel.project.canvas.aspect == aspect {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                Section {
                    Picker("Background", selection: Binding(get: { viewModel.project.canvas.background }, set: { viewModel.setBackground($0) })) {
                        ForEach(CanvasBackground.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Background")
                } footer: {
                    Text("Shown around clips that use Fit. Blur fills the frame with a blurred copy of the clip.")
                }
                Section {
                    Toggle("Magnetic Timeline", isOn: Binding(get: { viewModel.project.isMagnetic }, set: { viewModel.setMagnetic($0) }))
                    Toggle("Safe Area Guides", isOn: Binding(get: { viewModel.showSafeArea }, set: { viewModel.showSafeArea = $0 }))
                } footer: {
                    Text("Magnetic timeline closes gaps automatically when you trim, move or delete clips.")
                }
            }
        }
    }
}

// MARK: - Export

struct ExportSheet: View {
    let viewModel: EditorViewModel
    @State private var exporter: ExportViewModel?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let exporter {
                    ExportContent(exporter: exporter, playhead: viewModel.playhead)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        exporter?.cancel()
                        dismiss()
                    }
                }
            }
        }
        .interactiveDismissDisabled(isExporting)
        .onAppear {
            if exporter == nil {
                viewModel.playback.pause()
                exporter = ExportViewModel(project: viewModel.exportSnapshot)
            }
        }
    }

    private var isExporting: Bool {
        if case .exporting = exporter?.phase { return true }
        return false
    }
}

struct ExportContent: View {
    @Bindable var exporter: ExportViewModel
    let playhead: Double

    var body: some View {
        Group {
            switch exporter.phase {
            case .settings:
                settingsForm
            case .exporting(let progress):
                VStack(spacing: 20) {
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.15), lineWidth: 10)
                        Circle().trim(from: 0, to: progress)
                            .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(Int(progress * 100))%")
                            .font(.title.monospacedDigit().weight(.semibold))
                    }
                    .frame(width: 160, height: 160)
                    .animation(.linear(duration: 0.2), value: progress)
                    Text("Exporting \(exporter.renderSizeText)…")
                        .font(.headline)
                    Text("You can switch apps briefly; iOS allows a short time to finish in the background.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Cancel", role: .destructive) { exporter.cancel() }
                        .buttonStyle(.bordered)
                }
                .padding(32)
            case .finished:
                VStack(spacing: 18) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                    Text("Your video is ready")
                        .font(.title2.weight(.semibold))
                    Button {
                        exporter.saveToPhotos()
                    } label: {
                        Label(exporter.savedToPhotos ? "Saved to Photos" : "Save to Photos",
                              systemImage: exporter.savedToPhotos ? "checkmark" : "photo.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(exporter.savedToPhotos)
                    Button {
                        exporter.share()
                    } label: {
                        Label("Share", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    Button("Export Again") { exporter.reset() }
                    if let message = exporter.message {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(28)
            case .failed(let message):
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { exporter.reset() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(28)
            }
        }
        .sheet(item: Binding(get: { exporter.shareURL.map(ShareFile.init) }, set: { exporter.shareURL = $0?.url })) { file in
            ActivityView(items: [file.url])
                .presentationDetents([.medium, .large])
        }
    }

    private var settingsForm: some View {
        Form {
            Section {
                Picker("Resolution", selection: $exporter.settings.resolution) {
                    ForEach(ExportResolution.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Frame Rate", selection: $exporter.settings.frameRate) {
                    ForEach([24, 30, 60], id: \.self) { Text("\($0) fps").tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Format", selection: $exporter.settings.codec) {
                    ForEach(ExportCodec.allCases) { Text("MP4 · \($0.title)").tag($0) }
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Quality", value: $exporter.settings.quality, range: 0...1,
                          format: { $0 < 0.34 ? "Smaller" : ($0 < 0.67 ? "Balanced" : "Best") })
            } header: {
                Text("Video")
            } footer: {
                Text("\(exporter.renderSizeText) · \(TimeFormat.string(exporter.duration)) · about \(exporter.estimatedSize)")
            }
            Section {
                Button {
                    exporter.start()
                } label: {
                    Label("Export Video", systemImage: "square.and.arrow.up")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowBackground(Color.clear)
            }
            Section("More") {
                Button {
                    exporter.exportAudioOnly()
                } label: {
                    Label("Export Audio Only", systemImage: "waveform")
                }
                Button {
                    exporter.saveStillFrame(at: playhead)
                } label: {
                    Label("Save Frame at Playhead", systemImage: "photo")
                }
                if let message = exporter.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct ShareFile: Identifiable {
    let url: URL
    var id: String { url.path }
}
