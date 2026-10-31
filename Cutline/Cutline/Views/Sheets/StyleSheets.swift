import SwiftUI

// MARK: - Animate (keyframes)

struct AnimateSheet: View {
    let viewModel: EditorViewModel

    var body: some View {
        SheetContainer(title: "Animate") {
            if let target = viewModel.selection, let context = viewModel.transformContext(for: target) {
                let current = KeyframeMath.value(base: context.base, keyframes: context.keyframes, at: context.localTime)
                let inRange = context.localTime >= 0 && context.localTime <= context.duration
                Form {
                    Section {
                        slider("Position X", current.x, -1...1, current, target) { $0.x = $1 }
                        slider("Position Y", current.y, -1...1, current, target) { $0.y = $1 }
                        slider("Scale", current.scale, 0.1...4, current, target, format: { String(format: "%.2f×", $0) }) { $0.scale = $1 }
                        slider("Rotation", current.rotation, -180...180, current, target, format: { "\(Int($0))°" }) { $0.rotation = $1 }
                        slider("Opacity", current.opacity, 0...1, current, target, format: { "\(Int($0 * 100))%" }) { $0.opacity = $1 }
                    } header: {
                        Text(context.keyframes.isEmpty ? "Transform" : "Transform at Playhead")
                    } footer: {
                        Text(context.keyframes.isEmpty
                             ? "Add a keyframe, move the playhead, then change values to animate between them."
                             : "Changes edit the keyframe at the playhead, or add one there.")
                    }
                    Section {
                        Button {
                            viewModel.addKeyframe(for: target)
                        } label: {
                            Label("Add Keyframe at Playhead", systemImage: "plus.diamond")
                        }
                        .disabled(!inRange)
                        if !inRange {
                            Text("Move the playhead inside this item to add keyframes.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if !context.keyframes.isEmpty {
                        Section("Keyframes") {
                            ForEach(context.keyframes.sorted { $0.time < $1.time }) { keyframe in
                                HStack {
                                    Image(systemName: "diamond.fill")
                                        .font(.caption)
                                        .foregroundStyle(abs(keyframe.time - context.localTime) < 1.0 / 30 ? Color.accentColor : .secondary)
                                    Text(TimeFormat.string(keyframe.time))
                                        .font(.subheadline.monospacedDigit())
                                    Spacer()
                                    Menu {
                                        ForEach(Easing.allCases) { easing in
                                            Button(easing.title) {
                                                viewModel.setKeyframeEasing(keyframe.id, easing: easing, for: target)
                                            }
                                        }
                                    } label: {
                                        Text(keyframe.easing.title)
                                            .font(.subheadline)
                                    }
                                    Button(role: .destructive) {
                                        viewModel.removeKeyframe(keyframe.id, for: target)
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if let start = startTime(of: target) {
                                        viewModel.scrub(to: start + keyframe.time)
                                    }
                                }
                            }
                        }
                    }
                    Section {
                        Button("Reset Animation", role: .destructive) {
                            viewModel.resetTransform(for: target)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Select a clip, text or overlay", systemImage: "hand.tap")
            }
        }
    }

    private func startTime(of target: Selection) -> Double? {
        switch target {
        case .video(let id): return viewModel.project.videoClips.first { $0.id == id }?.startTime
        case .text(let id): return viewModel.project.texts.first { $0.id == id }?.startTime
        case .overlay(let id): return viewModel.project.overlays.first { $0.id == id }?.startTime
        default: return nil
        }
    }

    private func slider(_ title: String, _ value: Double, _ range: ClosedRange<Double>, _ current: TransformValues,
                        _ target: Selection, format: @escaping (Double) -> String = { String(format: "%.2f", $0) },
                        apply: @escaping (inout TransformValues, Double) -> Void) -> some View {
        SliderRow(title: title, value: Binding(get: { value }, set: { newValue in
            var updated = current
            apply(&updated, newValue)
            viewModel.setTransform(updated, for: target)
        }), range: range, format: format)
    }
}

// MARK: - Effects and filters

struct EffectsSheet: View {
    let viewModel: EditorViewModel
    let isGlobal: Bool

    private var effects: ClipEffects? {
        isGlobal ? viewModel.project.globalEffects : viewModel.selectedVideoClip?.effects
    }

    private func update(_ change: (inout ClipEffects) -> Void) {
        if isGlobal {
            var value = viewModel.project.globalEffects
            change(&value)
            viewModel.setGlobalEffects(value)
        } else if let clip = viewModel.selectedVideoClip {
            viewModel.updateVideoClip(clip.id, "Effects", coalescing: "effects") { change(&$0.effects) }
        }
    }

    var body: some View {
        SheetContainer(title: isGlobal ? "Filters · Whole Video" : "Effects") {
            if let effects {
                Form {
                    Section("Looks") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(FilterPreset.allCases) { preset in
                                    Button {
                                        update { $0.preset = preset }
                                        Haptics.light()
                                    } label: {
                                        Text(preset.title)
                                            .font(.subheadline.weight(.medium))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(effects.preset == preset ? Color.accentColor : Color(.tertiarySystemFill),
                                                        in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        if effects.preset != .none {
                            SliderRow(title: "Intensity", value: Binding(get: { effects.presetIntensity }, set: { value in update { $0.presetIntensity = value } }),
                                      range: 0...1, format: { "\(Int($0 * 100))%" })
                        }
                    }
                    Section("Adjust") {
                        adjust("Brightness", \.brightness, -0.5...0.5, effects)
                        adjust("Contrast", \.contrast, 0.5...1.5, effects)
                        adjust("Saturation", \.saturation, 0...2, effects)
                        adjust("Warmth", \.warmth, -1...1, effects)
                        adjust("Tint", \.tint, -1...1, effects)
                        adjust("Sharpen", \.sharpen, 0...1, effects)
                        adjust("Vignette", \.vignette, 0...1, effects)
                        adjust("Grain", \.grain, 0...1, effects)
                        adjust("Blur", \.blur, 0...1, effects)
                    }
                    if !isGlobal {
                        Section {
                            Toggle("Green Screen", isOn: Binding(get: { effects.chromaKey.isEnabled }, set: { value in update { $0.chromaKey.isEnabled = value } }))
                            if effects.chromaKey.isEnabled {
                                ColorSwatchPicker(title: "Key Color", selected: effects.chromaKey.color) { color in
                                    update { $0.chromaKey.color = color }
                                }
                                HStack(spacing: 10) {
                                    Button("Green") { update { $0.chromaKey.color = .green } }
                                    Button("Blue") { update { $0.chromaKey.color = RGBAColor(0, 0.3, 1) } }
                                }
                                .buttonStyle(.bordered)
                                SliderRow(title: "Tolerance", value: Binding(get: { effects.chromaKey.tolerance }, set: { value in update { $0.chromaKey.tolerance = value } }),
                                          range: 0.02...0.5)
                                SliderRow(title: "Softness", value: Binding(get: { effects.chromaKey.softness }, set: { value in update { $0.chromaKey.softness = value } }),
                                          range: 0...0.3)
                            }
                        } footer: {
                            Text("Removes a solid background color so the canvas or clips below show through.")
                        }
                        Section {
                            Toggle("Remove Background", isOn: Binding(get: { effects.removeBackground }, set: { value in update { $0.removeBackground = value } }))
                        } footer: {
                            Text("Keeps people and removes everything else using on-device Vision. Playback may be slower while this is on.")
                        }
                        Section {
                            Button("Apply to All Clips") {
                                viewModel.applyEffectsToAllClips(effects)
                                Haptics.success()
                            }
                        }
                    }
                    Section {
                        Button("Reset", role: .destructive) {
                            update { $0 = ClipEffects() }
                        }
                    }
                }
            } else {
                NothingSelectedView()
            }
        }
    }

    private func adjust(_ title: String, _ keyPath: WritableKeyPath<Adjustments, Double>, _ range: ClosedRange<Double>,
                        _ effects: ClipEffects) -> some View {
        SliderRow(title: title, value: Binding(get: { effects.adjustments[keyPath: keyPath] }, set: { value in
            update { $0.adjustments[keyPath: keyPath] = value }
        }), range: range)
    }
}

// MARK: - Text

struct TextSheet: View {
    let viewModel: EditorViewModel

    var body: some View {
        SheetContainer(title: "Text") {
            if let item = viewModel.selectedText {
                let id = item.id
                let style = item.style
                Form {
                    Section {
                        TextField("Type something", text: Binding(get: { item.text }, set: { value in
                            viewModel.updateText(id, "Edit Text", coalescing: "text") { $0.text = value }
                        }), axis: .vertical)
                        .font(.title3)
                        .lineLimit(1...4)
                    }
                    Section("Font") {
                        NavigationLink {
                            FontPickerList(previewText: item.text, selected: style.font, bold: style.isBold) { font in
                                viewModel.updateText(id, "Font") { $0.style.font = font }
                            }
                        } label: {
                            HStack {
                                Text("Font")
                                Spacer()
                                Text(style.font.displayName)
                                    .font(Font(style.font.uiFont(size: 17, bold: style.isBold) as CTFont))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        SliderRow(title: "Size", value: Binding(get: { style.size }, set: { value in
                            viewModel.updateText(id, "Text Size", coalescing: "size") { $0.style.size = value }
                        }), range: 0.02...0.16, format: { "\(Int($0 * 1000))" })
                        Toggle("Bold", isOn: Binding(get: { style.isBold }, set: { value in
                            viewModel.updateText(id, "Bold") { $0.style.isBold = value }
                        }))
                        Picker("Alignment", selection: Binding(get: { style.alignment }, set: { value in
                            viewModel.updateText(id, "Alignment") { $0.style.alignment = value }
                        })) {
                            ForEach(TextAlign.allCases) { Image(systemName: $0.systemImage).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    Section("Style") {
                        ColorSwatchPicker(title: "Color", selected: style.color) { color in
                            viewModel.updateText(id, "Text Color", coalescing: "color") { $0.style.color = color }
                        }
                        Toggle("Outline", isOn: Binding(get: { style.outlineEnabled }, set: { value in
                            viewModel.updateText(id, "Outline") { $0.style.outlineEnabled = value }
                        }))
                        if style.outlineEnabled {
                            ColorSwatchPicker(title: "Outline Color", selected: style.outlineColor) { color in
                                viewModel.updateText(id, "Outline Color", coalescing: "outline") { $0.style.outlineColor = color }
                            }
                        }
                        Toggle("Shadow", isOn: Binding(get: { style.shadowEnabled }, set: { value in
                            viewModel.updateText(id, "Shadow") { $0.style.shadowEnabled = value }
                        }))
                        Toggle("Background Box", isOn: Binding(get: { style.backgroundEnabled }, set: { value in
                            viewModel.updateText(id, "Background") { $0.style.backgroundEnabled = value }
                        }))
                        if style.backgroundEnabled {
                            ColorSwatchPicker(title: "Box Color", selected: style.backgroundColor) { color in
                                viewModel.updateText(id, "Box Color", coalescing: "box") { $0.style.backgroundColor = color }
                            }
                        }
                    }
                    Section("Animation") {
                        Picker("In", selection: Binding(get: { item.inAnimation }, set: { value in
                            viewModel.updateText(id, "Animation") { $0.inAnimation = value }
                        })) {
                            ForEach(TextAnimation.allCases) { Text($0.title).tag($0) }
                        }
                        Picker("Out", selection: Binding(get: { item.outAnimation }, set: { value in
                            viewModel.updateText(id, "Animation") { $0.outAnimation = value }
                        })) {
                            ForEach(TextAnimation.allCases.filter { $0 != .typewriter }) { Text($0.title).tag($0) }
                        }
                        SliderRow(title: "Duration", value: Binding(get: { item.duration }, set: { value in
                            viewModel.updateText(id, "Duration", coalescing: "duration") { $0.duration = value }
                        }), range: 0.5...max(20, item.duration), format: { String(format: "%.1fs", $0) })
                    }
                }
            } else {
                NothingSelectedView()
            }
        }
    }
}
