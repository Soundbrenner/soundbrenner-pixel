import AppKit
import Darwin
import SwiftUI
#if MEDIAFORGE_DIRECT_DISTRIBUTION
import Sparkle

@MainActor
private final class MediaforgeUpdates: NSObject, SPUStandardUserDriverDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self
    )

    func start() {
        _ = controller.updater
    }

    func check() {
        controller.checkForUpdates(nil)
    }

    nonisolated func standardUserDriverWillShowReleaseNotesText(
        _ releaseNotes: NSAttributedString,
        forUpdate update: SUAppcastItem,
        withBundleDisplayVersion _: String,
        bundleVersion: String
    ) -> NSAttributedString? {
        UpdateHighlights.releaseNotes(replacing: releaseNotes, for: update, installedBuild: bundleVersion)
    }
}
#endif

@main
private enum MediaforgeLauncher {
    @MainActor
    static func main() {
        do {
            let descriptor = try claimInstanceLock()
            defer { close(descriptor) }

            // Older builds may already be running without holding the lock.
            if let running = otherInstances.first(where: \.isFinishedLaunching) {
                reopen(running)
                return
            }

            MediaforgeApp.main()
        } catch let error as POSIXError where error.code == .EWOULDBLOCK {
            if let running = otherInstances.first(where: \.isFinishedLaunching) {
                reopen(running)
            }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Mediaforge couldn’t start"
            alert.informativeText = "Mediaforge couldn’t lock its local data folder. \(error.localizedDescription)"
            alert.runModal()
            exit(EXIT_FAILURE)
        }
    }

    private static func reopen(_ application: NSRunningApplication) {
        if let url = application.bundleURL {
            NSWorkspace.shared.open(url)
        }
    }

    private static var otherInstances: [NSRunningApplication] {
        guard let identifier = Bundle.main.bundleIdentifier else { return [] }
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter { $0.processIdentifier != current && !$0.isTerminated }
    }

    private static func claimInstanceLock() throws -> Int32 {
        let folder = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("SoundbrennerMediaGenerator", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("app.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        // Keep the lock file in place. The kernel releases the lock on exit.
        return descriptor
    }
}

struct MediaforgeApp: App {
#if MEDIAFORGE_DIRECT_DISTRIBUTION
    private let updates = MediaforgeUpdates()

    init() {
        updates.start()
    }
#endif
    @StateObject private var galleryStore = GalleryStore()
    @StateObject private var cameraProfileStore = CameraProfileStore()
    @StateObject private var appModel = AppModel()
    @StateObject private var promptModelStore = PromptModelStore()
    @StateObject private var productReferenceStore = ProductReferenceStore()
    @StateObject private var adAngleStore = AdAngleStore()
    @StateObject private var promotionalContextStore = PromotionalContextStore()
    @StateObject private var promptPresetStore = PromptPresetStore()

    var body: some Scene {
        Window("Mediaforge", id: "mediaforge") {
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
        .defaultSize(width: 1240, height: 800)
        .windowToolbarStyle(.unified)
#if MEDIAFORGE_DIRECT_DISTRIBUTION
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for updates…", action: updates.check)
            }
        }
#endif
    }
}
