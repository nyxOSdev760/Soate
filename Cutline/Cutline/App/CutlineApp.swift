import AVFoundation
import SwiftUI

@main
struct CutlineApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        Task.detached(priority: .utility) {
            // Prepare the blank base video so the first preview builds instantly.
            _ = try? await BlankVideo.shared.url()
        }
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
                .tint(Color(red: 1, green: 0.32, blue: 0.36))
        }
    }
}
