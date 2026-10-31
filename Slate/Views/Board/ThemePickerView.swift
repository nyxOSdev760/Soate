import SwiftUI

/// Picks the board's theme and background pattern. Changes apply live.
struct ThemePickerView: View {
    @Bindable var viewModel: BoardViewModel
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Theme")
                        .font(.headline)
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(ThemeManager.shared.themes) { theme in
                            Button {
                                viewModel.setTheme(theme.id)
                            } label: {
                                ThemeSwatch(theme: theme,
                                            pattern: viewModel.pattern,
                                            isSelected: viewModel.themeID == theme.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(theme.name)
                            .accessibilityAddTraits(viewModel.themeID == theme.id ? .isSelected : [])
                        }
                    }

                    Text("Background")
                        .font(.headline)
                    Picker("Background", selection: Binding(get: { viewModel.pattern }, set: { viewModel.setPattern($0) })) {
                        ForEach(BackgroundPattern.allCases) { pattern in
                            Text(pattern.title).tag(pattern)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Strokes, text and sticky notes that use the theme's default colors adapt automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ThemeSwatch: View {
    let theme: Theme
    let pattern: BackgroundPattern
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.background.color)
                PatternPreview(pattern: pattern, color: theme.patternColor.color)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                ScribblePreview()
                    .stroke(theme.foreground.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .padding(14)
                HStack(spacing: 4) {
                    ForEach(Array(theme.stickyPalette.prefix(3).enumerated()), id: \.offset) { _, color in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color.color)
                            .frame(width: 12, height: 12)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(8)
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? theme.accent.color : Color.primary.opacity(0.15),
                                  lineWidth: isSelected ? 3 : 1)
            )
            Text(theme.name)
                .font(.caption)
                .fontWeight(isSelected ? .semibold : .regular)
        }
    }
}

struct ScribblePreview: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.15))
        path.addCurve(to: CGPoint(x: rect.midX, y: rect.midY - rect.height * 0.1),
                      control1: CGPoint(x: rect.minX + rect.width * 0.2, y: rect.minY),
                      control2: CGPoint(x: rect.minX + rect.width * 0.35, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.2),
                      control1: CGPoint(x: rect.midX + rect.width * 0.15, y: rect.minY - rect.height * 0.2),
                      control2: CGPoint(x: rect.maxX - rect.width * 0.2, y: rect.maxY))
        return path
    }
}

struct PatternPreview: View {
    let pattern: BackgroundPattern
    let color: Color

    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 10
            switch pattern {
            case .none:
                break
            case .dots:
                var y: CGFloat = spacing / 2
                while y < size.height {
                    var x: CGFloat = spacing / 2
                    while x < size.width {
                        context.fill(Path(ellipseIn: CGRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)), with: .color(color))
                        x += spacing
                    }
                    y += spacing
                }
            case .grid:
                var path = Path()
                var x: CGFloat = 0
                while x < size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += spacing
                }
                var y: CGFloat = 0
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            case .lines:
                var path = Path()
                var y: CGFloat = spacing
                while y < size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += spacing
                }
                context.stroke(path, with: .color(color), lineWidth: 0.5)
            }
        }
        .allowsHitTesting(false)
    }
}
