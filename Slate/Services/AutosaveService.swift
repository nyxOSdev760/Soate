import UIKit

/// Debounced autosave. Every change calls `scheduleSave()`; the board is
/// written at most `debounceInterval` after the last change and never more
/// than `maximumDelay` after the first unsaved change. Pending changes are
/// written synchronously when the app moves to the background.
@MainActor
final class AutosaveService: NSObject {
    static let debounceInterval: TimeInterval = 0.5
    static let maximumDelay: TimeInterval = 0.9

    var snapshotProvider: (() -> Board?)?
    var thumbnailProvider: ((Board) -> Data?)?
    var onResult: ((Result<Void, Error>) -> Void)?

    private let store: BoardStore
    private let ioQueue = DispatchQueue(label: "com.slate.autosave", qos: .utility)
    private var pendingTask: Task<Void, Never>?
    private var firstUnsavedChange: Date?
    private(set) var hasUnsavedChanges = false

    init(store: BoardStore) {
        self.store = store
        super.init()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.didEnterBackgroundNotification,
                                               object: nil)
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(applicationDidEnterBackground),
                                               name: UIApplication.willTerminateNotification,
                                               object: nil)
    }

    func scheduleSave() {
        hasUnsavedChanges = true
        let now = Date()
        if let first = firstUnsavedChange {
            if now.timeIntervalSince(first) >= AutosaveService.maximumDelay {
                flush(synchronously: false)
                return
            }
        } else {
            firstUnsavedChange = now
        }
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(AutosaveService.debounceInterval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flush(synchronously: false)
        }
    }

    func flush(synchronously: Bool) {
        pendingTask?.cancel()
        pendingTask = nil
        guard hasUnsavedChanges, let board = snapshotProvider?() else { return }
        hasUnsavedChanges = false
        firstUnsavedChange = nil

        let data: Data
        do {
            data = try store.encode(board)
        } catch {
            hasUnsavedChanges = true
            onResult?(.failure(error))
            return
        }
        let thumbnail = thumbnailProvider?(board)
        let store = self.store
        let boardID = board.id

        let work: () -> Result<Void, Error> = {
            do {
                try store.write(data, for: boardID)
                if let thumbnail {
                    store.saveThumbnail(thumbnail, for: boardID)
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        if synchronously {
            let result = ioQueue.sync(execute: work)
            handle(result)
        } else {
            ioQueue.async {
                let result = work()
                Task { @MainActor [weak self] in
                    self?.handle(result)
                }
            }
        }
    }

    private func handle(_ result: Result<Void, Error>) {
        if case .failure = result {
            // Keep the data marked dirty so the next change retries.
            hasUnsavedChanges = true
        }
        onResult?(result)
    }

    @objc private func applicationDidEnterBackground() {
        flush(synchronously: true)
    }
}
