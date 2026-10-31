import SwiftUI
import UIKit

/// A horizontal row of color swatches with an optional "none", an optional
/// theme-adaptive "auto" color and a custom color picker.
struct ColorSwatchRow: View {
    let selected: PaintColor?
    let theme: Theme
    var allowsClear = false
    var allowsAuto = true
    let onSelect: (PaintColor) -> Void

    @ScaledMetric(relativeTo: .body) private var swatchSize: CGFloat = 28

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if allowsClear {
                    swatchButton(.clear, label: "No color") {
                        ZStack {
                            Circle().fill(Color.primary.opacity(0.06))
                            Rectangle()
                                .fill(Color.red)
                                .frame(width: 2, height: swatchSize * 0.9)
                                .rotationEffect(.degrees(45))
                        }
                    }
                }
                if allowsAuto {
                    swatchButton(.themeForeground, label: "Theme default") {
                        ZStack {
                            Circle().fill(theme.background.color)
                            Circle()
                                .trim(from: 0, to: 0.5)
                                .fill(theme.foreground.color)
                                .rotationEffect(.degrees(-45))
                            Text("A")
                                .font(.system(size: swatchSize * 0.38, weight: .bold, design: .rounded))
                                .foregroundStyle(theme.isDark ? Color.black : Color.white)
                                .offset(x: -swatchSize * 0.12, y: -swatchSize * 0.12)
                        }
                    }
                }
                ForEach(Palette.colors, id: \.self) { rgba in
                    swatchButton(.custom(rgba), label: "Color") {
                        Circle().fill(rgba.color)
                    }
                }
                ColorPicker("Custom color", selection: customColorBinding, supportsOpacity: true)
                    .labelsHidden()
                    .frame(width: swatchSize, height: swatchSize)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 2)
        }
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: {
                if let resolved = selected?.uiColor(in: theme) {
                    return Color(uiColor: resolved)
                }
                return theme.foreground.color
            },
            set: { newValue in
                onSelect(.custom(RGBA(uiColor: UIColor(newValue))))
            }
        )
    }

    private func swatchButton<Content: View>(_ color: PaintColor,
                                             label: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        let isSelected = selected == color
        return Button {
            onSelect(color)
        } label: {
            content()
                .frame(width: swatchSize, height: swatchSize)
                .clipShape(Circle())
                .overlay(
                    Circle().strokeBorder(Color.primary.opacity(0.18), lineWidth: 1)
                )
                .padding(3)
                .overlay(
                    Circle().strokeBorder(isSelected ? theme.accent.color : Color.clear, lineWidth: 2.5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Sticky note palette from the current theme.
struct StickyPaletteRow: View {
    let theme: Theme
    let selectedIndex: Int?
    let onSelect: (Int) -> Void

    @ScaledMetric(relativeTo: .body) private var swatchSize: CGFloat = 30

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(theme.stickyPalette.enumerated()), id: \.offset) { index, rgba in
                Button {
                    onSelect(index)
                } label: {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(rgba.color)
                        .frame(width: swatchSize, height: swatchSize)
                        .padding(3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(selectedIndex == index ? theme.accent.color : Color.clear, lineWidth: 2.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sticky color \(index + 1)")
                .accessibilityAddTraits(selectedIndex == index ? .isSelected : [])
            }
        }
    }
}
