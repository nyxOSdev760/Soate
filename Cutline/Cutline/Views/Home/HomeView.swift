import PhotosUI
import SwiftUI

/// Projects grid with search, quick-start templates and long-press actions.
struct HomeView: View {
    @State private var model = HomeViewModel()
    @State private var path: [UUID] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var pendingAspect: AspectRatio = .vertical
    @State private var renameTarget: ProjectSummary?
    @State private var renameText = ""
    @State private var deleteTarget: ProjectSummary?

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 14)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    templates
                    if model.filteredProjects.isEmpty {
                        emptyState
                    } else {
                        Text("Projects")
                            .font(.title3.weight(.semibold))
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(model.filteredProjects) { summary in
                                Button {
                                    path.append(summary.id)
                                } label: {
                                    ProjectCard(summary: summary)
                                }
                                .buttonStyle(.plain)
                                .contextMenu { contextMenu(for: summary) }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("Cutline")
            .searchable(text: $model.searchText, prompt: "Search projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        pendingAspect = .vertical
                        showPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.headline)
                    }
                    .accessibilityLabel("New Project")
                }
            }
            .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 30,
                          matching: .any(of: [.videos, .images]), preferredItemEncoding: .current)
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                if let id = model.createProject(aspect: pendingAspect, items: items) {
                    path.append(id)
                }
                pickerItems = []
            }
            .navigationDestination(for: UUID.self) { id in
                EditorScreen(projectID: id, home: model)
            }
            .onAppear { model.reload() }
            .onReceive(NotificationCenter.default.publisher(for: .cutlineProjectsDidChange)) { _ in
                model.reload()
            }
            .alert("Rename Project", isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) { renameTarget = nil }
                Button("Rename") {
                    if let target = renameTarget { model.rename(target.id, to: renameText) }
                    renameTarget = nil
                }
            }
            .confirmationDialog("Delete this project?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
                                titleVisibility: .visible, presenting: deleteTarget) { summary in
                Button("Delete \u{201C}\(summary.name)\u{201D}", role: .destructive) {
                    model.delete(summary.id)
                    deleteTarget = nil
                }
            } message: { _ in
                Text("The project and its imported media will be removed from this iPhone.")
            }
            .alert(item: $model.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
            }
        }
    }

    private var templates: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start New")
                .font(.title3.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    templateCard(.vertical, title: "TikTok · Reels · Shorts", icon: "iphone")
                    templateCard(.square, title: "Square", icon: "square")
                    templateCard(.portrait, title: "Instagram 4:5", icon: "rectangle.portrait")
                    templateCard(.widescreen, title: "YouTube", icon: "play.rectangle")
                }
            }
        }
    }

    private func templateCard(_ aspect: AspectRatio, title: String, icon: String) -> some View {
        Button {
            pendingAspect = aspect
            showPicker = true
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .aspectRatio(aspect.ratio, contentMode: .fit)
                        .frame(height: 44)
                    Image(systemName: icon)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .frame(height: 48)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(aspect.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(width: 170, alignment: .leading)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New \(title) project")
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(model.searchText.isEmpty ? "No projects yet" : "No matching projects")
                .font(.headline)
            if model.searchText.isEmpty {
                Text("Tap a format above or + to pick your clips. Cutline lays them out for you.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    @ViewBuilder
    private func contextMenu(for summary: ProjectSummary) -> some View {
        Button {
            renameText = summary.name
            renameTarget = summary
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            model.duplicate(summary.id)
        } label: {
            Label("Duplicate", systemImage: "plus.square.on.square")
        }
        Button(role: .destructive) {
            deleteTarget = summary
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }
}

struct ProjectCard: View {
    let summary: ProjectSummary
    @State private var thumbnail: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color(.secondarySystemBackground)
                .aspectRatio(3.0 / 4.0, contentMode: .fit)
                .overlay {
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Image(systemName: "film")
                            .font(.title)
                            .foregroundStyle(.tertiary)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    Text(TimeFormat.string(summary.duration, showFraction: false))
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(summary.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("\(summary.aspect.title) · \(summary.updatedAt.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(Rectangle())
        .task(id: summary.updatedAt) {
            thumbnail = UIImage(contentsOfFile: ProjectStore.shared.thumbnailURL(for: summary.id).path)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the project. Touch and hold for more options.")
    }
}
