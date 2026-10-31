import UIKit

/// Saves after every edit, debounced so a burst of edits causes one write at
/// most `debounceInterval` after the last edit (and never later than
/// `maximumDelay` after the first). Flushes synchronously when the app
/// goes to the background.
@MainActor
final class AutosaveService: NSObject {
    static let debounceInterval: TimeInterval = 0.5
    static let maximumDelay: TimeInterval = 0.9

    var snapshotProvider: (() -> Project?)?
    var thumbnailProvider: ((Project) async -> Data?)?
    var onResult: ((Result<Void, Error>) -> Void)?

    private let store: ProjectStore
    private let ioQueue = DispatchQueue(label: "com.cutline.autosave", qos: .utility)
    private var pendingTask: Task<Void, Never>?
    private var firstUnsavedChange: Date?
    private var thumbnailTask: Task<Void, Never>?
    private(set) var isDirty = false

    init(store: ProjectStore) {
        self.store = store
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(flushNow),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(flushNow),
                                               name: UIApplication.willTerminateNotification, object: nil)
    }

    func scheduleSave() {
        isDirty = true
        let now = Date()
        if let first = firstUnsavedChange, now.timeIntervalSince(first) >= AutosaveService.maximumDelay {
            flush(synchronously: false)
            return
        }
        if firstUnsavedChange == nil {
            firstUnsavedChange = now
        }
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AutosaveService.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush(synchronously: false)
        }
    }

    @objc private func flushNow() {
        flush(synchronously: true)
    }

    func flush(synchronously: Bool) {
        pendingTask?.cancel()
        pendingTask = nil
        guard isDirty, var project = snapshotProvider?() else { return }
        isDirty = false
        firstUnsavedChange = nil
        project.updatedAt = Date()
        let store = self.store
        let data: Data
        do {
            data = try store.encode(project)
        } catch {
            isDirty = true
            onResult?(.failure(error))
            return
        }
        let projectID = project.id
        let work: () -> Result<Void, Error> = {
            do {
                try store.write(data, projectID: projectID)
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        if synchronously {
            handle(ioQueue.sync(execute: work))
        } else {
            ioQueue.async {
                let result = work()
                Task { @MainActor [weak self] in
                    self?.handle(result)
                }
            }
        }
        refreshThumbnail(for: project)
    }

    private func refreshThumbnail(for project: Project) {
        guard let provider = thumbnailProvider else { return }
        thumbnailTask?.cancel()
        let store = self.store
        thumbnailTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, self != nil else { return }
            if let data = await provider(project) {
                store.saveThumbnail(data, projectID: project.id)
            }
        }
    }

    private func handle(_ result: Result<Void, Error>) {
        if case .failure = result {
            isDirty = true
        }
        onResult?(result)
    }
}
