import SwiftUI

@main
struct SoundbrennerPixelApp: App {
    @StateObject private var galleryStore = GalleryStore()
    @StateObject private var cameraProfileStore = CameraProfileStore()
    @StateObject private var appModel = AppModel()
    @StateObject private var promptModelStore = PromptModelStore()
    @StateObject private var productReferenceStore = ProductReferenceStore()
    @StateObject private var adAngleStore = AdAngleStore()
    @StateObject private var promotionalContextStore = PromotionalContextStore()
    @StateObject private var promptPresetStore = PromptPresetStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(galleryStore)
                .environmentObject(appModel)
                .environmentObject(promptModelStore)
                .environmentObject(cameraProfileStore)
                .environmentObject(productReferenceStore)
                .environmentObject(adAngleStore)
                .environmentObject(promotionalContextStore)
                .environmentObject(promptPresetStore)
                .frame(minWidth: 980, minHeight: 640)
        }
        .defaultSize(width: 1180, height: 760)
    }
}
