import SwiftUI

@main
struct PicCloudApp: App {
    init() {
        PicCloudCache.configure()
    }

    var body: some Scene {
        WindowGroup {
            GalleryView()
        }
    }
}
