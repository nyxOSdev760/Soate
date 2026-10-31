import SwiftUI
import UIKit

/// Multi-track timeline with a fixed center playhead. Drag to scrub, pinch
/// to zoom, tap to select, drag handles to trim, long-press and drag to
/// move or reorder, double-tap to split at the playhead.
struct TimelineView: View {
    @Bindable var viewModel: EditorViewModel
    @State private var scrubStart: Double?
    @State private var zoomStart: Double?
    @State private var drag: ItemDrag?

    struct ItemDrag: Equatable {
        let selection: Selection
        var delta: Double
    }

    static let videoLaneHeight: CGFloat = 58
    static let laneHeight: CGFloat = 32
    static let audioLaneHeight: CGFloat = 40

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let pps = viewModel.pixelsPerSecond
            let origin = width / 2 - viewModel.playhead * pps
            ZStack(alignment: .top) {
                Color(white: 0.06)
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 6) {
                        RulerView(origin: origin, pixelsPerSecond: pps, duration: viewModel.duration)
                            .frame(height: 18)
                        videoLane(origin: origin, pps: pps, width: width)
                        if !viewModel.project.overlays.isEmpty {
                            itemLane(viewModel.project.overlays.map { LaneItem(id: $0.id, start: $0.startTime, duration: $0.duration, title: $0.title, selection: .overlay($0.id), keyframes: $0.keyframes) },
                                     color: .orange, icon: "sparkles", origin: origin, pps: pps, width: width)
                        }
                        textLane(origin: origin, pps: pps, width: width)
                        if !viewModel.project.captions.lines.isEmpty {
                            itemLane(viewModel.project.captions.lines.map { LaneItem(id: $0.id, start: $0.start, duration: $0.end - $0.start, title: $0.text, selection: .caption($0.id), keyframes: []) },
                                     color: .teal, icon: "captions.bubble", origin: origin, pps: pps, width: width)
                        }
                        audioLanes(origin: origin, pps: pps, width: width)
                    }
                    .padding(.vertical, 6)
                }
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2)
                    .shadow(color: .black.opacity(0.6), radius: 2)
                    .allowsHitTesting(false)
                Triangle()
                    .fill(Color.white)
                    .frame(width: 12, height: 8)
                    .allowsHitTesting(false)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                viewModel.select(nil)
            }
            .simultaneousGesture(scrubGesture(pps: pps))
            .simultaneousGesture(zoomGesture)
        }
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
    }

    // MARK: Gestures

    private func scrubGesture(pps: Double) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if viewModel.isDraggingItem || drag != nil {
                    if let start = scrubStart {
                        viewModel.scrub(to: start)
                        scrubStart = nil
                    }
                    return
                }
                if scrubStart == nil {
                    scrubStart = viewModel.playhead
                }
                if let start = scrubStart {
                    viewModel.scrub(to: start - value.translation.width / pps)
                }
            }
            .onEnded { _ in
                if scrubStart != nil {
                    viewModel.endScrub()
                }
                scrubStart = nil
            }
    }

    private var zoomGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if zoomStart == nil {
                    zoomStart = viewModel.pixelsPerSecond
                }
                viewModel.setZoom((zoomStart ?? viewModel.pixelsPerSecond) * value.magnification)
            }
            .onEnded { _ in
                zoomStart = nil
                viewModel.endZoom()
            }
    }

    // MARK: Lanes

    private func isVisible(x: Double, width itemWidth: Double, laneWidth: Double) -> Bool {
        x + itemWidth > -40 && x < laneWidth + 40
    }

    private func videoLane(origin: Double, pps: Double, width: Double) -> some View {
        let clips = viewModel.project.videoClips
        return ZStack(alignment: .topLeading) {
            ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                let selection = Selection.video(clip.id)
                let isSelected = viewModel.selection == selection
                let moveOffset = drag?.selection == selection ? (drag?.delta ?? 0) * pps : 0
                let x = origin + clip.startTime * pps + moveOffset
                let clipWidth = max(clip.duration * pps, 4)
                if isVisible(x: x, width: clipWidth, laneWidth: width) {
                    VideoClipBlock(clip: clip, media: viewModel.media(for: clip.mediaID), viewModel: viewModel,
                                   isSelected: isSelected, width: clipWidth, visibleFrom: -x, visibleTo: width - x)
                        .frame(width: clipWidth, height: TimelineView.videoLaneHeight)
                        .overlay { if isSelected { trimHandles(selection, pps: pps) } }
                        .scaleEffect(moveOffset != 0 ? 1.04 : 1)
                        .shadow(color: .black.opacity(moveOffset != 0 ? 0.5 : 0), radius: 8)
                        .zIndex(moveOffset != 0 || isSelected ? 1 : 0)
                        .offset(x: x)
                        .modifier(ItemInteraction(selection: selection, viewModel: viewModel, drag: $drag, pps: pps, isMainTrack: true))
                }
                if index + 1 < clips.count, abs(clips[index + 1].startTime - clip.endTime) < 0.01 {
                    let boundary = origin + clip.endTime * pps
                    if boundary > -20 && boundary < width + 20 {
                        Button {
                            viewModel.transitionClipID = clip.id
                            viewModel.activeSheet = .transition
                        } label: {
                            Image(systemName: clip.transitionOut.kind == .cut ? "plus" : clip.transitionOut.kind.systemImage)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.black)
                                .frame(width: 22, height: 22)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                        .offset(x: boundary - 11, y: TimelineView.videoLaneHeight / 2 - 11)
                        .zIndex(2)
                        .accessibilityLabel("Transition")
                    }
                }
            }
            if clips.isEmpty {
                Button {
                    viewModel.showMediaPicker = true
                } label: {
                    Label("Add clips", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: 160, height: TimelineView.videoLaneHeight)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .offset(x: origin)
            }
        }
        .frame(width: width, height: TimelineView.videoLaneHeight, alignment: .topLeading)
    }

    private func textLane(origin: Double, pps: Double, width: Double) -> some View {
        Group {
            if viewModel.project.texts.isEmpty {
                placeholderLane("Add text", icon: "textformat", origin: origin, width: width) {
                    viewModel.addText()
                }
            } else {
                itemLane(viewModel.project.texts.map { LaneItem(id: $0.id, start: $0.startTime, duration: $0.duration, title: $0.text, selection: .text($0.id), keyframes: $0.keyframes) },
                         color: .purple, icon: "textformat", origin: origin, pps: pps, width: width)
            }
        }
    }

    struct LaneItem: Identifiable {
        let id: UUID
        let start: Double
        let duration: Double
        let title: String
        let selection: Selection
        let keyframes: [Keyframe]
    }

    private func itemLane(_ items: [LaneItem], color: Color, icon: String,
                          origin: Double, pps: Double, width: Double) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(items) { item in
                let start = item.start
                let duration = item.duration
                let title = item.title
                let selection = item.selection
                let keyframes = item.keyframes
                let isSelected = viewModel.selection == selection
                let x = origin + start * pps
                let itemWidth = max(duration * pps, 4)
                if isVisible(x: x, width: itemWidth, laneWidth: width) {
                    HStack(spacing: 4) {
                        Image(systemName: icon)
                            .font(.caption2)
                        Text(title)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .frame(width: itemWidth, height: TimelineView.laneHeight)
                    .background(color.opacity(isSelected ? 0.9 : 0.6), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .bottomLeading) {
                        KeyframeMarkers(keyframes: keyframes, pps: pps)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.yellow : .clear, lineWidth: 2)
                    }
                    .overlay { if isSelected { trimHandles(selection, pps: pps) } }
                    .zIndex(isSelected ? 1 : 0)
                    .offset(x: x)
                    .modifier(ItemInteraction(selection: selection, viewModel: viewModel, drag: $drag, pps: pps, isMainTrack: false))
                }
            }
        }
        .frame(width: width, height: TimelineView.laneHeight, alignment: .topLeading)
    }

    private func audioLanes(origin: Double, pps: Double, width: Double) -> some View {
        let lanes = TimelineView.packLanes(viewModel.project.audioClips)
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, lane in
                ZStack(alignment: .topLeading) {
                    ForEach(lane) { clip in
                        let selection = Selection.audio(clip.id)
                        let isSelected = viewModel.selection == selection
                        let x = origin + clip.startTime * pps
                        let clipWidth = max(clip.duration * pps, 4)
                        if isVisible(x: x, width: clipWidth, laneWidth: width) {
                            AudioClipBlock(clip: clip, media: viewModel.media(for: clip.mediaID), viewModel: viewModel,
                                           isSelected: isSelected, pps: pps, visibleFrom: -x, visibleTo: width - x)
                                .frame(width: clipWidth, height: TimelineView.audioLaneHeight)
                                .overlay { if isSelected { trimHandles(selection, pps: pps) } }
                                .zIndex(isSelected ? 1 : 0)
                                .offset(x: x)
                                .modifier(ItemInteraction(selection: selection, viewModel: viewModel, drag: $drag, pps: pps, isMainTrack: false))
                        }
                    }
                }
                .frame(width: width, height: TimelineView.audioLaneHeight, alignment: .topLeading)
            }
            placeholderLane("Add music or voiceover", icon: "music.note", origin: origin, width: width) {
                viewModel.activeSheet = .audio
            }
        }
    }

    private func placeholderLane(_ title: String, icon: String, origin: Double, width: Double, action: @escaping () -> Void) -> some View {
        ZStack(alignment: .topLeading) {
            Button(action: action) {
                Label(title, systemImage: icon)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    )
            }
            .buttonStyle(.plain)
            .offset(x: max(origin, 8))
        }
        .frame(width: width, height: 28, alignment: .topLeading)
    }

    /// Two trim handles on the selected item.
    private func trimHandles(_ selection: Selection, pps: Double) -> some View {
        HStack(spacing: 0) {
            TrimHandle(edge: .leading, selection: selection, viewModel: viewModel, pps: pps)
            Spacer(minLength: 0)
            TrimHandle(edge: .trailing, selection: selection, viewModel: viewModel, pps: pps)
        }
    }

    /// Greedy lane packing for audio clips that overlap in time.
    static func packLanes(_ clips: [AudioClip]) -> [[AudioClip]] {
        var lanes: [[AudioClip]] = []
        for clip in clips.sorted(by: { $0.startTime < $1.startTime }) {
            if let index = lanes.firstIndex(where: { ($0.last?.endTime ?? 0) <= clip.startTime + 0.001 }) {
                lanes[index].append(clip)
            } else {
                lanes.append([clip])
            }
        }
        return lanes
    }
}

// MARK: - Item interaction

/// Tap to select, double-tap to split at the playhead, long-press then drag
/// to move (or reorder on the main track).
struct ItemInteraction: ViewModifier {
    let selection: Selection
    let viewModel: EditorViewModel
    @Binding var drag: TimelineView.ItemDrag?
    let pps: Double
    let isMainTrack: Bool

    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) {
                viewModel.select(selection)
                if case .caption = selection { return }
                viewModel.splitAtPlayhead()
            }
            .onTapGesture {
                viewModel.select(viewModel.selection == selection ? nil : selection)
            }
            .gesture(
                LongPressGesture(minimumDuration: 0.3)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                    .onChanged { value in
                        guard case .second(true, let dragValue) = value else { return }
                        if drag == nil {
                            viewModel.beginItemGesture(selection)
                            drag = TimelineView.ItemDrag(selection: selection, delta: 0)
                            Haptics.medium()
                        }
                        let delta = (dragValue?.translation.width ?? 0) / pps
                        drag?.delta = delta
                        if !isMainTrack {
                            viewModel.move(selection, delta: delta)
                        }
                    }
                    .onEnded { value in
                        if case .second(true, let dragValue) = value, isMainTrack, case .video(let id) = selection {
                            viewModel.finishMainClipMove(id, delta: (dragValue?.translation.width ?? 0) / pps)
                        }
                        viewModel.endItemGesture()
                        drag = nil
                    }
            )
    }
}

struct TrimHandle: View {
    let edge: TrimEdge
    let selection: Selection
    let viewModel: EditorViewModel
    let pps: Double
    @State private var isDragging = false

    var body: some View {
        RoundedRectangle(cornerRadius: 4)
            .fill(Color.yellow)
            .frame(width: 14)
            .overlay(
                Image(systemName: edge == .leading ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundStyle(.black)
            )
            .frame(width: 30)
            .contentShape(Rectangle())
            .offset(x: edge == .leading ? -8 : 8)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            viewModel.beginItemGesture(selection)
                        }
                        viewModel.trim(selection, edge: edge, delta: value.translation.width / pps)
                    }
                    .onEnded { _ in
                        isDragging = false
                        viewModel.endItemGesture()
                    }
            )
            .accessibilityLabel(edge == .leading ? "Trim start" : "Trim end")
    }
}

// MARK: - Blocks

struct VideoClipBlock: View {
    let clip: VideoClip
    let media: MediaAsset?
    let viewModel: EditorViewModel
    let isSelected: Bool
    let width: Double
    let visibleFrom: Double
    let visibleTo: Double

    private static let tileWidth: Double = 44

    var body: some View {
        let tiles = Int(ceil(width / VideoClipBlock.tileWidth))
        let first = max(0, Int(floor(visibleFrom / VideoClipBlock.tileWidth)))
        let last = min(tiles - 1, Int(ceil(visibleTo / VideoClipBlock.tileWidth)))
        ZStack(alignment: .topLeading) {
            Color(white: 0.18)
            if let media, first <= last {
                ForEach(first...last, id: \.self) { index in
                    let localX = (Double(index) + 0.5) * VideoClipBlock.tileWidth
                    let time = clip.sourceTime(atTimeline: clip.startTime + localX / max(width, 1) * clip.duration)
                    ThumbnailTile(url: viewModel.mediaURL(media, preferProxy: true), time: time, isImage: clip.isImage)
                        .frame(width: VideoClipBlock.tileWidth, height: TimelineView.videoLaneHeight)
                        .clipped()
                        .offset(x: Double(index) * VideoClipBlock.tileWidth)
                }
            }
            HStack(spacing: 4) {
                if !clip.speed.isNormal {
                    badge(clip.speed.ramp == .none ? String(format: "%.1f×", clip.speed.rate) : clip.speed.ramp.title, icon: "speedometer")
                }
                if clip.isMuted { badge(nil, icon: "speaker.slash.fill") }
                if clip.isReversed { badge(nil, icon: "backward.fill") }
                if clip.stabilization != nil { badge(nil, icon: "camera.metering.center.weighted") }
                if !clip.effects.isNeutral { badge(nil, icon: "camera.filters") }
            }
            .padding(4)
            if media == nil {
                Label("Missing", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .padding(6)
            }
        }
        .overlay(alignment: .bottomLeading) {
            KeyframeMarkers(keyframes: clip.keyframes, pps: viewModel.pixelsPerSecond)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.yellow : Color.white.opacity(0.15), lineWidth: isSelected ? 2.5 : 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clip.isImage ? "Photo" : "Video") clip, \(TimeFormat.string(clip.duration))")
    }

    private func badge(_ text: String?, icon: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: icon)
            if let text { Text(text) }
        }
        .font(.system(size: 9, weight: .bold))
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(.black.opacity(0.6), in: Capsule())
    }
}

struct ThumbnailTile: View {
    let url: URL
    let time: Double
    let isImage: Bool
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: "\(url.lastPathComponent)|\((time * 4).rounded())") {
            if isImage {
                image = await ThumbnailCache.shared.image(url: url)
            } else {
                image = await ThumbnailCache.shared.thumbnail(url: url, time: time)
            }
        }
    }
}

struct AudioClipBlock: View {
    let clip: AudioClip
    let media: MediaAsset?
    let viewModel: EditorViewModel
    let isSelected: Bool
    let pps: Double
    let visibleFrom: Double
    let visibleTo: Double
    @State private var envelope: [Float] = []

    private var color: Color {
        switch clip.role {
        case .music: return .green
        case .voiceover: return .red
        case .extracted: return .blue
        }
    }

    var body: some View {
        let clipStart = clip.startTime
        let trimStart = clip.trimStart
        let beats = clip.timelineBeats
        ZStack(alignment: .topLeading) {
            color.opacity(clip.isMuted ? 0.2 : 0.35)
            Canvas { context, size in
                guard !envelope.isEmpty else { return }
                let from = max(0, visibleFrom)
                let to = min(Double(size.width), visibleTo)
                guard to > from else { return }
                var path = Path()
                var x = from
                while x < to {
                    let sourceTime = trimStart + x / pps
                    let index = Int(sourceTime * Double(WaveformGenerator.samplesPerSecond))
                    let amplitude = index >= 0 && index < envelope.count ? CGFloat(envelope[index]) : 0
                    let barHeight: CGFloat = max(1, amplitude * size.height * 0.85)
                    let barY: CGFloat = (size.height - barHeight) / 2
                    path.addRect(CGRect(x: CGFloat(x), y: barY, width: 1.5, height: barHeight))
                    x += 3
                }
                context.fill(path, with: .color(color.opacity(0.9)))
                for beat in beats {
                    let bx = (beat - clipStart) * pps
                    guard bx >= from, bx <= to else { continue }
                    context.fill(Path(CGRect(x: bx - 0.75, y: 0, width: 1.5, height: 6)), with: .color(.yellow))
                }
            }
            HStack(spacing: 4) {
                Image(systemName: clip.role.systemImage)
                Text(media?.displayName ?? clip.role.title)
                    .lineLimit(1)
                if clip.isMuted { Image(systemName: "speaker.slash.fill") }
            }
            .font(.system(size: 10, weight: .semibold))
            .padding(4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(isSelected ? Color.yellow : Color.white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1))
        .task(id: media?.fileName) {
            guard let media else { return }
            envelope = await WaveformGenerator.shared.envelope(url: viewModel.mediaURL(media))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(clip.role.title), \(TimeFormat.string(clip.duration))")
    }
}

struct KeyframeMarkers: View {
    let keyframes: [Keyframe]
    let pps: Double

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(keyframes) { keyframe in
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 7, height: 7)
                    .rotationEffect(.degrees(45))
                    .offset(x: keyframe.time * pps - 3.5, y: -3)
            }
        }
        .allowsHitTesting(false)
    }
}

struct RulerView: View {
    let origin: Double
    let pixelsPerSecond: Double
    let duration: Double

    var body: some View {
        Canvas { context, size in
            let steps: [Double] = [0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
            let step = steps.first { $0 * pixelsPerSecond >= 70 } ?? 600
            let firstTime = max(0, floor(-origin / pixelsPerSecond / step) * step)
            var t = firstTime
            while true {
                let x = origin + t * pixelsPerSecond
                if x > size.width { break }
                if x >= -40 {
                    context.fill(Path(CGRect(x: x, y: size.height - 6, width: 1, height: 6)), with: .color(.white.opacity(0.4)))
                    let label = Text(TimeFormat.string(t, showFraction: step < 1))
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundColor(.white.opacity(0.5))
                    context.draw(label, at: CGPoint(x: x + 3, y: 6), anchor: .leading)
                    let half = x + step * pixelsPerSecond / 2
                    context.fill(Path(CGRect(x: half, y: size.height - 3, width: 1, height: 3)), with: .color(.white.opacity(0.25)))
                }
                t += step
            }
        }
        .allowsHitTesting(false)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
