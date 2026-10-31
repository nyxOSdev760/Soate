import SwiftUI

/// Bottom toolbar whose tools follow the selection. Every tool is one tap.
struct ContextToolbar: View {
    @Bindable var viewModel: EditorViewModel

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                tools
            }
            .padding(.horizontal, 8)
        }
        .frame(height: 76)
        .background(.bar)
        .animation(.snappy(duration: 0.2), value: viewModel.selection)
    }

    @ViewBuilder
    private var tools: some View {
        switch viewModel.selection {
        case nil:
            ToolButton(title: "Add Media", systemImage: "plus.rectangle.on.rectangle") { viewModel.showMediaPicker = true }
            ToolButton(title: "Text", systemImage: "textformat") { viewModel.addText() }
            ToolButton(title: "Audio", systemImage: "music.note") { viewModel.activeSheet = .audio }
            ToolButton(title: "Overlay", systemImage: "sparkles") { viewModel.activeSheet = .overlay }
            ToolButton(title: "Captions", systemImage: "captions.bubble") { viewModel.activeSheet = .captions }
            ToolButton(title: "Filters", systemImage: "camera.filters") { viewModel.activeSheet = .filters }
            ToolButton(title: "Canvas", systemImage: "aspectratio") { viewModel.activeSheet = .canvas }
            ToolButton(title: "Export", systemImage: "square.and.arrow.up") { viewModel.activeSheet = .export }
        case .video:
            doneButton
            if let clip = viewModel.selectedVideoClip {
                ToolButton(title: "Split", systemImage: "scissors") { viewModel.splitAtPlayhead() }
                ToolButton(title: "Trim", systemImage: "timeline.selection") { viewModel.activeSheet = .trim }
                if !clip.isImage {
                    ToolButton(title: "Speed", systemImage: "speedometer") { viewModel.activeSheet = .speed }
                    ToolButton(title: "Volume", systemImage: clip.isMuted ? "speaker.slash" : "speaker.wave.2") { viewModel.activeSheet = .volume }
                }
                ToolButton(title: "Crop", systemImage: "crop.rotate") { viewModel.activeSheet = .crop }
                ToolButton(title: "Animate", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { viewModel.activeSheet = .animate }
                ToolButton(title: "Effects", systemImage: "wand.and.stars") { viewModel.activeSheet = .effects }
                ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") { viewModel.duplicateSelection() }
                ToolButton(title: "Delete", systemImage: "trash", tint: .red) { viewModel.deleteSelection() }
                if !clip.isImage {
                    ToolButton(title: "Freeze", systemImage: "snowflake") { viewModel.freezeFrame() }
                    ToolButton(title: "Reverse", systemImage: "backward.fill", isOn: clip.isReversed) { viewModel.reverseSelectedClip() }
                    ToolButton(title: "Stabilize", systemImage: "camera.metering.center.weighted", isOn: clip.stabilization != nil) { viewModel.toggleStabilization() }
                    ToolButton(title: "Detach Audio", systemImage: "waveform.badge.minus") { viewModel.detachAudio() }
                    ToolButton(title: "Clean Audio", systemImage: "waveform.badge.magnifyingglass") { viewModel.cleanAudio() }
                }
                ToolButton(title: "Copy Effects", systemImage: "doc.on.doc") { viewModel.copyLook() }
                if viewModel.copiedLook != nil {
                    ToolButton(title: "Paste Effects", systemImage: "doc.on.clipboard") { viewModel.pasteLook() }
                }
            }
        case .audio:
            doneButton
            if let clip = viewModel.selectedAudioClip {
                ToolButton(title: "Split", systemImage: "scissors") { viewModel.splitAtPlayhead() }
                ToolButton(title: "Volume", systemImage: clip.isMuted ? "speaker.slash" : "speaker.wave.2") { viewModel.activeSheet = .volume }
                ToolButton(title: "Trim", systemImage: "timeline.selection") { viewModel.activeSheet = .trim }
                ToolButton(title: "Beats", systemImage: "metronome") { viewModel.detectBeats() }
                ToolButton(title: "Clean Audio", systemImage: "waveform.badge.magnifyingglass") { viewModel.cleanAudio() }
                ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") { viewModel.duplicateSelection() }
                ToolButton(title: "Delete", systemImage: "trash", tint: .red) { viewModel.deleteSelection() }
            }
        case .text:
            doneButton
            ToolButton(title: "Edit", systemImage: "character.cursor.ibeam") { viewModel.activeSheet = .text }
            ToolButton(title: "Animate", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { viewModel.activeSheet = .animate }
            ToolButton(title: "Trim", systemImage: "timeline.selection") { viewModel.activeSheet = .trim }
            ToolButton(title: "Split", systemImage: "scissors") { viewModel.splitAtPlayhead() }
            ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") { viewModel.duplicateSelection() }
            ToolButton(title: "Delete", systemImage: "trash", tint: .red) { viewModel.deleteSelection() }
        case .overlay:
            doneButton
            ToolButton(title: "Edit", systemImage: "slider.horizontal.3") { viewModel.activeSheet = .overlay }
            ToolButton(title: "Animate", systemImage: "point.topleft.down.to.point.bottomright.curvepath") { viewModel.activeSheet = .animate }
            ToolButton(title: "Trim", systemImage: "timeline.selection") { viewModel.activeSheet = .trim }
            ToolButton(title: "Split", systemImage: "scissors") { viewModel.splitAtPlayhead() }
            ToolButton(title: "Duplicate", systemImage: "plus.square.on.square") { viewModel.duplicateSelection() }
            ToolButton(title: "Delete", systemImage: "trash", tint: .red) { viewModel.deleteSelection() }
        case .caption:
            doneButton
            ToolButton(title: "Edit", systemImage: "character.cursor.ibeam") { viewModel.activeSheet = .captions }
            ToolButton(title: "Style", systemImage: "textformat.size") { viewModel.activeSheet = .captions }
            ToolButton(title: "Delete", systemImage: "trash", tint: .red) { viewModel.deleteSelection() }
        }
    }

    private var doneButton: some View {
        ToolButton(title: "Done", systemImage: "chevron.down.circle") {
            viewModel.select(nil)
        }
    }
}

/// Routes each sheet case to its view.
struct EditorSheetView: View {
    let sheet: EditorSheet
    let viewModel: EditorViewModel

    var body: some View {
        switch sheet {
        case .text: TextSheet(viewModel: viewModel)
        case .audio: AudioSheet(viewModel: viewModel)
        case .overlay: OverlaySheet(viewModel: viewModel)
        case .captions: CaptionsSheet(viewModel: viewModel)
        case .filters: EffectsSheet(viewModel: viewModel, isGlobal: true)
        case .canvas: CanvasSheet(viewModel: viewModel)
        case .export: ExportSheet(viewModel: viewModel)
        case .speed: SpeedSheet(viewModel: viewModel)
        case .volume: VolumeSheet(viewModel: viewModel)
        case .crop: CropSheet(viewModel: viewModel)
        case .animate: AnimateSheet(viewModel: viewModel)
        case .effects: EffectsSheet(viewModel: viewModel, isGlobal: false)
        case .trim: TrimSheet(viewModel: viewModel)
        case .transition: TransitionSheet(viewModel: viewModel)
        }
    }
}
