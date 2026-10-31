import AVFoundation
import Speech

enum CaptionError: LocalizedError {
    case notAuthorized
    case onDeviceUnavailable
    case noSpeech
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Cutline needs Speech Recognition access to make captions. Allow it in Settings > Privacy > Speech Recognition."
        case .onDeviceUnavailable:
            return "On-device speech recognition isn't available for your language on this device. Captions stay private, so Cutline doesn't use online recognition."
        case .noSpeech:
            return "No speech was found in this project's clip audio or voiceovers."
        case .failed(let reason):
            return "Captions couldn't be created: \(reason)"
        }
    }
}

/// On-device speech-to-text with word timing. Only clip audio and
/// voiceovers are transcribed (music is excluded to improve accuracy).
enum CaptionService {
    static func authorize() async -> Bool {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .authorized { return true }
        if current == .denied || current == .restricted { return false }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func generate(for project: Project) async throws -> [CaptionLine] {
        guard await authorize() else { throw CaptionError.notAuthorized }
        let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard let recognizer, recognizer.supportsOnDeviceRecognition else { throw CaptionError.onDeviceUnavailable }

        var speechOnly = project
        speechOnly.audioClips = project.audioClips.filter { $0.role != .music }
        let audioURL: URL
        do {
            audioURL = try await ExportService.exportAudio(project: speechOnly)
        } catch {
            throw CaptionError.noSpeech
        }
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let words = try await transcribe(url: audioURL, recognizer: recognizer)
        guard !words.isEmpty else { throw CaptionError.noSpeech }
        return group(words)
    }

    private static func transcribe(url: URL, recognizer: SFSpeechRecognizer) async throws -> [CaptionWord] {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        final class Box: @unchecked Sendable {
            var task: SFSpeechRecognitionTask?
            var finished = false
        }
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[CaptionWord], Error>) in
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    guard !box.finished else { return }
                    if let result, result.isFinal {
                        box.finished = true
                        let words = result.bestTranscription.segments.map { segment in
                            CaptionWord(text: segment.substring,
                                        start: segment.timestamp,
                                        end: segment.timestamp + max(segment.duration, 0.12))
                        }
                        continuation.resume(returning: words)
                    } else if let error {
                        box.finished = true
                        let nsError = error as NSError
                        // 1110: no speech detected.
                        if nsError.code == 1110 {
                            continuation.resume(returning: [])
                        } else {
                            continuation.resume(throwing: CaptionError.failed(error.localizedDescription))
                        }
                    }
                }
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    /// Groups words into short readable lines.
    static func group(_ words: [CaptionWord]) -> [CaptionLine] {
        var lines: [CaptionLine] = []
        var current: [CaptionWord] = []
        var characters = 0
        for word in words {
            let gap = current.last.map { word.start - $0.end } ?? 0
            if !current.isEmpty && (current.count >= 4 || characters + word.text.count > 22 || gap > 0.6) {
                lines.append(CaptionLine(words: current))
                current = []
                characters = 0
            }
            current.append(word)
            characters += word.text.count + 1
            if let last = word.text.last, ".!?".contains(last) {
                lines.append(CaptionLine(words: current))
                current = []
                characters = 0
            }
        }
        if !current.isEmpty {
            lines.append(CaptionLine(words: current))
        }
        // Keep lines on screen until the next one starts (up to 0.5 s extra).
        for index in lines.indices {
            guard var lastWord = lines[index].words.last else { continue }
            let nextStart = index + 1 < lines.count ? lines[index + 1].start : lastWord.end + 0.5
            lastWord.end = max(lastWord.end, min(lastWord.end + 0.5, nextStart))
            lines[index].words[lines[index].words.count - 1] = lastWord
        }
        return lines
    }
}
