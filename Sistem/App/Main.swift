import AppKit

/// AppKit owns the lifecycle: the app is a menu bar item first, and the window is
/// created only on demand.
@main
enum SistemMain {
    static func main() {
        let app = NSApplication.shared
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            SnapshotRenderer.run(into: URL(filePath: args[i + 1]))
            return
        }
        if args.contains("--selfcheck") {
            exit(MainActor.assumeIsolated { SelfCheck.run() })
        }
        #endif
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
