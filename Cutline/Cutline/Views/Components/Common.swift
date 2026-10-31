import SwiftUI
import UIKit

/// Large icon + label button used by the context toolbar.
struct ToolButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .primary
    var isOn = false
    let action: () -> Void

    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 22

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: iconSize, weight: .medium))
                    .frame(width: 44, height: 32)
                    .foregroundStyle(isOn ? Color.accentColor : tint)
                Text(title)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isOn ? Color.accentColor : Color.primary)
            }
            .frame(minWidth: 64, minHeight: 60)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.subheadline)
                Spacer()
                Text(format(value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .accessibilityLabel(title)
        }
    }
}

struct ColorSwatchPicker: View {
    let title: String
    let selected: RGBAColor
    let onSelect: (RGBAColor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(RGBAColor.palette, id: \.self) { color in
                        Button {
                            onSelect(color)
                        } label: {
                            Circle()
                                .fill(color.color)
                                .frame(width: 30, height: 30)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                                .padding(3)
                                .overlay(Circle().strokeBorder(isClose(color) ? Color.accentColor : .clear, lineWidth: 2.5))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Color")
                    }
                    ColorPicker("Custom", selection: Binding(get: { selected.color },
                                                             set: { onSelect(RGBAColor(uiColor: UIColor($0))) }),
                                supportsOpacity: true)
                        .labelsHidden()
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func isClose(_ color: RGBAColor) -> Bool {
        abs(color.r - selected.r) + abs(color.g - selected.g) + abs(color.b - selected.b) < 0.02
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// Blocking progress HUD for long operations, with cancel.
struct BusyOverlay: View {
    let state: BusyState
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea()
            VStack(spacing: 14) {
                if let progress = state.progress {
                    ProgressView(value: progress)
                        .frame(width: 200)
                    Text("\(Int(progress * 100))%")
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(state.title)
                    .font(.headline)
                Button("Cancel", role: .cancel, action: onCancel)
                    .buttonStyle(.bordered)
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .accessibilityElement(children: .contain)
    }
}

/// A picker of system fonts with a live preview of the text in each font.
struct FontPickerList: View {
    let previewText: String
    let selected: FontChoice
    let bold: Bool
    let onSelect: (FontChoice) -> Void

    var body: some View {
        List(FontChoice.allCases) { font in
            Button {
                onSelect(font)
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(previewText.isEmpty ? "Aa Bb Cc" : previewText)
                            .font(Font(font.uiFont(size: UIFontMetrics(forTextStyle: .body).scaledValue(for: 22), bold: bold) as CTFont))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Text(font.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if font == selected {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct SheetContainer<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .fontWeight(.semibold)
                    }
                }
        }
    }
}
