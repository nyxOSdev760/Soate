import SwiftUI

struct NothingSelectedView: View {
    var body: some View {
        ContentUnavailableView("Nothing Selected", systemImage: "hand.tap",
                               description: Text("Select a clip on the timeline first."))
    }
}

// MARK: - Trim

struct TrimSheet: View {
    let viewModel: EditorViewModel

    var body: some View {
        SheetContainer(title: "Trim") {
            Form {
                switch viewModel.selection {
                case .video(let id):
                    if let clip = viewModel.selectedVideoClip {
                        if clip.isImage {
                            Section {
                                SliderRow(title: "Duration", value: Binding(get: { clip.duration }, set: { value in
                                    viewModel.updateVideoClip(id, "Duration", coalescing: "trim") { $0.trimEnd = $0.trimStart + value }
                                }), range: 0.5...30, format: { String(format: "%.1fs", $0) })
                            }
                        } else {
                            let mediaDuration = viewModel.media(for: clip.mediaID)?.duration ?? clip.trimEnd
                            Section {
                                SliderRow(title: "Start", value: Binding(get: { clip.trimStart }, set: { value in
                                    viewModel.updateVideoClip(id, "Trim", coalescing: "trim") { $0.trimStart = min(value, $0.trimEnd - 0.1) }
                                }), range: 0...max(mediaDuration, 0.2), format: { TimeFormat.string($0) })
                                SliderRow(title: "End", value: Binding(get: { clip.trimEnd }, set: { value in
                                    viewModel.updateVideoClip(id, "Trim", coalescing: "trim") { $0.trimEnd = max(value, $0.trimStart + 0.1) }
                                }), range: 0...max(mediaDuration, 0.2), format: { TimeFormat.string($0) })
                            } footer: {
                                Text("Clip length on the timeline: \(TimeFormat.string(clip.duration)). You can also drag the yellow handles.")
                            }
                        }
                    }
                case .audio(let id):
                    if let clip = viewModel.selectedAudioClip {
                        let mediaDuration = viewModel.media(for: clip.mediaID)?.duration ?? clip.trimEnd
                        Section {
                            SliderRow(title: "Start", value: Binding(get: { clip.trimStart }, set: { value in
                                viewModel.updateAudioClip(id, "Trim", coalescing: "trim") { $0.trimStart = min(value, $0.trimEnd - 0.1) }
                            }), range: 0...max(mediaDuration, 0.2), format: { TimeFormat.string($0) })
                            SliderRow(title: "End", value: Binding(get: { clip.trimEnd }, set: { value in
                                viewModel.updateAudioClip(id, "Trim", coalescing: "trim") { $0.trimEnd = max(value, $0.trimStart + 0.1) }
                            }), range: 0...max(mediaDuration, 0.2), format: { TimeFormat.string($0) })
                        }
                    }
                case .text(let id):
                    if let item = viewModel.selectedText {
                        timingSection(start: item.startTime, duration: item.duration) { start, duration in
                            viewModel.updateText(id, "Timing", coalescing: "trim") {
                                $0.startTime = start
                                $0.duration = duration
                            }
                        }
                    }
                case .overlay(let id):
                    if let item = viewModel.selectedOverlay {
                        timingSection(start: item.startTime, duration: item.duration) { start, duration in
                            viewModel.updateOverlay(id, "Timing", coalescing: "trim") {
                                $0.startTime = start
                                $0.duration = duration
                            }
                        }
                    }
                default:
                    NothingSelectedView()
                }
            }
        }
    }

    private func timingSection(start: Double, duration: Double, update: @escaping (Double, Double) -> Void) -> some View {
        Section {
            SliderRow(title: "Starts at", value: Binding(get: { start }, set: { update($0, duration) }),
                      range: 0...max(viewModel.duration, start + 1), format: { TimeFormat.string($0) })
            SliderRow(title: "Duration", value: Binding(get: { duration }, set: { update(start, $0) }),
                      range: 0.2...max(30, duration), format: { String(format: "%.1fs", $0) })
            Button("Start at Playhead") {
                update(viewModel.playhead, duration)
            }
        }
    }
}

// MARK: - Speed

struct SpeedSheet: View {
    let viewModel: EditorViewModel

    var body: some View {
        SheetContainer(title: "Speed") {
            if let clip = viewModel.selectedVideoClip {
                Form {
                    Section {
                        SliderRow(title: "Speed", value: Binding(get: { log(clip.speed.rate) }, set: { value in
                            let rate = (exp(value) * 100).rounded() / 100
                            viewModel.updateVideoClip(clip.id, "Speed", coalescing: "speed") { $0.speed.rate = rate }
                        }), range: log(SpeedMath.minSpeed)...log(SpeedMath.maxSpeed), format: { String(format: "%.2f×", exp($0)) })
                        HStack {
                            ForEach([0.25, 0.5, 1, 2, 4, 8], id: \.self) { rate in
                                Button(rate < 1 ? String(format: "%.2g×", rate) : "\(Int(rate))×") {
                                    viewModel.updateVideoClip(clip.id, "Speed") { $0.speed.rate = rate }
                                    Haptics.light()
                                }
                                .buttonStyle(.bordered)
                                .tint(clip.speed.rate == rate ? .accentColor : .gray)
                                .frame(maxWidth: .infinity)
                            }
                        }
                    } footer: {
                        Text("New length: \(TimeFormat.string(clip.duration)). Audio keeps its pitch.")
                    }
                    Section("Speed Ramp") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96))], spacing: 10) {
                            ForEach(SpeedRamp.allCases) { ramp in
                                Button {
                                    viewModel.updateVideoClip(clip.id, "Speed Ramp") { $0.speed.ramp = ramp }
                                    Haptics.light()
                                } label: {
                                    VStack(spacing: 6) {
                                        RampCurve(ramp: ramp)
                                            .stroke(clip.speed.ramp == ramp ? Color.accentColor : .secondary, lineWidth: 2)
                                            .frame(height: 30)
                                        Text(ramp.title)
                                            .font(.caption.weight(.medium))
                                    }
                                    .padding(8)
                                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(clip.speed.ramp == ramp ? Color.accentColor : .clear, lineWidth: 2))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                NothingSelectedView()
            }
        }
    }
}

struct RampCurve: Shape {
    let ramp: SpeedRamp

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let samples = 40
        for index in 0...samples {
            let position = Double(index) / Double(samples)
            let value = ramp.multiplier(at: position)
            let normalized = (log(value) - log(0.2)) / (log(4) - log(0.2))
            let point = CGPoint(x: rect.minX + rect.width * position, y: rect.maxY - rect.height * normalized.clamped(0...1))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}

// MARK: - Volume

struct VolumeSheet: View {
    let viewModel: EditorViewModel

    var body: some View {
        SheetContainer(title: "Volume") {
            Form {
                if let clip = viewModel.selectedVideoClip {
                    controls(volume: clip.volume, muted: clip.isMuted, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, duration: clip.duration) { change in
                        viewModel.updateVideoClip(clip.id, "Volume", coalescing: "volume") { item in
                            var values = (item.volume, item.isMuted, item.fadeIn, item.fadeOut)
                            change(&values)
                            (item.volume, item.isMuted, item.fadeIn, item.fadeOut) = values
                        }
                    }
                } else if let clip = viewModel.selectedAudioClip {
                    controls(volume: clip.volume, muted: clip.isMuted, fadeIn: clip.fadeIn, fadeOut: clip.fadeOut, duration: clip.duration) { change in
                        viewModel.updateAudioClip(clip.id, "Volume", coalescing: "volume") { item in
                            var values = (item.volume, item.isMuted, item.fadeIn, item.fadeOut)
                            change(&values)
                            (item.volume, item.isMuted, item.fadeIn, item.fadeOut) = values
                        }
                    }
                } else {
                    NothingSelectedView()
                }
            }
        }
    }

    private func controls(volume: Double, muted: Bool, fadeIn: Double, fadeOut: Double, duration: Double,
                          update: @escaping ((inout (Double, Bool, Double, Double)) -> Void) -> Void) -> some View {
        Group {
            Section {
                Toggle("Mute", isOn: Binding(get: { muted }, set: { value in update { $0.1 = value } }))
                SliderRow(title: "Volume", value: Binding(get: { volume }, set: { value in update { $0.0 = value } }),
                          range: 0...2, format: { "\(Int(($0 * 100).rounded()))%" })
                    .disabled(muted)
            }
            Section("Fades") {
                SliderRow(title: "Fade In", value: Binding(get: { fadeIn }, set: { value in update { $0.2 = value } }),
                          range: 0...max(0.1, min(5, duration / 2)), format: { String(format: "%.1fs", $0) })
                SliderRow(title: "Fade Out", value: Binding(get: { fadeOut }, set: { value in update { $0.3 = value } }),
                          range: 0...max(0.1, min(5, duration / 2)), format: { String(format: "%.1fs", $0) })
            }
        }
    }
}

// MARK: - Crop

struct CropSheet: View {
    let viewModel: EditorViewModel

    var body: some View {
        SheetContainer(title: "Crop & Rotate") {
            if let clip = viewModel.selectedVideoClip {
                let id = clip.id
                let values = viewModel.transformContext(for: .video(id)).map {
                    KeyframeMath.value(base: $0.base, keyframes: $0.keyframes, at: $0.localTime)
                } ?? clip.transform
                Form {
                    Section("Frame") {
                        Picker("Fit", selection: Binding(get: { clip.fit }, set: { value in
                            viewModel.updateVideoClip(id, "Fit") { $0.fit = value }
                        })) {
                            ForEach(FitMode.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        HStack {
                            Button {
                                viewModel.updateVideoClip(id, "Rotate") { $0.crop.quarterTurns = ($0.crop.quarterTurns + 1) % 4 }
                                Haptics.light()
                            } label: {
                                Label("Rotate", systemImage: "rotate.right")
                            }
                            .buttonStyle(.bordered)
                            Spacer()
                            Toggle(isOn: Binding(get: { clip.crop.flipHorizontal }, set: { value in
                                viewModel.updateVideoClip(id, "Flip") { $0.crop.flipHorizontal = value }
                            })) {
                                Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                            }
                            .toggleStyle(.button)
                            Toggle(isOn: Binding(get: { clip.crop.flipVertical }, set: { value in
                                viewModel.updateVideoClip(id, "Flip") { $0.crop.flipVertical = value }
                            })) {
                                Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down")
                            }
                            .toggleStyle(.button)
                        }
                    }
                    Section("Crop") {
                        cropSlider("Left", clip.crop.left) { value in viewModel.updateVideoClip(id, "Crop", coalescing: "crop") { $0.crop.left = value } }
                        cropSlider("Right", clip.crop.right) { value in viewModel.updateVideoClip(id, "Crop", coalescing: "crop") { $0.crop.right = value } }
                        cropSlider("Top", clip.crop.top) { value in viewModel.updateVideoClip(id, "Crop", coalescing: "crop") { $0.crop.top = value } }
                        cropSlider("Bottom", clip.crop.bottom) { value in viewModel.updateVideoClip(id, "Crop", coalescing: "crop") { $0.crop.bottom = value } }
                    }
                    Section {
                        SliderRow(title: "Zoom", value: Binding(get: { values.scale }, set: { value in
                            var updated = values
                            updated.scale = value
                            viewModel.setTransform(updated, for: .video(id))
                        }), range: 0.3...4, format: { String(format: "%.2f×", $0) })
                        SliderRow(title: "Pan Horizontal", value: Binding(get: { values.x }, set: { value in
                            var updated = values
                            updated.x = value
                            viewModel.setTransform(updated, for: .video(id))
                        }), range: -0.8...0.8)
                        SliderRow(title: "Pan Vertical", value: Binding(get: { values.y }, set: { value in
                            var updated = values
                            updated.y = value
                            viewModel.setTransform(updated, for: .video(id))
                        }), range: -0.8...0.8)
                    } header: {
                        Text("Zoom & Pan")
                    } footer: {
                        Text(clip.keyframes.isEmpty ? "Add keyframes in Animate to move the zoom over time." : "This clip is animated, so changes edit the keyframe at the playhead.")
                    }
                    Section {
                        Button("Reset Crop & Zoom", role: .destructive) {
                            viewModel.updateVideoClip(id, "Reset Crop") { $0.crop = CropSettings() }
                            viewModel.resetTransform(for: .video(id))
                        }
                    }
                }
            } else {
                NothingSelectedView()
            }
        }
    }

    private func cropSlider(_ title: String, _ value: Double, update: @escaping (Double) -> Void) -> some View {
        SliderRow(title: title, value: Binding(get: { value }, set: update), range: 0...0.45,
                  format: { "\(Int(($0 * 100).rounded()))%" })
    }
}

// MARK: - Transition

struct TransitionSheet: View {
    let viewModel: EditorViewModel

    var body: some View {
        SheetContainer(title: "Transition") {
            if let id = viewModel.transitionClipID, let clip = viewModel.project.videoClips.first(where: { $0.id == id }) {
                Form {
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 80))], spacing: 12) {
                            ForEach(TransitionKind.allCases) { kind in
                                Button {
                                    var transition = clip.transitionOut
                                    transition.kind = kind
                                    viewModel.setTransition(after: id, transition)
                                    Haptics.light()
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: kind.systemImage)
                                            .font(.title3)
                                            .frame(width: 52, height: 40)
                                            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(clip.transitionOut.kind == kind ? Color.accentColor : .clear, lineWidth: 2))
                                        Text(kind.title)
                                            .font(.caption)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if clip.transitionOut.kind != .cut {
                        Section {
                            SliderRow(title: "Duration", value: Binding(get: { clip.transitionOut.duration }, set: { value in
                                var transition = clip.transitionOut
                                transition.duration = value
                                viewModel.setTransition(after: id, transition)
                            }), range: 0.2...2, format: { String(format: "%.1fs", $0) })
                            Button("Apply to All Cuts") {
                                let transition = clip.transitionOut
                                viewModel.mutate("Transitions") { project in
                                    for index in project.videoClips.indices.dropLast() {
                                        project.videoClips[index].transitionOut = transition
                                    }
                                }
                                Haptics.success()
                            }
                        }
                    }
                }
            } else {
                NothingSelectedView()
            }
        }
    }
}
