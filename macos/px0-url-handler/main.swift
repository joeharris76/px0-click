import AppKit

// Entry point for the "px0 URL Handler" app bundle.
// LaunchServices delivers clicked px0:// URLs via the Apple Event
// application(_:open:) delegate callback (Command-line argv carries only
// the binary path and possible -psn_* serial numbers, never the URL).
// Each URL is forwarded to ~/.local/bin/px0-open, which normalizes it
// and launches px0 detached.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var opener: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/px0-open")
    }

    /// Seconds to stay alive after the last open event. Rapid clicks arrive
    /// as separate open events; quitting immediately after the first would
    /// drop events still in flight, so each event pushes termination out.
    /// The handler is still effectively one-shot: a background AppKit
    /// process lingering a few seconds per click burst.
    static let lingerSeconds = 3.0

    private var quitTimer: Timer?
    /// Set once open URLs arrive. applicationDidFinishLaunching also fires
    /// on URL launches (order with application(_:open:) is not guaranteed),
    /// so it must not schedule a competing timer once URLs are flowing.
    private var didReceiveOpenEvent = false

    func application(_ application: NSApplication, open urls: [URL]) {
        didReceiveOpenEvent = true
        for url in urls {
            let proc = Process()
            proc.executableURL = Self.opener
            proc.arguments = [url.absoluteString]
            // Detached: never block the event loop on px0.
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            do {
                try proc.run()
            } catch {
                NSLog("px0 URL Handler: failed to launch px0-open: %@", "\(error)")
            }
        }
        // Push out termination so rapid clicks in the same burst are all
        // delivered to this instance instead of racing a relaunch.
        quitTimer?.invalidate()
        quitTimer = Timer.scheduledTimer(withTimeInterval: Self.lingerSeconds, repeats: false) { _ in
            NSApp.terminate(nil)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Launched without URLs (Finder double-click): linger briefly in
        // case an open event is right behind, then quit. Skipped when open
        // events already arrived so two timers never race.
        guard !didReceiveOpenEvent else { return }
        quitTimer = Timer.scheduledTimer(withTimeInterval: Self.lingerSeconds, repeats: false) { _ in
            NSApp.terminate(nil)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
