import SwiftUI

@main
struct SlateApp: App {
    init() {
        BoardStore.shared.prepareDirectories()
        BoardStore.shared.collectUnusedImagesInBackground(imageStore: ImageStore.shared)
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
                .preferredColorScheme(.dark)
        }
    }
}
