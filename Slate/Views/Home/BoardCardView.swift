import SwiftUI
import UIKit

/// A board thumbnail with its name and last edit time.
struct BoardCardView: View {
    let header: BoardHeader

    @State private var thumbnail: UIImage?

    private var theme: Theme {
        ThemeManager.shared.theme(for: header.themeID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            theme.background.color
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "scribble.variable")
                            .font(.largeTitle)
                            .foregroundStyle(theme.foreground.color.opacity(0.25))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.3), radius: 6, y: 3)

            VStack(alignment: .leading, spacing: 2) {
                Text(header.name)
                    .font(.headline)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                Text(header.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the board. Touch and hold for more options.")
        .task(id: header.updatedAt) {
            let url = BoardStore.shared.thumbnailURL(for: header.id)
            thumbnail = UIImage(contentsOfFile: url.path)
        }
    }
}
